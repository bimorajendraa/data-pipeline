"""Beri skor risiko kerusakan 30/90/180 hari untuk PART yang saat ini masih
aktif, dengan cara "discrete-time hazard chaining" - BUKAN model baru.

Cara kerja: model 30 hari RESMI (train_final_model.py, tidak diubah/dilatih
ulang di sini) dipakai sebagai estimator hazard 30-harian. Untuk
memperkirakan risiko 90/180 hari, fitur "diputar maju" 30 hari demi 30 hari
(umur pemasangan dan waktu sejak corrective terakhir bertambah sesuai waktu
yang berlalu; fitur riwayat/hitungan lain DIBEKUKAN pada nilai saat ini -
asumsi "tidak ada kejadian baru", cara paling sederhana yang bisa
dipertanggungjawabkan tanpa mensimulasikan kejadian acak), lalu model yang
SAMA dipakai untuk menaksir hazard di tiap periode 30 hari berikutnya.
Risiko kumulatif dihitung lewat survival chaining:

    S(30k hari) = produk (1 - hazard_langkah_i) untuk i=0..k-1
    P(gagal dalam 30k hari) = 1 - S(30k hari)

Ini MENJAMIN P(30d) <= P(90d) <= P(180d) secara matematis (bukan kebetulan),
dan pada backtest TEST_2026 (populasi & ground truth sama persis dengan
train_multi_horizon_models.py) terbukti PERINGKAT dan KALIBRASINYA lebih
baik daripada classifier 90/180 hari yang dilatih terpisah:

    90 hari  : ROC-AUC 0,699 vs 0,664 (chained menang), PR-AUC 0,451 vs 0,382, Brier 0,197 vs 0,204
    180 hari : ROC-AUC 0,733 vs 0,687 (chained menang), PR-AUC 0,204 vs 0,193, Brier 0,089 vs 0,093
    (angka lengkap: models/failure_multi_horizon_metadata.json -> hazard_chaining_vs_direct_classifier)

Keterbatasan yang harus diingat: asumsi "tidak ada kejadian baru" antar
langkah adalah PENYEDERHANAAN - kalau PART benar-benar mengalami corrective
baru dalam 90/180 hari ke depan, taksiran ini tidak "tahu" itu (tapi begitu
juga classifier 90/180 hari terpisah - keduanya sama-sama hanya memakai
fitur pada titik waktu SEKARANG, bukan mengintip masa depan).

TIDAK menggantikan score_current_risk.py (skor 30 hari resmi tetap dari
sana) - script ini murni tambahan untuk pertanyaan "seberapa jauh ke depan".
"""

from __future__ import annotations

import json

import joblib
import numpy as np
import pandas as pd
from catboost import CatBoostClassifier

from database import PROJECT_DIR, connect

MODEL_DIR = PROJECT_DIR / "models"
MODEL_PATH = MODEL_DIR / "failure_30d_baseline_catboost.cbm"
CALIBRATOR_PATH = MODEL_DIR / "failure_30d_baseline_calibrator.joblib"
METADATA_PATH = MODEL_DIR / "failure_30d_baseline_metadata.json"
OUTPUT_PATH = PROJECT_DIR / "reports" / "current_risk_ranking_multi_horizon.csv"

HORIZON_STEPS = {"30d": 1, "90d": 3, "180d": 6}  # dalam kelipatan 30 hari
N_STEPS = max(HORIZON_STEPS.values())

AGE_BAND_BINS = [-1, 90, 180, 365, 730, 1460, np.inf]
AGE_BAND_LABELS = [
    "000_090_DAYS", "091_180_DAYS", "181_365_DAYS",
    "366_730_DAYS", "731_1460_DAYS", "1461_PLUS_DAYS",
]


def query(sql: str) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])


def load_active_snapshots(feature_columns: list[str]) -> pd.DataFrame:
    columns_sql = ", ".join(f"f.{c}" for c in feature_columns)
    return query(f"""
        SELECT f.installation_cycle_id, f.item_identifier_clean, f.observation_on,
            {columns_sql}
        FROM analytics.item_current_snapshot_features f
    """)


def project_step(base: pd.DataFrame, k: int) -> pd.DataFrame:
    """Fitur pada langkah ke-k (k=0 = sekarang). Lihat docstring modul."""
    proj = base.copy()
    days = base["_raw_days_since_installation"] + 30 * k
    corrective_days = base["_eff_days_since_last_corrective"] + 30 * k
    proj["log_days_since_installation"] = np.log1p(days.clip(lower=0))
    proj["installation_age_band"] = pd.cut(days, bins=AGE_BAND_BINS, labels=AGE_BAND_LABELS).astype(str)
    proj["log_days_since_last_corrective"] = np.log1p(corrective_days.clip(lower=0))
    future_month = (base["observation_on"] + pd.to_timedelta(30 * k, unit="D")).dt.month
    proj["month_sin"] = np.sin(2.0 * np.pi * (future_month - 1) / 12.0)
    proj["month_cos"] = np.cos(2.0 * np.pi * (future_month - 1) / 12.0)
    return proj


def main() -> int:
    if not (MODEL_PATH.exists() and CALIBRATOR_PATH.exists() and METADATA_PATH.exists()):
        raise SystemExit("Model belum tersedia. Jalankan dulu: python src/train_final_model.py")

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

    active["observation_on"] = pd.to_datetime(active["observation_on"])
    numeric_columns = [c for c in feature_columns if c not in categorical_features]
    active[numeric_columns] = active[numeric_columns].apply(pd.to_numeric)

    # Balikkan transformasi LN(1+x) dari sql/15 - exp(m1) adalah invers eksak.
    active["_raw_days_since_installation"] = np.expm1(active["log_days_since_installation"])
    active["_eff_days_since_last_corrective"] = np.expm1(active["log_days_since_last_corrective"])

    survival = pd.Series(1.0, index=active.index)
    checkpoint_proba: dict[str, pd.Series] = {}
    for k in range(N_STEPS):
        proj = project_step(active, k)
        proj[categorical_features] = proj[categorical_features].astype(str)
        raw = model.predict_proba(proj[feature_columns])[:, 1]
        hazard_k = calibrator.predict(raw)
        survival = survival * (1 - hazard_k)
        for horizon, steps in HORIZON_STEPS.items():
            if k == steps - 1:
                checkpoint_proba[horizon] = 1 - survival.copy()

    result = active[["installation_cycle_id", "item_identifier_clean", "observation_on",
                      "part_model_category", "client_category"]].copy()
    result["risiko_30_hari"] = checkpoint_proba["30d"]
    result["risiko_90_hari"] = checkpoint_proba["90d"]
    result["risiko_180_hari"] = checkpoint_proba["180d"]
    # Konsistensi monotonicity WAJIB benar (dijamin konstruksi matematisnya,
    # bukan sekadar diharapkan) - dicek eksplisit sebagai jaring pengaman.
    assert (result["risiko_30_hari"] <= result["risiko_90_hari"] + 1e-9).all()
    assert (result["risiko_90_hari"] <= result["risiko_180_hari"] + 1e-9).all()

    result = result.sort_values("risiko_180_hari", ascending=False).reset_index(drop=True)
    result.insert(0, "peringkat", result.index + 1)

    OUTPUT_PATH.parent.mkdir(exist_ok=True)
    result.to_csv(OUTPUT_PATH, index=False)

    print(f"[OK] {len(result):,} PART aktif diberi skor multi-horizon.".replace(",", "."))
    print(f"[OK] Hasil disimpan: {OUTPUT_PATH}")
    print("\nContoh 10 PART risiko 180-hari tertinggi:")
    top = result.head(10)[["peringkat", "item_identifier_clean", "part_model_category",
                            "risiko_30_hari", "risiko_90_hari", "risiko_180_hari"]]
    with pd.option_context("display.max_columns", None, "display.width", 120):
        print(top.to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
