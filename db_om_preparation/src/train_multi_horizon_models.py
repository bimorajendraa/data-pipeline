"""Latih model challenger untuk horizon 90 dan 180 hari (Bagian 12 master
prompt), TERPISAH dari model klasifikasi 30 hari resmi (train_final_model.py)
- tidak menimpa file model itu. Fitur dan hyperparameter dibuat identik
dengan model 30 hari resmi supaya perbandingan antar-horizon adil (bukan
mengubah fitur per horizon tanpa bukti).

PENTING - keterbatasan TEST_2026 untuk horizon 180 hari: observation_on
setelah (dataset_max_event_on - 180 hari) hanya bisa lolos syarat kelayakan
lewat cabang GAGAL (hasil negatif belum bisa dikonfirmasi penuh) - ini
artefak seleksi di ekor data, bukan sinyal bisnis. Evaluasi TEST_2026 untuk
180 hari HARUS dibatasi ke observation_on <= dataset_max_event_on - 180 hari
supaya adil (lihat models/failure_multi_horizon_metadata.json untuk detail
dan angka sebelum/sesudah koreksi).

Jalankan ulang script ini kalau pipeline SQL diperbarui.
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
    "log_prior_failure_365d", "log_prior_events_180d", "log_previous_cycle_lifetime_mean",
    "has_previous_cycle", "month_sin", "month_cos",
]
FEATURE_COLUMNS = CATEGORICAL_FEATURES + NUMERIC_FEATURES
BEST_PARAMS = {"depth": 4, "learning_rate": 0.03, "l2_leaf_reg": 10}
RANDOM_STATE = 42
HORIZONS = ["90d", "180d"]
# Batas observation_on untuk evaluasi TEST_2026 180 hari yang adil - lihat
# docstring modul.
CLEAN_180D_BOUNDARY = "2026-02-04"

MODEL_DIR = PROJECT_DIR / "models"


def query(sql: str) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])


def load_dataset(horizon: str) -> pd.DataFrame:
    dataset = query(f"""
        SELECT f.*, l.target_failure_{horizon} AS target, l.temporal_split_{horizon} AS split
        FROM analytics.failure_30d_baseline_features f
        JOIN analytics.failure_multi_horizon_labels l
          USING (installation_cycle_id, item_identifier_clean, observation_on)
        WHERE l.temporal_split_{horizon} IN ('TRAIN_2014_2024', 'VALIDATION_2025', 'TEST_2026')
          AND l.is_{horizon}_training_eligible
    """)
    dataset[CATEGORICAL_FEATURES] = dataset[CATEGORICAL_FEATURES].astype(str)
    dataset[NUMERIC_FEATURES] = dataset[NUMERIC_FEATURES].apply(pd.to_numeric)
    dataset["target"] = dataset["target"].astype(bool)
    return dataset


def check_monotonicity(test_scored: dict[str, pd.DataFrame]) -> dict:
    """P(<=30h) <= P(<=90h) <= P(<=180h) baris-per-baris, memakai model 30 hari
    RESMI (sudah tersimpan) plus dua model challenger yang baru dilatih.
    """
    model_30d = CatBoostClassifier()
    model_30d.load_model(str(MODEL_DIR / "failure_30d_baseline_catboost.cbm"))
    calibrator_30d = joblib.load(MODEL_DIR / "failure_30d_baseline_calibrator.joblib")

    keys = ["installation_cycle_id", "item_identifier_clean", "observation_on"]
    common = test_scored["90d"][keys].merge(test_scored["180d"][keys], on=keys, how="inner")

    dataset_30d = query(f"""
        SELECT f.*, l.temporal_split_30d AS split
        FROM analytics.failure_30d_baseline_features f
        JOIN analytics.failure_multi_horizon_labels l
          USING (installation_cycle_id, item_identifier_clean, observation_on)
        WHERE l.temporal_split_30d = 'TEST_2026' AND l.is_30d_training_eligible
    """)
    dataset_30d[CATEGORICAL_FEATURES] = dataset_30d[CATEGORICAL_FEATURES].astype(str)
    dataset_30d[NUMERIC_FEATURES] = dataset_30d[NUMERIC_FEATURES].apply(pd.to_numeric)
    common = common.merge(dataset_30d, on=keys, how="inner")
    if common.empty:
        return {"description": "Tidak ada populasi TEST_2026 yang eligible di ketiga horizon sekaligus."}

    p30 = calibrator_30d.predict(model_30d.predict_proba(common[FEATURE_COLUMNS])[:, 1])
    merged = common[keys].copy()
    merged["p_30d"] = p30
    for horizon in HORIZONS:
        merged = merged.merge(
            test_scored[horizon][keys + ["proba_cal"]].rename(columns={"proba_cal": f"p_{horizon}"}),
            on=keys, how="left",
        )

    boundary = pd.Timestamp(CLEAN_180D_BOUNDARY)
    clean = merged.observation_on <= boundary

    def violation_rates(frame: pd.DataFrame) -> dict:
        return {
            "n": int(len(frame)),
            "violation_30_vs_90_pct": round(float((frame.p_30d > frame.p_90d).mean() * 100), 2),
            "violation_90_vs_180_pct": round(float((frame.p_90d > frame.p_180d).mean() * 100), 2),
            "violation_30_vs_180_pct": round(float((frame.p_30d > frame.p_180d).mean() * 100), 2),
        }

    return {
        "description": (
            "P(gagal <=30 hari) <= P(gagal <=90 hari) <= P(gagal <=180 hari), diperiksa "
            "baris-per-baris pada TEST_2026 yang eligible di ketiga horizon sekaligus, "
            "memakai skor terkalibrasi. 'population_clean_subset_only' membuang baris "
            "boundary-contaminated (observation_on > dataset_max_event_on - 180 hari)."
        ),
        "population_all": violation_rates(merged),
        "population_clean_subset_only": violation_rates(merged.loc[clean]),
        "interpretation": (
            "Pelanggaran 30d-vs-90d dan 30d-vs-180d biasanya sangat jarang (<1%). "
            "Pelanggaran 90d-vs-180d cenderung jauh lebih tinggi BAHKAN pada subset bersih "
            "- ini bukan artefak boundary, melainkan konsekuensi melatih 3 model independen "
            "(tidak ada constraint yang memaksa urutan probabilitas antar-horizon konsisten "
            "per baris, sesuai antisipasi Bagian 12 master prompt). Discrete-time hazard/"
            "survival bersama (Fase 6) akan menjamin ini secara struktural."
        ),
    }


def main() -> int:
    MODEL_DIR.mkdir(exist_ok=True)
    horizon_results = {}
    test_scored = {}

    for horizon in HORIZONS:
        dataset = load_dataset(horizon)
        splits = {
            name: dataset.loc[dataset.split.eq(name)]
            for name in ["TRAIN_2014_2024", "VALIDATION_2025", "TEST_2026"]
        }
        train, val, test = splits["TRAIN_2014_2024"], splits["VALIDATION_2025"], splits["TEST_2026"]

        train_pool = Pool(train[FEATURE_COLUMNS], train["target"], cat_features=CATEGORICAL_FEATURES)
        val_pool = Pool(val[FEATURE_COLUMNS], val["target"], cat_features=CATEGORICAL_FEATURES)
        model = CatBoostClassifier(
            iterations=200, loss_function="Logloss", eval_metric="AUC",
            auto_class_weights="Balanced", random_seed=RANDOM_STATE,
            use_best_model=False, verbose=False, thread_count=1, **BEST_PARAMS,
        )
        model.fit(train_pool, eval_set=val_pool)

        proba_train = model.predict_proba(train[FEATURE_COLUMNS])[:, 1]
        proba_val = model.predict_proba(val[FEATURE_COLUMNS])[:, 1]
        proba_test = model.predict_proba(test[FEATURE_COLUMNS])[:, 1]

        calibrator = IsotonicRegression(out_of_bounds="clip")
        calibrator.fit(proba_val, val["target"].astype(int))
        proba_test_cal = calibrator.predict(proba_test)

        metrics = {
            "roc_auc_train": float(roc_auc_score(train.target, proba_train)),
            "roc_auc_test": float(roc_auc_score(test.target, proba_test)),
            "pr_auc_test": float(average_precision_score(test.target, proba_test)),
            "brier_raw": float(brier_score_loss(test.target, proba_test)),
            "brier_calibrated": float(brier_score_loss(test.target, proba_test_cal)),
            "rows": {"train": len(train), "val": len(val), "test": len(test)},
            "positives": {
                "train": int(train.target.sum()), "val": int(val.target.sum()),
                "test": int(test.target.sum()),
            },
            "base_rate_test": float(test.target.mean()),
        }

        if horizon == "180d":
            clean = test.observation_on <= pd.Timestamp(CLEAN_180D_BOUNDARY)
            proba_clean_cal = calibrator.predict(model.predict_proba(test.loc[clean, FEATURE_COLUMNS])[:, 1])
            target_clean = test.loc[clean, "target"]
            metrics["test_metric_warning"] = (
                "TEST_2026 gabungan TERKONTAMINASI boundary artifact - lihat test_2026_clean_subset."
            )
            metrics["test_2026_clean_subset"] = {
                "description": (
                    f"observation_on <= {CLEAN_180D_BOUNDARY} saja - satu-satunya rentang "
                    "dimana hasil negatif sudah bisa dikonfirmasi penuh, sama seperti positif."
                ),
                "n": int(clean.sum()),
                "base_rate": float(target_clean.mean()),
                "roc_auc": float(roc_auc_score(target_clean, proba_clean_cal)),
                "pr_auc": float(average_precision_score(target_clean, proba_clean_cal)),
                "brier_calibrated": float(brier_score_loss(target_clean, proba_clean_cal)),
            }

        model.save_model(str(MODEL_DIR / f"failure_{horizon}_baseline_catboost.cbm"))
        joblib.dump(calibrator, MODEL_DIR / f"failure_{horizon}_baseline_calibrator.joblib")
        horizon_results[horizon] = metrics
        test_scored[horizon] = test[["installation_cycle_id", "item_identifier_clean", "observation_on"]].copy()
        test_scored[horizon]["proba_cal"] = proba_test_cal
        print(f"[{horizon}] ROC-AUC train={metrics['roc_auc_train']:.4f} "
              f"test={metrics['roc_auc_test']:.4f}  PR-AUC test={metrics['pr_auc_test']:.4f}")

    monotonicity = check_monotonicity(test_scored)
    print(f"[monotonicity] {monotonicity.get('population_clean_subset_only')}")

    metadata = {
        "trained_at_utc": datetime.now(timezone.utc).isoformat(),
        "feature_columns": FEATURE_COLUMNS,
        "categorical_features": CATEGORICAL_FEATURES,
        "hyperparameters": BEST_PARAMS,
        "notes": (
            "Model challenger 90/180 hari, fitur & hyperparameter identik dengan model "
            "resmi 30 hari (train_final_model.py) supaya perbandingan adil. TIDAK "
            "menggantikan model 30 hari resmi. Lihat docstring modul untuk keterbatasan "
            "evaluasi TEST_2026 180 hari (boundary artifact)."
        ),
        "horizons": horizon_results,
        "monotonicity_check": monotonicity,
    }
    (MODEL_DIR / "failure_multi_horizon_metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"[OK] Metadata disimpan: {MODEL_DIR / 'failure_multi_horizon_metadata.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
