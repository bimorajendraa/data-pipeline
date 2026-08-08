"""Beri skor risiko kerusakan 30 hari untuk PART yang saat ini masih aktif
(belum rusak, belum dipasang ulang), memakai model yang sudah dilatih dan
disimpan oleh train_final_model.py.

Fitur diambil dari snapshot 30-harian TERAKHIR yang tersedia untuk setiap
cycle yang masih berjalan (analytics.item_observation_30d dengan
cycle_end_reason = 'RIGHT_CENSORED_AT_DATA_END') - bukan dihitung ulang -
supaya persis konsisten dengan logika point-in-time yang sudah divalidasi
di pipeline SQL. Karena snapshot dibuat setiap 30 hari, skor tiap PART bisa
"basi" sampai ~29 hari; kolom hari_sejak_snapshot menunjukkan itu secara
eksplisit. PART yang baru dipasang kurang dari 30 hari sebelum data
terakhir belum akan muncul di sini karena belum sempat mendapat snapshot.
"""

from __future__ import annotations

import json

import joblib
import pandas as pd
from catboost import CatBoostClassifier

from database import PROJECT_DIR, connect

MODEL_DIR = PROJECT_DIR / "models"
MODEL_PATH = MODEL_DIR / "failure_30d_baseline_catboost.cbm"
CALIBRATOR_PATH = MODEL_DIR / "failure_30d_baseline_calibrator.joblib"
METADATA_PATH = MODEL_DIR / "failure_30d_baseline_metadata.json"
OUTPUT_PATH = PROJECT_DIR / "reports" / "current_risk_ranking.csv"


def query(sql: str) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])


def load_active_snapshots(feature_columns: list[str]) -> pd.DataFrame:
    columns_sql = ", ".join(f"f.{c}" for c in feature_columns)
    data = query(f"""
        WITH latest_snapshot AS (
            SELECT DISTINCT ON (installation_cycle_id)
                installation_cycle_id, item_identifier_clean, observation_on
            FROM analytics.item_observation_30d
            WHERE cycle_end_reason = 'RIGHT_CENSORED_AT_DATA_END'
            ORDER BY installation_cycle_id, observation_on DESC
        ), boundary AS (
            SELECT MAX(created_on) AS dataset_max_event_on
            FROM analytics.item_journey_operational_timeline
        )
        SELECT f.installation_cycle_id, f.item_identifier_clean, f.observation_on,
            {columns_sql},
            EXTRACT(EPOCH FROM (b.dataset_max_event_on - f.observation_on)) / 86400.0
                AS hari_sejak_snapshot
        FROM analytics.failure_30d_baseline_features f
        JOIN latest_snapshot ls
          USING (installation_cycle_id, item_identifier_clean, observation_on)
        CROSS JOIN boundary b
    """)
    return data


def main() -> int:
    if not (MODEL_PATH.exists() and CALIBRATOR_PATH.exists() and METADATA_PATH.exists()):
        raise SystemExit(
            "Model belum tersedia. Jalankan dulu: python src/train_final_model.py"
        )

    metadata = json.loads(METADATA_PATH.read_text(encoding="utf-8"))
    feature_columns = metadata["feature_columns"]
    categorical_features = metadata["categorical_features"]

    model = CatBoostClassifier()
    model.load_model(str(MODEL_PATH))
    calibrator = joblib.load(CALIBRATOR_PATH)

    active = load_active_snapshots(feature_columns)
    if active.empty:
        print("[INFO] Tidak ada PART aktif yang bisa diberi skor saat ini.")
        return 0

    active[categorical_features] = active[categorical_features].astype(str)
    numeric_columns = [c for c in feature_columns if c not in categorical_features]
    active[numeric_columns] = active[numeric_columns].apply(pd.to_numeric)

    raw_proba = model.predict_proba(active[feature_columns])[:, 1]
    calibrated_proba = calibrator.predict(raw_proba)

    result = active[["installation_cycle_id", "item_identifier_clean", "observation_on",
                      "hari_sejak_snapshot"]].copy()
    result["part_model_category"] = active["part_model_category"]
    result["client_category"] = active["client_category"]
    result["skor_risiko_30_hari"] = calibrated_proba
    result["skor_mentah"] = raw_proba
    # Urut berdasarkan skor mentah (lebih presisi antar-PART, tidak
    # menggumpal) - skor_risiko_30_hari tetap ditampilkan untuk dibaca
    # sebagai perkiraan persentase, tetapi kalibrasi isotonic secara alami
    # membuat beberapa PART berbagi nilai persis sama (plateau), sehingga
    # kurang cocok dipakai sebagai kunci urutan halus.
    result = result.sort_values("skor_mentah", ascending=False).reset_index(drop=True)
    result.insert(0, "peringkat", result.index + 1)

    OUTPUT_PATH.parent.mkdir(exist_ok=True)
    result.to_csv(OUTPUT_PATH, index=False)

    print(f"[OK] {len(result):,} PART aktif diberi skor.".replace(",", "."))
    print(f"[OK] Hasil disimpan: {OUTPUT_PATH}")
    print("\nTop 10 PART dengan risiko tertinggi:")
    top10 = result.head(10)[["peringkat", "item_identifier_clean", "part_model_category",
                              "skor_risiko_30_hari", "skor_mentah", "hari_sejak_snapshot"]]
    with pd.option_context("display.max_columns", None, "display.width", 120):
        print(top10.to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
