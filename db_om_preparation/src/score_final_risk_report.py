"""Laporan risiko akhir per PART aktif - menggabungkan Risk 30/90/180 hari
(hazard chaining, lihat score_multi_horizon_risk.py), kelompok risiko,
estimasi jendela waktu kegagalan, dan skor keandalan (reliability) jadi
satu tabel, mengikuti format yang diminta Bagian 28 master prompt.

TIDAK melatih model baru - murni menggabungkan output yang sudah
tervalidasi di fase-fase sebelumnya:
- Risk 30D/90D/180D: model 30 hari resmi + hazard chaining (Fase 6,
  terbukti lebih akurat & menjamin monotonicity dibanding classifier
  90/180 hari terpisah - lihat models/failure_multi_horizon_metadata.json)
- Kelompok risiko (Tinggi/Sedang/Rendah): ambang batas yang sama dan sudah
  diuji di score_current_risk.py (>=3x dan >=1x base rate validasi)
- Estimasi jendela waktu kegagalan: dari kurva hazard yang sama, HANYA
  dilaporkan untuk PART kelompok Tinggi/Sedang - untuk kelompok Rendah,
  risiko 180 harinya sendiri terlalu kecil untuk jendela waktu yang
  bermakna, jadi dilaporkan apa adanya sebagai "belum bisa diperkirakan"
  alih-alih memaksakan angka presisi palsu (sesuai larangan eksplisit
  Bagian 15 master prompt)
- Reliability: berdasarkan dukungan historis tipe PART (part_model_category)
  - HIGH/MEDIUM/LOW/UNKNOWN, ambang sama dengan yang dipakai rare-category
  ablation (Fase 3): >=5000 baris riwayat = Tinggi, 300-4999 = Sedang,
  <300 atau tidak dikenal = Rendah. Ini bukan skor kepercayaan model
  formal (mis. interval prediksi) - hanya proxy "seberapa banyak riwayat
  yang mendukung prediksi tipe PART ini", supaya pengguna tahu prediksi
  mana yang didukung banyak data historis vs sedikit.
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
OUTPUT_PATH = PROJECT_DIR / "reports" / "final_risk_report.csv"

HORIZON_STEPS = {"30d": 1, "90d": 3, "180d": 6}
N_STEPS = max(HORIZON_STEPS.values())
BIN_LABELS = ["1-30", "31-60", "61-90", "91-120", "121-150", "151-180"]

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
            f.part_model_code_raw, f.part_model_cumulative_support,
            {columns_sql}
        FROM analytics.item_current_snapshot_features f
    """)


def project_step(base: pd.DataFrame, k: int) -> pd.DataFrame:
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


def reliability_tier(support: pd.Series, category: pd.Series) -> pd.Series:
    tier = pd.Series("Rendah", index=support.index)
    tier[(category != "UNKNOWN") & (support >= 300)] = "Sedang"
    tier[(category != "UNKNOWN") & (support >= 5000)] = "Tinggi"
    return pd.Categorical(tier, categories=["Tinggi", "Sedang", "Rendah"], ordered=True)


def failure_window(hazard_steps: np.ndarray, risk_level: str) -> str:
    """Perkiraan jendela waktu kegagalan dari kurva hazard 30-harian.
    Hanya dilaporkan untuk kelompok Tinggi/Sedang - lihat docstring modul."""
    if risk_level == "Rendah":
        return "Risiko rendah - jendela waktu belum bisa diperkirakan"
    survival = np.cumprod(1 - hazard_steps)
    cum_fail = 1 - survival
    total = cum_fail[-1]
    if total < 0.05:
        return "Risiko 180 hari terlalu kecil - jendela waktu belum bisa diperkirakan"
    conditional_cdf = cum_fail / total
    bin_25 = int(np.searchsorted(conditional_cdf, 0.25))
    bin_75 = int(np.searchsorted(conditional_cdf, 0.75))
    bin_25, bin_75 = min(bin_25, 5), min(bin_75, 5)
    lo = BIN_LABELS[bin_25].split("-")[0]
    hi = BIN_LABELS[bin_75].split("-")[1]
    return f"{lo}-{hi} hari"


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
    active["part_model_cumulative_support"] = pd.to_numeric(active["part_model_cumulative_support"])

    active["_raw_days_since_installation"] = np.expm1(active["log_days_since_installation"])
    active["_eff_days_since_last_corrective"] = np.expm1(active["log_days_since_last_corrective"])

    survival = pd.Series(1.0, index=active.index)
    hazard_matrix = np.zeros((len(active), N_STEPS))
    checkpoint_proba: dict[str, pd.Series] = {}
    for k in range(N_STEPS):
        proj = project_step(active, k)
        proj[categorical_features] = proj[categorical_features].astype(str)
        raw = model.predict_proba(proj[feature_columns])[:, 1]
        hazard_k = calibrator.predict(raw)
        hazard_matrix[:, k] = hazard_k
        survival = survival * (1 - hazard_k)
        for horizon, steps in HORIZON_STEPS.items():
            if k == steps - 1:
                checkpoint_proba[horizon] = 1 - survival.copy()

    # Kelompok risiko: ambang sama & sudah teruji di score_current_risk.py,
    # berbasis skor 30 hari (dari model resmi, bukan hasil chaining).
    validation_metrics = metadata["metrics"]["validation"]
    base_rate = validation_metrics["positives"] / validation_metrics["rows"]
    risk_level = pd.cut(
        checkpoint_proba["30d"],
        bins=[-float("inf"), base_rate, 3 * base_rate, float("inf")],
        labels=["Rendah", "Sedang", "Tinggi"],
    ).astype(str)

    result = active[["installation_cycle_id", "item_identifier_clean", "observation_on",
                      "part_model_category", "part_model_code_raw", "client_category"]].copy()
    result["umur_hari"] = active["_raw_days_since_installation"].round(0).astype(int)
    result["risiko_30_hari"] = checkpoint_proba["30d"]
    result["risiko_90_hari"] = checkpoint_proba["90d"]
    result["risiko_180_hari"] = checkpoint_proba["180d"]
    result["kelompok_risiko"] = pd.Categorical(risk_level, categories=["Tinggi", "Sedang", "Rendah"], ordered=True)
    result["jendela_kegagalan"] = [
        failure_window(hazard_matrix[i], risk_level[i]) for i in range(len(active))
    ]
    result["keandalan_prediksi"] = reliability_tier(
        active["part_model_cumulative_support"], active["part_model_category"]
    )

    result = result.sort_values(
        ["kelompok_risiko", "risiko_180_hari"], ascending=[True, False]
    ).reset_index(drop=True)
    result.insert(0, "peringkat", result.index + 1)

    OUTPUT_PATH.parent.mkdir(exist_ok=True)
    result.to_csv(OUTPUT_PATH, index=False)

    print(f"[OK] {len(result):,} PART aktif diberi laporan risiko akhir.".replace(",", "."))
    print(f"[OK] Hasil disimpan: {OUTPUT_PATH}")
    print("\nJumlah PART per kelompok risiko x keandalan prediksi:")
    print(pd.crosstab(result["kelompok_risiko"], result["keandalan_prediksi"]))
    print("\nContoh 10 PART risiko tertinggi:")
    cols = ["peringkat", "item_identifier_clean", "part_model_code_raw", "umur_hari",
            "risiko_30_hari", "risiko_90_hari", "risiko_180_hari",
            "kelompok_risiko", "jendela_kegagalan", "keandalan_prediksi"]
    with pd.option_context("display.max_columns", None, "display.width", 200):
        print(result[cols].head(10).to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
