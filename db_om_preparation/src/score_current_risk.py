"""Beri skor risiko kerusakan 30 hari untuk PART yang saat ini masih aktif
(belum rusak, belum dipasang ulang), memakai model yang sudah dilatih dan
disimpan oleh train_final_model.py.

Fitur diambil dari analytics.item_current_snapshot_features (sql/15) yang
menghitung ulang fitur historis PERSIS pada observation_on = kejadian
terbaru yang tercatat di database (dataset_max_event_on) untuk setiap cycle
yang masih aktif - bukan snapshot grid 30-harian dari dataset training
(analytics.item_observation_30d), yang bisa tertinggal sampai ~29 hari.
Rumus fiturnya identik dengan yang dipakai training (lihat komentar di
sql/15_current_risk_snapshot.sql), jadi model yang sama tetap valid dipakai
tanpa dilatih ulang. Kolom hari_sejak_data_terakhir menunjukkan seberapa
baru DATABASE itu sendiri (dataset_max_event_on vs waktu saat ini) - bukan
lagi soal snapshot yang basi, karena sekarang skornya selalu dihitung dari
kejadian terbaru yang tersedia. PART yang baru dipasang tetap langsung
mendapat skor sejak hari pertama, karena tidak lagi bergantung pada grid
30 hari.
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
        SELECT f.installation_cycle_id, f.item_identifier_clean, f.observation_on,
            {columns_sql},
            EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - f.observation_on)) / 86400.0
                AS hari_sejak_data_terakhir
        FROM analytics.item_current_snapshot_features f
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

    # Kelompok risiko (Tinggi/Sedang/Rendah) berdasarkan skor terkalibrasi
    # dibandingkan dengan base rate historis (persentase kerusakan asli di
    # data validasi - anchor yang sama dipakai kalibrator). Ambang batas
    # (>=3x dan >=1x base rate) diuji terhadap data test 2026 dan terbukti
    # memisahkan tiga kelompok dengan persentase kerusakan sungguhan yang
    # jauh berbeda (16,1% / 4,5% / 0,9%). Dipakai sebagai pengganti ranking
    # 1-2-3 yang presisi karena PART dengan skor mirip sering berbagi nilai
    # persis sama (plateau kalibrasi) - masuk kelompok yang sama itu wajar,
    # dipaksa berebut urutan justru tidak stabil antar hitung ulang.
    validation_metrics = metadata["metrics"]["validation"]
    base_rate = validation_metrics["positives"] / validation_metrics["rows"]
    tier = pd.cut(
        calibrated_proba,
        bins=[-float("inf"), base_rate, 3 * base_rate, float("inf")],
        labels=["Rendah", "Sedang", "Tinggi"],
    )

    result = active[["installation_cycle_id", "item_identifier_clean", "observation_on",
                      "hari_sejak_data_terakhir"]].copy()
    result["part_model_category"] = active["part_model_category"]
    result["client_category"] = active["client_category"]
    result["kelompok_risiko"] = pd.Categorical(tier, categories=["Tinggi", "Sedang", "Rendah"], ordered=True)
    result["skor_risiko_30_hari"] = calibrated_proba
    result["skor_mentah"] = raw_proba
    # Urut dulu per kelompok risiko (Tinggi -> Sedang -> Rendah, ini yang
    # stabil dan dipakai untuk keputusan kerja), lalu skor mentah sebagai
    # urutan halus di dalam kelompok yang sama (informatif tapi tidak
    # sepresisi urutan kelompoknya sendiri).
    result = result.sort_values(
        ["kelompok_risiko", "skor_mentah"], ascending=[True, False]
    ).reset_index(drop=True)
    result.insert(0, "peringkat", result.index + 1)

    OUTPUT_PATH.parent.mkdir(exist_ok=True)
    result.to_csv(OUTPUT_PATH, index=False)

    print(f"[OK] {len(result):,} PART aktif diberi skor.".replace(",", "."))
    print(f"[OK] Hasil disimpan: {OUTPUT_PATH}")
    print("\nJumlah PART per kelompok risiko:")
    print(result["kelompok_risiko"].value_counts().reindex(["Tinggi", "Sedang", "Rendah"]).to_string())
    print("\nContoh PART di kelompok Tinggi (skor mentah tertinggi lebih dulu):")
    top_high = result.loc[result["kelompok_risiko"].eq("Tinggi")].head(10)[
        ["peringkat", "item_identifier_clean", "part_model_category",
         "kelompok_risiko", "skor_risiko_30_hari", "hari_sejak_data_terakhir"]
    ]
    with pd.option_context("display.max_columns", None, "display.width", 120):
        print(top_high.to_string(index=False) if len(top_high) else "(kosong)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
