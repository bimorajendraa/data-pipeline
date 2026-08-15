"""Konfigurasi tunggal untuk pipeline production.

Semua angka/ambang di sini berasal dari hasil research yang sudah terbukti di
repository lama (db_om_preparation). Tidak ada nilai baru yang dikarang: lihat
README.md bagian "Asal-usul setiap konstanta".
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

PACKAGE_DIR = Path(__file__).resolve().parent
MODEL_DIR = PACKAGE_DIR / "models"

# --- Fitur final model (18 fitur, urutan wajib sama seperti saat training) ----
CATEGORICAL_FEATURES = [
    "part_model_category",
    "client_category",
    "installation_age_band",
]
NUMERIC_FEATURES = [
    "log_days_since_installation",
    "log_total_prior_events",
    "log_prior_failure_count",
    "has_prior_failure",
    "log_prior_corrective_count",
    "has_prior_corrective",
    "log_days_since_last_corrective",
    "log_prior_distinct_places",
    "log_prior_corrective_30d",
    "log_prior_failure_365d",
    "log_prior_events_180d",
    "log_previous_cycle_lifetime_mean",
    "has_previous_cycle",
    "month_sin",
    "month_cos",
]
FEATURE_COLUMNS = CATEGORICAL_FEATURES + NUMERIC_FEATURES

# --- Target dan observasi ---------------------------------------------------
# Target: PART mengalami failure onset dalam 30 hari SETELAH observation_on.
TARGET_HORIZON_DAYS = 30
# Snapshot training dibuat pada grid tetap 30 hari sejak tanggal pemasangan.
OBSERVATION_STEP_DAYS = 30

# --- Split waktu (dengan embargo selebar horizon target) --------------------
MIN_OBSERVATION_DATE = "2014-01-01"
TRAIN_END = "2025-01-01"
VALIDATION_END = "2026-01-01"

# --- Hyperparameter model ---------------------------------------------------
# Iterasi TETAP (bukan early stopping): early stopping berbasis AUC pada
# validasi yang positifnya sedikit terbukti bisa berhenti sangat prematur dan
# menghasilkan model dengan resolusi probabilitas sangat kasar.
CATBOOST_PARAMS = {
    "iterations": 200,
    "depth": 4,
    "learning_rate": 0.03,
    "l2_leaf_reg": 10,
    "loss_function": "Logloss",
    "eval_metric": "AUC",
    "auto_class_weights": "Balanced",
    "use_best_model": False,
    "verbose": False,
    "thread_count": 1,
}
RANDOM_STATE = 42

# --- Konstanta feature engineering ------------------------------------------
# Tipe PART dengan riwayat < 300 observasi dikelompokkan jadi satu kategori
# supaya model tidak menghafal pola dari sampel yang terlalu kecil.
MIN_PART_MODEL_SUPPORT = 300
LOW_SUPPORT_LABEL = "LOW_HISTORICAL_SUPPORT"
UNKNOWN_LABEL = "UNKNOWN"

# Ambang batas umur (hari). Umur bersifat pecahan, jadi ambang ditulis sebagai
# batas "lebih kecil dari" persis seperti definisi SQL yang membuat data
# training: <91, <181, <366, <731, <1461.
AGE_BAND_THRESHOLDS = [91, 181, 366, 731, 1461]
AGE_BAND_LABELS = [
    "000_090_DAYS",
    "091_180_DAYS",
    "181_365_DAYS",
    "366_730_DAYS",
    "731_1460_DAYS",
    "1461_PLUS_DAYS",
]

# --- Prediksi ---------------------------------------------------------------
# Semua horizon adalah kelipatan 30 hari supaya setiap titik merupakan hasil
# hazard chaining langsung, tanpa interpolasi.
PREDICTION_HORIZON_DAYS = [30, 60, 90, 120]

# Kelompok risiko dibandingkan terhadap base rate validasi (persentase
# kerusakan sungguhan), bukan ambang absolut yang dikarang.
RISK_HIGH_MULTIPLIER = 3.0
RISK_MEDIUM_MULTIPLIER = 1.0

# --- Kanonikalisasi teks (client/lokasi) ------------------------------------
# Mapping yang sudah disetujui reviewer pada fase research. Disimpan sebagai
# konstanta supaya production tidak bergantung pada tabel di schema analytics.
APPROVED_LOCATION_ALIAS = {"GUDANG NUTECH": "GUDANG NI"}
APPROVED_CLIENT_ALIAS: dict[str, str] = {}
TEXT_ABBREVIATION_MAPPING = {"JKT": "JAKARTA"}

# Kandidat fuzzy diterima otomatis hanya kalau sangat mirip DAN jauh lebih
# mirip dibanding kandidat kedua.
FUZZY_MIN_SCORE = 0.90
FUZZY_MIN_MARGIN = 0.08


def db_settings() -> dict[str, str]:
    """Kredensial database dari .env / environment. Production hanya membaca."""
    load_dotenv(PACKAGE_DIR / ".env")
    required = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
    missing = [name for name in required if not os.getenv(name)]
    if missing:
        raise RuntimeError(
            "Konfigurasi database belum lengkap: "
            + ", ".join(missing)
            + ". Salin .env.example menjadi .env lalu isi nilainya."
        )
    return {
        "host": os.environ["DB_HOST"],
        "port": os.environ["DB_PORT"],
        "dbname": os.environ["DB_NAME"],
        "user": os.environ["DB_USER"],
        "password": os.environ["DB_PASSWORD"],
        "sslmode": os.getenv("DB_SSLMODE", "prefer"),
    }
