"""Feature engineering: kolom mentah -> 18 fitur final model.

SATU-SATUNYA tempat fitur dihitung. Training dan prediction sama-sama memanggil
`build_features`, jadi tidak mungkin ada perbedaan antara fitur yang dipelajari
model dan fitur yang dipakai saat production.

Semua hitungan count/durasi memakai LN(1+x): distribusinya sangat right-skewed,
dan tanpa transformasi ini beberapa outlier akan mendominasi.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

import config


_DAY = np.timedelta64(1, "D")

# Kolom agregat riwayat yang dihasilkan attach_history.
_HISTORY_COUNTS = [
    "total_prior_events",
    "prior_failure_count",
    "prior_corrective_count",
    "prior_corrective_30d",
    "prior_failure_365d",
    "prior_events_180d",
    "prior_distinct_places",
]


# ---------------------------------------------------------------------------
# Pembentukan observasi
# ---------------------------------------------------------------------------


def training_observations(cycles: pd.DataFrame) -> pd.DataFrame:
    """Snapshot training pada grid tetap 30 hari sejak tanggal pemasangan.

    Grid dibuat untuk SELURUH siklus dalam cohort (bukan hanya yang layak
    dilatih) karena dukungan historis tipe PART dihitung dari seluruh
    observasi; penyaringan kelayakan dilakukan setelahnya.
    """
    cohort = cycles.loc[
        cycles["is_initial_model_cohort"].fillna(False)
        & (cycles["installed_on"] < cycles["cycle_end_on"])
    ].reset_index(drop=True)

    installed = cohort["installed_on"].to_numpy("datetime64[ns]")
    ends = cohort["cycle_end_on"].to_numpy("datetime64[ns]")
    step = np.timedelta64(config.OBSERVATION_STEP_DAYS, "D")

    # Observasi terakhir harus benar-benar SEBELUM siklus berakhir.
    span = ends - installed - np.timedelta64(1, "us")
    n_steps = (span // step).astype("int64") + 1

    row = np.repeat(np.arange(len(cohort)), n_steps)
    offset = np.arange(n_steps.sum()) - np.repeat(
        np.cumsum(n_steps) - n_steps, n_steps
    )
    observations = cohort.iloc[row].reset_index(drop=True)
    observations["observation_on"] = installed[row] + offset * step

    failure = observations["failure_onset_on"].to_numpy("datetime64[ns]")
    observed = observations["observation_on"].to_numpy("datetime64[ns]")
    horizon = np.timedelta64(config.TARGET_HORIZON_DAYS, "D")
    observations["target_failure"] = (failure > observed) & (
        failure <= observed + horizon
    )

    # Sebuah baris hanya dipakai kalau hasilnya benar-benar bisa dipastikan:
    # positif kalau failure terjadi dalam horizon, negatif kalau 30 hari ke
    # depan sudah sepenuhnya terekam DAN siklusnya memang layak jadi negatif.
    observations["is_eligible"] = observations["target_failure"] | (
        observations["is_recon_verified_negative_eligible"].fillna(False)
        & (
            observations["observation_on"]
            <= observations["last_confirmable_observation_on"]
        )
    )
    return _finalize_observations(observations)


def current_observations(cycles: pd.DataFrame) -> pd.DataFrame:
    """Satu snapshot per PART yang saat ini masih terpasang.

    Diambil pada kejadian terbaru yang tercatat, BUKAN pada grid 30 hari
    seperti dataset training - kalau memakai grid, skor sebuah PART bisa
    tertinggal sampai ~29 hari dari kondisi terakhir yang sudah diketahui.
    """
    active = cycles.loc[
        cycles["is_initial_model_cohort"].fillna(False)
        & cycles["cycle_end_reason"].eq("RIGHT_CENSORED_AT_DATA_END")
    ].copy()
    active["observation_on"] = active["dataset_max_event_on"]
    return _finalize_observations(active)


def _finalize_observations(observations: pd.DataFrame) -> pd.DataFrame:
    observations = observations.reset_index(drop=True)
    observations["days_since_installation"] = (
        observations["observation_on"].to_numpy("datetime64[ns]")
        - observations["installed_on"].to_numpy("datetime64[ns]")
    ) / _DAY
    return observations


# ---------------------------------------------------------------------------
# Agregat riwayat point-in-time
# ---------------------------------------------------------------------------


def attach_history(observations: pd.DataFrame, events: pd.DataFrame) -> pd.DataFrame:
    """Tambahkan ringkasan riwayat item pada setiap observasi.

    HANYA memakai event pada atau sebelum observation_on, jadi secara
    konstruksi tidak mungkin mengambil informasi masa depan.
    """
    observations = observations.reset_index(drop=True)
    total = len(observations)
    counts = {name: np.zeros(total, dtype="int64") for name in _HISTORY_COUNTS}
    last_corrective = np.full(total, np.datetime64("NaT"), dtype="datetime64[ns]")
    observed_at = observations["observation_on"].to_numpy("datetime64[ns]")

    if total and len(events):
        events = events.sort_values(
            ["item_identifier_clean", "created_on"], kind="stable"
        )
        event_times = events["created_on"].to_numpy("datetime64[ns]")
        is_corrective = events["wo_type_clean"].eq("CORRECTIVE").to_numpy()
        is_failure = events["is_failure_onset"].fillna(False).to_numpy(dtype=bool)
        is_new_place = _first_occurrence(events)
        event_rows = events.groupby("item_identifier_clean", sort=False).indices

        window_30 = np.timedelta64(30, "D")
        window_180 = np.timedelta64(180, "D")
        window_365 = np.timedelta64(365, "D")

        for item, rows in observations.groupby(
            "item_identifier_clean", sort=False
        ).indices.items():
            slot = event_rows.get(item)
            if slot is None:
                continue
            times = event_times[slot]
            cumulative_failure = np.cumsum(is_failure[slot])
            cumulative_corrective = np.cumsum(is_corrective[slot])
            cumulative_place = np.cumsum(is_new_place[slot])
            corrective_times = times[is_corrective[slot]]

            at = observed_at[rows]
            seen = np.searchsorted(times, at, side="right")
            seen_30 = np.searchsorted(times, at - window_30, side="right")
            seen_180 = np.searchsorted(times, at - window_180, side="right")
            seen_365 = np.searchsorted(times, at - window_365, side="right")

            failure_to_date = _at(cumulative_failure, seen)
            corrective_to_date = _at(cumulative_corrective, seen)

            counts["total_prior_events"][rows] = seen
            counts["prior_failure_count"][rows] = failure_to_date
            counts["prior_corrective_count"][rows] = corrective_to_date
            counts["prior_distinct_places"][rows] = _at(cumulative_place, seen)
            counts["prior_events_180d"][rows] = seen - seen_180
            counts["prior_corrective_30d"][rows] = corrective_to_date - _at(
                cumulative_corrective, seen_30
            )
            counts["prior_failure_365d"][rows] = failure_to_date - _at(
                cumulative_failure, seen_365
            )

            has_corrective = corrective_to_date > 0
            if has_corrective.any():
                position = np.maximum(corrective_to_date - 1, 0)
                last_corrective[rows] = np.where(
                    has_corrective, corrective_times[position], np.datetime64("NaT")
                )

    for name, values in counts.items():
        observations[name] = values
    # Kosong berarti PART belum pernah kena corrective sama sekali.
    observations["days_since_last_corrective"] = (observed_at - last_corrective) / _DAY
    return observations


# ---------------------------------------------------------------------------
# Dukungan historis tipe PART
# ---------------------------------------------------------------------------


def cumulative_support(observations: pd.DataFrame) -> pd.Series:
    """Jumlah observasi tipe PART yang sama sampai titik waktu masing-masing.

    Dihitung point-in-time supaya tidak memakai informasi masa depan. Baris
    dengan observation_on identik sengaja mendapat nilai yang sama (bukan
    diurutkan sembarang), supaya hasilnya deterministik antar-run.
    """
    times = observations["observation_on"].to_numpy("datetime64[ns]")
    support = np.zeros(len(observations), dtype="int64")
    grouped = observations.groupby("item_model_code_clean", sort=False, dropna=False)
    for rows in grouped.indices.values():
        support[rows] = np.searchsorted(np.sort(times[rows]), times[rows], side="right")
    return pd.Series(support, index=observations.index)


def support_totals(observations: pd.DataFrame) -> dict[str, int]:
    """Dukungan akhir per tipe PART, untuk dibekukan ke dalam metadata model."""
    totals = observations.groupby("item_model_code_clean").size()
    return {str(model): int(count) for model, count in totals.items()}


def _at(cumulative: np.ndarray, position: np.ndarray) -> np.ndarray:
    """Nilai kumulatif setelah `position` event; 0 kalau belum ada event."""
    return np.where(position > 0, cumulative[np.maximum(position - 1, 0)], 0)


def _first_occurrence(events: pd.DataFrame) -> np.ndarray:
    """Tandai event yang memperkenalkan lokasi baru untuk item tersebut.

    Jumlah lokasi berbeda sampai suatu titik waktu = jumlah penanda ini
    sampai titik tersebut, tanpa perlu menghitung ulang himpunan lokasi.
    """
    frame = events[["item_identifier_clean", "place_canonical_clean"]]
    known = frame["place_canonical_clean"].notna()
    return (known & ~frame.duplicated()).to_numpy()


def _log1p(values: pd.Series) -> pd.Series:
    """LN(1+x) dengan nilai kosong diperlakukan sebagai 0.

    Kosong di sini berarti "belum pernah terjadi" (mis. belum pernah ada
    corrective), bukan data hilang - itulah kenapa dipasangkan dengan kolom
    penanda has_* supaya model bisa membedakan keduanya.
    """
    return np.log1p(pd.to_numeric(values, errors="coerce").fillna(0.0).clip(lower=0.0))


def _age_band(days: pd.Series) -> pd.Series:
    index = np.searchsorted(
        config.AGE_BAND_THRESHOLDS,
        pd.to_numeric(days, errors="coerce").fillna(0.0).to_numpy(),
        side="right",
    )
    return pd.Series(np.asarray(config.AGE_BAND_LABELS)[index], index=days.index)


def part_model_support(raw: pd.DataFrame, support_by_model: dict[str, int]) -> pd.Series:
    """Dukungan historis tipe PART untuk jalur prediction.

    Memakai angka yang DIBEKUKAN saat training (tersimpan di metadata), bukan
    dihitung ulang dari data terbaru. Alasannya konsistensi: kategori yang
    dikenal model adalah kategori pada saat model dilatih. Kalau sebuah tipe
    PART baru melewati ambang dukungan di antara dua kali training, menghitung
    ulang akan memunculkan kategori yang belum pernah dilihat model. Angka ini
    otomatis ikut diperbarui setiap kali `train.py` dijalankan.
    """
    return (
        raw["item_model_code_clean"]
        .map(support_by_model)
        .fillna(0)
        .astype("int64")
    )


def build_features(raw: pd.DataFrame, support: pd.Series) -> pd.DataFrame:
    """Bangun 18 fitur model dari kolom mentah hasil data_reader.

    `support` adalah dukungan historis tipe PART per baris: saat training
    dihitung point-in-time, saat prediction diambil dari metadata model.
    """
    features = pd.DataFrame(index=raw.index)

    # --- Identitas & konteks -------------------------------------------------
    model_code = raw["item_model_code_clean"]
    # Tipe PART yang riwayatnya masih sangat sedikit digabung jadi satu
    # kategori supaya model tidak menghafal pola dari sampel kecil.
    features["part_model_category"] = np.where(
        model_code.isna(),
        config.UNKNOWN_LABEL,
        np.where(
            pd.to_numeric(support, errors="coerce").fillna(0)
            < config.MIN_PART_MODEL_SUPPORT,
            config.LOW_SUPPORT_LABEL,
            model_code.astype("string").fillna(config.UNKNOWN_LABEL),
        ),
    )
    features["client_category"] = (
        raw["installed_client_clean"].fillna(config.UNKNOWN_LABEL).astype(str)
    )

    # --- Umur pemasangan -----------------------------------------------------
    days_since_installation = pd.to_numeric(
        raw["days_since_installation"], errors="coerce"
    ).fillna(0.0)
    features["installation_age_band"] = _age_band(days_since_installation)
    features["log_days_since_installation"] = _log1p(days_since_installation)

    # --- Intensitas dan jenis riwayat ---------------------------------------
    features["log_total_prior_events"] = _log1p(raw["total_prior_events"])
    features["log_prior_failure_count"] = _log1p(raw["prior_failure_count"])
    features["has_prior_failure"] = (
        pd.to_numeric(raw["prior_failure_count"], errors="coerce").fillna(0) > 0
    )
    features["log_prior_corrective_count"] = _log1p(raw["prior_corrective_count"])
    features["has_prior_corrective"] = (
        pd.to_numeric(raw["prior_corrective_count"], errors="coerce").fillna(0) > 0
    )
    features["log_days_since_last_corrective"] = _log1p(raw["days_since_last_corrective"])
    features["log_prior_distinct_places"] = _log1p(raw["prior_distinct_places"])

    # --- Riwayat dalam jendela waktu tertentu -------------------------------
    features["log_prior_corrective_30d"] = _log1p(raw["prior_corrective_30d"])
    features["log_prior_failure_365d"] = _log1p(raw["prior_failure_365d"])
    features["log_prior_events_180d"] = _log1p(raw["prior_events_180d"])

    # --- Lifecycle antar-siklus ---------------------------------------------
    features["log_previous_cycle_lifetime_mean"] = _log1p(
        raw["previous_cycle_lifetime_mean"]
    )
    features["has_previous_cycle"] = raw["has_previous_cycle"].fillna(False).astype(bool)

    # --- Musiman ------------------------------------------------------------
    # Representasi siklik supaya Desember tidak dianggap jauh dari Januari.
    month = pd.to_datetime(raw["observation_on"]).dt.month
    features["month_sin"] = np.sin(2.0 * np.pi * (month - 1) / 12.0)
    features["month_cos"] = np.cos(2.0 * np.pi * (month - 1) / 12.0)

    features[config.CATEGORICAL_FEATURES] = features[config.CATEGORICAL_FEATURES].astype(str)
    features[config.NUMERIC_FEATURES] = features[config.NUMERIC_FEATURES].astype(float)
    return features[config.FEATURE_COLUMNS]


def project_features(raw: pd.DataFrame, support: pd.Series, steps_ahead: int) -> pd.DataFrame:
    """Fitur seandainya waktu maju `steps_ahead` x 30 hari tanpa kejadian baru.

    Dipakai prediction multi-horizon: umur pemasangan, waktu sejak corrective
    terakhir, dan bulan ikut bertambah sesuai waktu yang berlalu, sementara
    hitungan riwayat dibekukan. Asumsi "tidak ada kejadian baru" adalah
    penyederhanaan yang disengaja - tidak ada cara jujur untuk mengetahui
    kejadian yang belum terjadi.
    """
    if steps_ahead == 0:
        return build_features(raw, support)

    elapsed_days = steps_ahead * config.OBSERVATION_STEP_DAYS
    shifted = raw.copy()
    shifted["days_since_installation"] = (
        pd.to_numeric(raw["days_since_installation"], errors="coerce").fillna(0.0)
        + elapsed_days
    )
    # Kolom ini kosong kalau PART belum pernah kena corrective; harus tetap
    # kosong setelah diproyeksikan, bukan berubah jadi angka.
    shifted["days_since_last_corrective"] = (
        pd.to_numeric(raw["days_since_last_corrective"], errors="coerce") + elapsed_days
    )
    shifted["observation_on"] = pd.to_datetime(raw["observation_on"]) + pd.to_timedelta(
        elapsed_days, unit="D"
    )
    return build_features(shifted, support)
