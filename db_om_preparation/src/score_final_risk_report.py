"""Laporan risiko akhir per PART aktif - kurva risiko di beberapa titik waktu
(7/14/30/60/90/120/150/180 hari, hazard chaining - lihat
score_multi_horizon_risk.py), kelompok risiko, estimasi jendela waktu
kegagalan, dan skor keandalan (reliability) jadi satu tabel, mengikuti
format yang diminta Bagian 28 master prompt.

TIDAK melatih model baru - murni menggabungkan/memperluas output yang sudah
tervalidasi di fase-fase sebelumnya. Eksperimen Random Survival Forest
(2026-08) sempat dicoba sebagai alternatif TAPI DITOLAK: C-index test-nya
konsisten lebih rendah (~0,66-0,67) daripada Cox PH yang sudah ada (0,71)
di semua kombinasi hyperparameter yang dicoba - lihat
notebooks/06_survival_analysis.ipynb. Karena itu, kurva risiko multi-titik
di bawah tetap memakai hazard chaining dari model 30 hari resmi (CatBoost),
BUKAN Cox PH ataupun RSF - hazard chaining sudah terbukti lebih akurat dari
classifier 90/180 hari terpisah DAN memakai fitur jauh lebih lengkap (18
fitur point-in-time) dibanding yang bisa dipakai Cox PH/RSF (cuma fitur di
titik pemasangan awal).

- Risk per titik waktu: model 30 hari resmi + hazard chaining (Fase 6).
  Titik 7/14 hari diinterpolasi dari hazard 30-harian pertama dengan
  asumsi laju kegagalan konstan dalam window itu (pendekatan standar utk
  granularitas sub-window pada discrete-time hazard model) - titik
  30/60/.../180 hari adalah hasil chaining langsung, bukan interpolasi.
- Kelompok risiko (Tinggi/Sedang/Rendah): ambang batas yang sama dan sudah
  diuji di score_current_risk.py (>=3x dan >=1x base rate validasi),
  berbasis risiko 30 hari.
- Estimasi jendela waktu kegagalan: dari kurva hazard yang sama, HANYA
  dilaporkan untuk PART kelompok Tinggi/Sedang - untuk kelompok Rendah,
  risiko 180 harinya sendiri terlalu kecil untuk jendela waktu yang
  bermakna, jadi dilaporkan apa adanya sebagai "belum bisa diperkirakan"
  alih-alih memaksakan angka presisi palsu (sesuai larangan eksplisit
  Bagian 15 master prompt)
- Reliability: berdasarkan dukungan historis tipe PART (part_model_category)
  - Tinggi/Sedang/Rendah, ambang sama dengan yang dipakai rare-category
  ablation (Fase 3): >=5000 baris riwayat = Tinggi, 300-4999 = Sedang,
  <300 atau tidak dikenal = Rendah. Ini bukan skor kepercayaan model
  formal (mis. interval prediksi) - hanya proxy "seberapa banyak riwayat
  yang mendukung prediksi tipe PART ini", supaya pengguna tahu prediksi
  mana yang didukung banyak data historis vs sedikit.
- Prioritas kerja: kolom `peringkat`, diurutkan kelompok risiko dulu lalu
  risiko 180 hari - sudah mencakup horizon pendek dan panjang sekaligus.
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

CHECKPOINT_DAYS = [7, 14, 30, 60, 90, 120, 150, 180]
N_STEPS = 6  # 6 x 30 hari = 180 hari, mencakup seluruh CHECKPOINT_DAYS
BIN_LABELS = ["1-30", "31-60", "61-90", "91-120", "121-150", "151-180"]


def cumulative_failure_at(hazard_steps: np.ndarray, day: int) -> float:
    """P(gagal dalam `day` hari) dari kurva hazard 30-harian. Untuk day yang
    bukan kelipatan 30 (mis. 7, 14), langkah TERAKHIR yang belum penuh
    diinterpolasi dengan asumsi laju kegagalan konstan dalam window
    30-harian itu - standar untuk granularitas sub-window pada
    discrete-time hazard model, bukan hasil chaining langsung."""
    full_steps, remainder = divmod(day, 30)
    survival = np.prod(1 - hazard_steps[:full_steps]) if full_steps > 0 else 1.0
    if remainder > 0 and full_steps < len(hazard_steps):
        survival *= (1 - hazard_steps[full_steps]) ** (remainder / 30.0)
    return 1 - survival

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

    hazard_matrix = np.zeros((len(active), N_STEPS))
    hazard_matrix_raw = np.zeros((len(active), N_STEPS))
    for k in range(N_STEPS):
        proj = project_step(active, k)
        proj[categorical_features] = proj[categorical_features].astype(str)
        raw = model.predict_proba(proj[feature_columns])[:, 1]
        hazard_matrix[:, k] = calibrator.predict(raw)
        hazard_matrix_raw[:, k] = raw

    # Skor mentah (tanpa kalibrasi) HANYA dipakai sebagai pemecah seri urutan,
    # tidak pernah dilaporkan sebagai probabilitas. Kalibrator isotonic adalah
    # fungsi tangga: pada data 2026 ia memampatkan 2.190 nilai skor mentah
    # menjadi hanya 377 nilai terkalibrasi, sehingga ribuan PART berbagi angka
    # identik (blok terbesar: 27,9% armada bernilai sama persis). Tanpa pemecah
    # seri, urutan di dalam blok itu mengikuti urutan baris - berubah-ubah antar
    # hitung ulang padahal datanya sama. score_current_risk.py sudah memakai
    # pola yang sama (lihat komentar di sana); laporan akhir ini sebelumnya
    # terlewat. Diukur pada landmark test 2026: pengaruhnya ke akurasi kecil
    # (PR-AUC 0,1907 -> 0,1941, Top-K nyaris tak berubah) - alasan utamanya
    # keterulangan hasil, bukan kenaikan akurasi.
    risk_180_raw = 1 - np.prod(1 - hazard_matrix_raw, axis=1)

    checkpoint_proba: dict[int, np.ndarray] = {
        day: np.array([cumulative_failure_at(hazard_matrix[i], day) for i in range(len(active))])
        for day in CHECKPOINT_DAYS
    }
    # Jaring pengaman: kurva HARUS naik monoton (dijamin konstruksi
    # matematisnya - perkalian survival tidak pernah turun makin lama waktu
    # berjalan), bukan sekadar diharapkan.
    for a, b in zip(CHECKPOINT_DAYS, CHECKPOINT_DAYS[1:]):
        assert (checkpoint_proba[a] <= checkpoint_proba[b] + 1e-9).all(), f"monotonicity gagal {a} vs {b}"

    # Kelompok risiko: ambang sama & sudah teruji di score_current_risk.py,
    # berbasis skor 30 hari (dari model resmi, bukan hasil chaining).
    validation_metrics = metadata["metrics"]["validation"]
    base_rate = validation_metrics["positives"] / validation_metrics["rows"]
    risk_level = pd.cut(
        checkpoint_proba[30],
        bins=[-float("inf"), base_rate, 3 * base_rate, float("inf")],
        labels=["Rendah", "Sedang", "Tinggi"],
    ).astype(str)

    result = active[["installation_cycle_id", "item_identifier_clean", "observation_on",
                      "part_model_category", "part_model_code_raw", "client_category"]].copy()
    result["umur_hari"] = active["_raw_days_since_installation"].round(0).astype(int)
    for day in CHECKPOINT_DAYS:
        result[f"risiko_{day}_hari"] = checkpoint_proba[day]
    result["kelompok_risiko"] = pd.Categorical(risk_level, categories=["Tinggi", "Sedang", "Rendah"], ordered=True)
    result["jendela_kegagalan"] = [
        failure_window(hazard_matrix[i], risk_level[i]) for i in range(len(active))
    ]
    result["keandalan_prediksi"] = reliability_tier(
        active["part_model_cumulative_support"], active["part_model_category"]
    )

    result["_skor_mentah_180"] = risk_180_raw
    result = result.sort_values(
        ["kelompok_risiko", "risiko_180_hari", "_skor_mentah_180"],
        ascending=[True, False, False],
    ).drop(columns="_skor_mentah_180").reset_index(drop=True)
    result.insert(0, "peringkat", result.index + 1)

    OUTPUT_PATH.parent.mkdir(exist_ok=True)
    result.to_csv(OUTPUT_PATH, index=False)

    print(f"[OK] {len(result):,} PART aktif diberi laporan risiko akhir.".replace(",", "."))
    print(f"[OK] Hasil disimpan: {OUTPUT_PATH}")
    print("\nJumlah PART per kelompok risiko x keandalan prediksi:")
    print(pd.crosstab(result["kelompok_risiko"], result["keandalan_prediksi"]))
    print("\nContoh 10 PART risiko tertinggi:")
    cols = (["peringkat", "item_identifier_clean", "part_model_code_raw", "umur_hari"]
            + [f"risiko_{d}_hari" for d in CHECKPOINT_DAYS]
            + ["kelompok_risiko", "jendela_kegagalan", "keandalan_prediksi"])
    with pd.option_context("display.max_columns", None, "display.width", 200):
        print(result[cols].head(10).to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
