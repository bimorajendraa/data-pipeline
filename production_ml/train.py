"""Latih (atau latih ulang) model risiko kerusakan PART 30 hari.

    python train.py

Alurnya:

    database -> observasi + target -> fitur -> latih -> evaluasi -> simpan

Setiap kali dijalankan, hasilnya disimpan sebagai versi BARU di models/vN/.
Model production hanya diganti kalau versi baru tidak lebih buruk pada data
uji; kalau lebih buruk, versinya tetap tersimpan lengkap dengan metriknya
supaya bisa dibandingkan, tetapi production tetap memakai model lama.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone

import joblib
import numpy as np
import pandas as pd
from catboost import CatBoostClassifier, Pool
from sklearn.isotonic import IsotonicRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score

import config
import data_reader
import feature_builder

TRAIN, VALIDATION, TEST = "TRAIN", "VALIDATION", "TEST"
CURRENT_POINTER = config.MODEL_DIR / "CURRENT"


# ---------------------------------------------------------------------------
# Dataset
# ---------------------------------------------------------------------------


def assign_split(observations: pd.DataFrame, data_end: pd.Timestamp) -> pd.Series:
    """Bagi data berdasarkan WAKTU, bukan acak - model harus diuji pada periode
    yang belum pernah dilihatnya.

    Tahun terakhir yang ada di data jadi data uji, setahun sebelumnya jadi
    validasi, sisanya data latih. Di antara blok ada jeda (embargo) selebar
    horizon target: snapshot yang jawabannya baru terungkap di periode
    berikutnya dibuang, supaya jawaban periode uji tidak bocor ke data latih.
    """
    observed = pd.to_datetime(observations["observation_on"])
    resolved = observed + np.timedelta64(config.TARGET_HORIZON_DAYS, "D")

    test_start = pd.Timestamp(year=data_end.year, month=1, day=1)
    validation_start = test_start - pd.DateOffset(years=1)

    split = pd.Series("EXCLUDED_EMBARGO", index=observations.index)
    split[observed < pd.Timestamp(config.MIN_OBSERVATION_DATE)] = "EXCLUDED_TOO_OLD"
    split[
        (observed >= pd.Timestamp(config.MIN_OBSERVATION_DATE))
        & (resolved < validation_start)
    ] = TRAIN
    split[(observed >= validation_start) & (resolved < test_start)] = VALIDATION
    split[observed >= test_start] = TEST
    return split


def build_dataset() -> tuple[pd.DataFrame, pd.DataFrame, dict[str, int], pd.Timestamp]:
    """Baca database lalu susun observasi, target, dan fitur."""
    print("[1/5] Membaca event dan siklus pemasangan dari database...")
    events = data_reader.get_events()
    cycles = data_reader.get_cycles()
    data_end = pd.Timestamp(cycles["dataset_max_event_on"].max())
    print(f"      {len(events):,} event, {len(cycles):,} siklus, data s/d {data_end}")

    print("[2/5] Menyusun observasi 30-harian dan target...")
    observations = feature_builder.training_observations(cycles)
    observations = feature_builder.attach_history(observations, events)

    # Dukungan historis dihitung dari SELURUH observasi, sebelum penyaringan
    # kelayakan, supaya nilainya benar-benar point-in-time.
    support = feature_builder.cumulative_support(observations)
    support_totals = feature_builder.support_totals(observations)

    eligible = observations["is_eligible"].to_numpy()
    dataset = observations.loc[eligible].reset_index(drop=True)
    dataset["split"] = assign_split(dataset, data_end)
    print(
        f"      {len(observations):,} observasi -> {len(dataset):,} layak dilatih "
        f"({int(dataset['target_failure'].sum()):,} kerusakan)"
    )

    print("[3/5] Menghitung fitur...")
    features = feature_builder.build_features(
        dataset, support.loc[eligible].reset_index(drop=True)
    )
    return dataset, features, support_totals, data_end


# ---------------------------------------------------------------------------
# Training dan evaluasi
# ---------------------------------------------------------------------------


def evaluate(target: pd.Series, raw: np.ndarray, calibrated: np.ndarray | None = None) -> dict:
    metrics = {
        "rows": int(len(target)),
        "positives": int(target.sum()),
        "roc_auc": float(roc_auc_score(target, raw)),
        "pr_auc": float(average_precision_score(target, raw)),
    }
    if calibrated is not None:
        metrics["brier_raw"] = float(brier_score_loss(target, raw))
        metrics["brier_calibrated"] = float(brier_score_loss(target, calibrated))
    return metrics


def train_model(dataset: pd.DataFrame, features: pd.DataFrame) -> tuple:
    parts = {name: dataset["split"].eq(name).to_numpy() for name in (TRAIN, VALIDATION, TEST)}
    for name, mask in parts.items():
        if not mask.any():
            raise SystemExit(f"Tidak ada baris untuk bagian {name}. Data belum cukup.")

    target = dataset["target_failure"].astype(bool)
    train_x, train_y = features[parts[TRAIN]], target[parts[TRAIN]]
    val_x, val_y = features[parts[VALIDATION]], target[parts[VALIDATION]]
    test_x, test_y = features[parts[TEST]], target[parts[TEST]]

    print(
        f"[4/5] Melatih model: latih={len(train_x):,} validasi={len(val_x):,} uji={len(test_x):,}"
    )
    if test_y.sum() < 30:
        print(
            f"      PERINGATAN: hanya {int(test_y.sum())} kerusakan di data uji - "
            "metrik uji akan sangat berisik. Pertimbangkan menunggu data lebih banyak."
        )

    model = CatBoostClassifier(
        random_seed=config.RANDOM_STATE, **config.CATBOOST_PARAMS
    )
    model.fit(
        Pool(train_x, train_y, cat_features=config.CATEGORICAL_FEATURES),
        eval_set=Pool(val_x, val_y, cat_features=config.CATEGORICAL_FEATURES),
    )

    raw_train = model.predict_proba(train_x)[:, 1]
    raw_val = model.predict_proba(val_x)[:, 1]
    raw_test = model.predict_proba(test_x)[:, 1]

    # Skor mentah CatBoost bagus untuk MENGURUTKAN risiko, tapi tidak bisa
    # dibaca sebagai probabilitas. Kalibrator memetakannya ke persentase yang
    # benar-benar mencerminkan frekuensi kerusakan sungguhan.
    calibrator = IsotonicRegression(out_of_bounds="clip")
    calibrator.fit(raw_val, val_y.astype(int))

    metrics = {
        "train": evaluate(train_y, raw_train),
        "validation": evaluate(val_y, raw_val),
        "test": evaluate(test_y, raw_test, calibrator.predict(raw_test)),
    }
    return model, calibrator, metrics


# ---------------------------------------------------------------------------
# Penyimpanan versi
# ---------------------------------------------------------------------------


def next_version() -> str:
    existing = [
        int(path.name[1:])
        for path in config.MODEL_DIR.glob("v*")
        if path.is_dir() and path.name[1:].isdigit()
    ]
    return f"v{max(existing, default=0) + 1}"


def current_version() -> str | None:
    if not CURRENT_POINTER.exists():
        return None
    version = CURRENT_POINTER.read_text(encoding="utf-8").strip()
    return version if (config.MODEL_DIR / version / "metadata.json").exists() else None


def load_metadata(version: str) -> dict:
    path = config.MODEL_DIR / version / "metadata.json"
    return json.loads(path.read_text(encoding="utf-8"))


def save_version(
    version: str,
    model: CatBoostClassifier,
    calibrator: IsotonicRegression,
    metrics: dict,
    support_totals: dict[str, int],
    dataset: pd.DataFrame,
    data_end: pd.Timestamp,
) -> dict:
    directory = config.MODEL_DIR / version
    directory.mkdir(parents=True, exist_ok=True)

    model.save_model(str(directory / "model.cbm"))
    joblib.dump(calibrator, directory / "calibrator.joblib")

    observed = pd.to_datetime(dataset["observation_on"])
    validation = metrics["validation"]
    metadata = {
        "model_version": version,
        "training_date": datetime.now(timezone.utc).isoformat(),
        "training_period": {
            "observation_from": str(observed.min()),
            "observation_to": str(observed.max()),
            "dataset_max_event_on": str(data_end),
            "rows_by_split": dataset["split"].value_counts().to_dict(),
        },
        "target": (
            f"PART mengalami kerusakan dalam {config.TARGET_HORIZON_DAYS} hari "
            "setelah tanggal observasi"
        ),
        "features": config.FEATURE_COLUMNS,
        "categorical_features": config.CATEGORICAL_FEATURES,
        "hyperparameters": {**config.CATBOOST_PARAMS, "random_seed": config.RANDOM_STATE},
        "evaluation_metrics": metrics,
        # Base rate validasi jadi jangkar kelompok risiko: "tinggi" berarti
        # tinggi dibanding kenyataan historis, bukan dibanding angka karangan.
        "validation_base_rate": validation["positives"] / validation["rows"],
        # Dibekukan supaya kategori tipe PART saat prediksi persis sama dengan
        # yang dipelajari model. Ikut diperbarui setiap kali training ulang.
        "part_model_support": support_totals,
    }
    (directory / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    return metadata


def decide_promotion(new_score: float, force: bool) -> tuple[bool, str]:
    """Boleh tidaknya model baru menggantikan model production.

    Model baru yang lebih buruk pada data uji TIDAK otomatis dipakai - hasil
    latihnya tetap disimpan supaya bisa dibandingkan, tetapi production tidak
    ikut turun kualitas hanya karena training ulang sudah dijalankan.
    """
    previous = current_version()
    if previous is None:
        return True, "belum ada model production sebelumnya"

    old_score = load_metadata(previous)["evaluation_metrics"]["test"]["roc_auc"]
    comparison = f"ROC-AUC uji {new_score:.4f} vs {previous} {old_score:.4f}"
    if new_score >= old_score:
        return True, comparison
    if force:
        return True, f"{comparison} - dipaksa lewat --force-promote"
    return False, comparison


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force-promote",
        action="store_true",
        help="Pakai model baru sebagai production walaupun hasil ujinya lebih buruk.",
    )
    args = parser.parse_args()

    config.MODEL_DIR.mkdir(parents=True, exist_ok=True)
    dataset, features, support_totals, data_end = build_dataset()
    model, calibrator, metrics = train_model(dataset, features)

    version = next_version()
    save_version(version, model, calibrator, metrics, support_totals, dataset, data_end)

    print(f"[5/5] Tersimpan sebagai {version} di {config.MODEL_DIR / version}")
    for name in ("train", "validation", "test"):
        part = metrics[name]
        print(
            f"      {name:10s} baris={part['rows']:>7,} kerusakan={part['positives']:>5,} "
            f"ROC-AUC={part['roc_auc']:.4f} PR-AUC={part['pr_auc']:.4f}"
        )
    print(f"      Brier terkalibrasi (uji) = {metrics['test']['brier_calibrated']:.4f}")

    previous = current_version()
    promote, reason = decide_promotion(metrics["test"]["roc_auc"], args.force_promote)

    if promote:
        CURRENT_POINTER.write_text(version, encoding="utf-8")
        print(f"\n[OK] {version} dipakai sebagai model production ({reason}).")
    else:
        print(
            f"\n[TAHAN] Model production TETAP {previous} - {reason}.\n"
            f"        {version} tetap tersimpan untuk dibandingkan. Untuk tetap "
            f"memakainya: python train.py --force-promote, atau tulis '{version}' "
            f"ke {CURRENT_POINTER}."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
