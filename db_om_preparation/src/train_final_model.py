"""Latih model baseline resmi (kelompok fitur C, aturan RECON-verified),
lalu simpan model, kalibrator, dan metadata supaya bisa dipakai scoring
tanpa harus melatih ulang dari notebook setiap kali.

Konfigurasi (fitur, aturan kelayakan, hyperparameter) mengikuti hasil yang
sudah diuji di notebooks/05_final_baseline_tuned.ipynb. Jalankan ulang
script ini kalau pipeline SQL diperbarui atau kalau ingin melatih ulang
dengan data terbaru.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

import joblib
import pandas as pd
from catboost import CatBoostClassifier, Pool
from sklearn.isotonic import IsotonicRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score

from database import PROJECT_DIR, connect

CATEGORICAL_FEATURES = ["part_model_category", "client_category", "installation_age_band"]
NUMERIC_FEATURES = [
    "log_days_since_installation", "log_total_prior_events", "log_prior_failure_count",
    "has_prior_failure", "log_prior_corrective_count", "has_prior_corrective",
    "log_days_since_last_corrective", "log_prior_distinct_places", "log_prior_corrective_30d",
    "log_prior_failure_365d", "log_prior_events_180d", "month_sin", "month_cos",
]
FEATURE_COLUMNS = CATEGORICAL_FEATURES + NUMERIC_FEATURES
BEST_PARAMS = {"depth": 4, "learning_rate": 0.03, "l2_leaf_reg": 10}
RANDOM_STATE = 42

MODEL_DIR = PROJECT_DIR / "models"
MODEL_PATH = MODEL_DIR / "failure_30d_baseline_catboost.cbm"
CALIBRATOR_PATH = MODEL_DIR / "failure_30d_baseline_calibrator.joblib"
METADATA_PATH = MODEL_DIR / "failure_30d_baseline_metadata.json"


def query(sql: str) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])


def load_dataset() -> pd.DataFrame:
    dataset = query("""
        SELECT f.*, l.target_failure_30d, l.temporal_split
        FROM analytics.failure_30d_baseline_features f
        JOIN analytics.failure_30d_model_labels l
          USING (installation_cycle_id, item_identifier_clean, observation_on)
        WHERE l.temporal_split IN ('TRAIN_2014_2024', 'VALIDATION_2025', 'TEST_2026')
          AND l.is_recon_verified_training_eligible
    """)
    dataset[CATEGORICAL_FEATURES] = dataset[CATEGORICAL_FEATURES].astype(str)
    dataset[NUMERIC_FEATURES] = dataset[NUMERIC_FEATURES].apply(pd.to_numeric)
    dataset["target_failure_30d"] = dataset["target_failure_30d"].astype(bool)
    return dataset


def main() -> int:
    MODEL_DIR.mkdir(exist_ok=True)
    dataset = load_dataset()

    splits = {
        name: dataset.loc[dataset.temporal_split.eq(name)]
        for name in ["TRAIN_2014_2024", "VALIDATION_2025", "TEST_2026"]
    }
    train, val, test = splits["TRAIN_2014_2024"], splits["VALIDATION_2025"], splits["TEST_2026"]

    train_pool = Pool(train[FEATURE_COLUMNS], train["target_failure_30d"], cat_features=CATEGORICAL_FEATURES)
    val_pool = Pool(val[FEATURE_COLUMNS], val["target_failure_30d"], cat_features=CATEGORICAL_FEATURES)

    model = CatBoostClassifier(
        iterations=3000, loss_function="Logloss", eval_metric="AUC",
        auto_class_weights="Balanced", random_seed=RANDOM_STATE,
        early_stopping_rounds=150, verbose=False, thread_count=1, **BEST_PARAMS,
    )
    model.fit(train_pool, eval_set=val_pool)

    proba_train = model.predict_proba(train[FEATURE_COLUMNS])[:, 1]
    proba_val = model.predict_proba(val[FEATURE_COLUMNS])[:, 1]
    proba_test = model.predict_proba(test[FEATURE_COLUMNS])[:, 1]

    calibrator = IsotonicRegression(out_of_bounds="clip")
    calibrator.fit(proba_val, val["target_failure_30d"].astype(int))
    proba_test_calibrated = calibrator.predict(proba_test)

    metrics = {
        "train": {
            "rows": int(len(train)), "positives": int(train["target_failure_30d"].sum()),
            "roc_auc": float(roc_auc_score(train["target_failure_30d"], proba_train)),
            "pr_auc": float(average_precision_score(train["target_failure_30d"], proba_train)),
        },
        "validation": {
            "rows": int(len(val)), "positives": int(val["target_failure_30d"].sum()),
            "roc_auc": float(roc_auc_score(val["target_failure_30d"], proba_val)),
            "pr_auc": float(average_precision_score(val["target_failure_30d"], proba_val)),
        },
        "test": {
            "rows": int(len(test)), "positives": int(test["target_failure_30d"].sum()),
            "roc_auc": float(roc_auc_score(test["target_failure_30d"], proba_test)),
            "pr_auc": float(average_precision_score(test["target_failure_30d"], proba_test)),
            "brier_raw": float(brier_score_loss(test["target_failure_30d"], proba_test)),
            "brier_calibrated": float(brier_score_loss(test["target_failure_30d"], proba_test_calibrated)),
        },
    }

    model.save_model(str(MODEL_PATH))
    joblib.dump(calibrator, CALIBRATOR_PATH)
    metadata = {
        "trained_at_utc": datetime.now(timezone.utc).isoformat(),
        "feature_columns": FEATURE_COLUMNS,
        "categorical_features": CATEGORICAL_FEATURES,
        "hyperparameters": BEST_PARAMS,
        "eligibility_rule": "is_recon_verified_training_eligible",
        "source_view": "analytics.failure_30d_baseline_features",
        "best_iteration": model.get_best_iteration(),
        "metrics": metrics,
        "notes": (
            "Baseline resmi (kelompok fitur C, 16 fitur). Fitur lokasi/TERMINAL "
            "belum dipakai karena belum terbukti cukup bernilai (lihat "
            "notebooks/03_ablation_study.ipynb). Selisih ROC-AUC "
            "validasi-test kecil (lihat notebooks/05_final_baseline_tuned.ipynb), "
            "tidak ada tanda overfitting."
        ),
    }
    METADATA_PATH.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"[OK] Model disimpan: {MODEL_PATH}")
    print(f"[OK] Kalibrator disimpan: {CALIBRATOR_PATH}")
    print(f"[OK] Metadata disimpan: {METADATA_PATH}")
    print(f"ROC-AUC train={metrics['train']['roc_auc']:.4f} "
          f"val={metrics['validation']['roc_auc']:.4f} "
          f"test={metrics['test']['roc_auc']:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
