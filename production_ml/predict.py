"""Prediksi risiko kerusakan untuk satu PART.

    from predict import predict
    predict("PART-A")

Pemanggil cukup memberi ID PART. Seluruh fitur dihitung sendiri dari riwayat
PART tersebut di database - backend tidak perlu tahu apa pun soal umur,
jumlah kerusakan, client, atau fitur lainnya.

Risiko untuk beberapa horizon dihitung dengan "hazard chaining": model 30
hari yang sama dipakai berulang, dengan fitur waktu dimajukan 30 hari setiap
langkah, lalu peluang bertahan dikalikan berantai:

    P(rusak dalam 30k hari) = 1 - hasil kali (1 - hazard tiap langkah)

Cara ini menjamin risiko 30 hari <= 60 hari <= 90 hari <= 120 hari secara
matematis, dan pada pengujian research terbukti lebih akurat daripada
melatih model terpisah untuk tiap horizon.
"""

from __future__ import annotations

import json
import sys

import joblib
from catboost import CatBoostClassifier

import config
import data_reader
import feature_builder

_LOADED: tuple[CatBoostClassifier, object, dict] | None = None


class ItemNotScorable(LookupError):
    """PART tidak dikenal, atau sedang tidak terpasang sehingga tidak ada
    risiko kerusakan yang perlu diperkirakan."""


def _load_model() -> tuple[CatBoostClassifier, object, dict]:
    """Muat model production sekali per proses."""
    global _LOADED
    if _LOADED is not None:
        return _LOADED

    pointer = config.FAILURE_MODEL_DIR / "CURRENT"
    if not pointer.exists():
        raise FileNotFoundError(
            f"Belum ada model kerusakan di {config.FAILURE_MODEL_DIR}. "
            "Jalankan dulu: python train.py"
        )
    directory = config.FAILURE_MODEL_DIR / pointer.read_text(encoding="utf-8").strip()

    model = CatBoostClassifier()
    model.load_model(str(directory / "model.cbm"))
    calibrator = joblib.load(directory / "calibrator.joblib")
    metadata = json.loads((directory / "metadata.json").read_text(encoding="utf-8"))
    _LOADED = (model, calibrator, metadata)
    return _LOADED


def _risk_level(probability: float, cutoffs: dict[str, float]) -> str:
    """Kelompokkan risiko memakai ambang yang ditetapkan saat training.

    Ambangnya diturunkan dari kapasitas kerja yang ditetapkan bisnis, bukan
    angka bulat yang dikarang: sebanyak PART yang sanggup ditindaklanjuti per
    bulan itulah yang masuk kelompok HIGH. Lihat config.py.
    """
    if probability >= cutoffs["high"]:
        return "HIGH"
    if probability >= cutoffs["medium"]:
        return "MEDIUM"
    return "LOW"


def predict(item_id: str) -> dict:
    """Perkirakan risiko kerusakan sebuah PART.

    Mengembalikan peluang kerusakan untuk tiap horizon, kelompok risiko, dan
    keterangan versi model serta tanggal data yang dipakai.

    Melempar ItemNotScorable kalau PART tidak dikenal atau sedang tidak
    terpasang.
    """
    model, calibrator, metadata = _load_model()

    data_end = data_reader.get_dataset_max_event_on()
    cycles = data_reader.get_cycles(item_id, data_end)
    if cycles.empty:
        raise ItemNotScorable(f"PART '{item_id}' tidak ditemukan di database.")

    snapshot = feature_builder.current_observations(cycles)
    if snapshot.empty:
        raise ItemNotScorable(
            f"PART '{item_id}' sedang tidak terpasang (sudah rusak atau sudah "
            "dipasang ulang), jadi tidak ada risiko yang perlu diperkirakan."
        )

    events = data_reader.get_events(item_id)
    snapshot = feature_builder.attach_history(snapshot, events)
    support = feature_builder.part_model_support(
        snapshot, metadata["part_model_support"]
    )

    # Hazard tiap 30 hari, lalu dirantai jadi risiko kumulatif.
    steps = max(config.PREDICTION_HORIZON_DAYS) // config.OBSERVATION_STEP_DAYS
    survival = 1.0
    tier_score = 0.0
    cumulative_risk: dict[int, float] = {}
    for step in range(steps):
        features = feature_builder.project_features(snapshot, support, step)
        raw = float(model.predict_proba(features)[:, 1][0])
        if step == 0:
            # Kelompok risiko memakai skor mentah langkah pertama: urutannya
            # sama dengan probabilitas terkalibrasi, tetapi nilainya jauh
            # lebih halus sehingga batas kapasitas bisa tepat. Lihat train.py.
            tier_score = raw
        hazard = float(calibrator.predict([raw])[0])
        survival *= 1.0 - hazard
        cumulative_risk[(step + 1) * config.OBSERVATION_STEP_DAYS] = 1.0 - survival

    probabilities = {
        f"failure_probability_{days}d": round(cumulative_risk[days], 4)
        for days in config.PREDICTION_HORIZON_DAYS
    }

    return {
        "item_id": snapshot["item_identifier_clean"].iloc[0],
        **probabilities,
        "risk_level": _risk_level(tier_score, metadata["risk_cutoffs"]),
        "model_version": metadata["model_version"],
        "as_of": str(snapshot["observation_on"].iloc[0]),
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Cara pakai: python predict.py <ITEM_ID>")
    try:
        print(json.dumps(predict(sys.argv[1]), indent=2, ensure_ascii=False))
    except ItemNotScorable as error:
        raise SystemExit(f"[TIDAK BISA DISKOR] {error}")
