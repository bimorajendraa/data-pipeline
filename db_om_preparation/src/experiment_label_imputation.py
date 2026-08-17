"""EKSPERIMEN: menyelamatkan data yang sekarang dibuang, lewat imputasi label.

BUKAN model resmi. Tidak menyentuh model, view, atau script mana pun yang
sudah ada - hanya membaca schema analytics dan melaporkan hasilnya.

Dua gagasan yang diuji:

IDE 1 - RECON sebagai penanda akhir hidup PART
    Aturan resmi menolak sebuah siklus jadi contoh "tidak rusak" kalau ada
    RECON muncul setelah PART terakhir terlihat aktif. Alasannya masuk akal:
    RECON menandakan ada yang perlu direkonsiliasi, jadi masa diam sebelumnya
    belum tentu aman. Tetapi konsekuensinya besar - 968.045 observasi dibuang.

    Yang diuji: alih-alih dibuang, tanggal RECON dipakai sebagai perkiraan
    "kapan PART itu berhenti dipakai", dan waktu menuju kerusakan diisi dari
    MEDIAN umur-sampai-rusak tipe PART tersebut.

IDE 2 - kerusakan tanpa kelanjutan dianggap berakhir dibuang
    743 kerusakan tidak punya vonis bengkel DAN PART-nya tidak pernah dipasang
    lagi. Sekarang dibuang dari pemodelan. Yang diuji: anggap saja PART itu
    memang tidak pernah kembali, alias dibuang.

ATURAN YANG TETAP DIPEGANG - ini yang membuat eksperimen tetap jujur:

  * Label hasil tebakan HANYA boleh dipakai untuk MELATIH.
  * Pengujian TETAP memakai label yang benar-benar terverifikasi.
    Kalau tidak, kita cuma menguji model terhadap tebakan kita sendiri.
  * Median umur dihitung HANYA dari periode latih, supaya tidak mengintip
    masa depan.
  * Pembagian waktu, embargo, dan definisi target tidak diubah sama sekali.

Jalankan: python src/experiment_label_imputation.py
"""

from __future__ import annotations

import warnings

import numpy as np
import pandas as pd
from catboost import CatBoostClassifier, Pool
from sklearn.ensemble import RandomForestClassifier, VotingClassifier
from sklearn.compose import ColumnTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from database import connect

warnings.filterwarnings("ignore")

CATEGORICAL = ["part_model_category", "client_category", "installation_age_band"]
NUMERIC = [
    "log_days_since_installation", "log_total_prior_events", "log_prior_failure_count",
    "has_prior_failure", "log_prior_corrective_count", "has_prior_corrective",
    "log_days_since_last_corrective", "log_prior_distinct_places", "log_prior_corrective_30d",
    "log_prior_failure_365d", "log_prior_events_180d", "log_previous_cycle_lifetime_mean",
    "has_previous_cycle", "month_sin", "month_cos",
]
FEATURES = CATEGORICAL + NUMERIC
PARAMS = dict(iterations=200, depth=4, learning_rate=0.03, l2_leaf_reg=10,
              loss_function="Logloss", auto_class_weights="Balanced",
              random_seed=42, verbose=False, thread_count=1)

SCRAP_STATUS = ("UNREPAIRABLE", "BROKEN")
SCRAP_ERA = "2025-04-01"
SCRAP_TEST = "2026-04-01"


def query(sql: str) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])


def split_of(observed: pd.Series, horizon_days: int = 30) -> pd.Series:
    """Pembagian waktu resmi, disalin apa adanya - tidak diubah."""
    resolved = observed + pd.Timedelta(days=horizon_days)
    split = pd.Series("EXCLUDED", index=observed.index)
    split[(observed >= "2014-01-01") & (resolved < "2025-01-01")] = "TRAIN"
    split[(observed >= "2025-01-01") & (resolved < "2026-01-01")] = "VALIDATION"
    split[observed >= "2026-01-01"] = "TEST"
    return split


# ---------------------------------------------------------------------------
# IDE 1 - RECON sebagai penanda akhir hidup
# ---------------------------------------------------------------------------

IDEA1_SQL = """
SELECT o.installation_cycle_id, o.item_identifier_clean, o.observation_on,
    o.item_model_code_clean, o.installed_on,
    o.target_failure_30d, o.is_target_observable, o.is_recon_verified_training_eligible,
    c.has_recon_after_last_seen, c.item_last_seen_on, c.failure_onset_on,
    c.cycle_end_reason, c.dataset_max_event_on,
    f.part_model_category, f.client_category, f.installation_age_band,
    f.log_days_since_installation, f.log_total_prior_events, f.log_prior_failure_count,
    f.has_prior_failure, f.log_prior_corrective_count, f.has_prior_corrective,
    f.log_days_since_last_corrective, f.log_prior_distinct_places,
    f.log_prior_corrective_30d, f.log_prior_failure_365d, f.log_prior_events_180d,
    f.log_previous_cycle_lifetime_mean, f.has_previous_cycle, f.month_sin, f.month_cos
FROM analytics.item_observation_30d o
JOIN analytics.failure_30d_baseline_features f
  USING (installation_cycle_id, item_identifier_clean, observation_on)
JOIN analytics.item_installation_cycle c USING (installation_cycle_id)
WHERE o.observation_on >= DATE '2014-01-01'
"""


def run_idea_1() -> None:
    print("=" * 78)
    print("IDE 1 - RECON sebagai penanda akhir hidup PART")
    print("=" * 78)
    data = query(IDEA1_SQL)
    data["observation_on"] = pd.to_datetime(data["observation_on"])
    data["split"] = split_of(data["observation_on"])
    data["target"] = data["target_failure_30d"].astype(bool)

    verified = data["is_recon_verified_training_eligible"].fillna(False).to_numpy()
    loose = data["is_target_observable"].fillna(False).to_numpy()
    train_period = data["split"].eq("TRAIN").to_numpy()

    # Median umur sampai rusak per tipe PART, HANYA dari kerusakan yang
    # benar-benar teramati di periode latih - tidak mengintip masa depan.
    observed_failures = data.loc[
        train_period & data["failure_onset_on"].notna(),
        ["item_model_code_clean", "installed_on", "failure_onset_on"],
    ].drop_duplicates()
    observed_failures["lifetime"] = (
        pd.to_datetime(observed_failures["failure_onset_on"])
        - pd.to_datetime(observed_failures["installed_on"])
    ).dt.total_seconds() / 86400.0
    median_lifetime = observed_failures.groupby("item_model_code_clean")["lifetime"].median()
    overall_median = float(observed_failures["lifetime"].median())
    print(f"Median umur-sampai-rusak: {overall_median:,.0f} hari keseluruhan, "
          f"dihitung untuk {len(median_lifetime)} tipe PART (dari periode latih saja)")

    # Kandidat imputasi: siklus yang ditolak aturan RECON, belum pernah rusak.
    candidate = (
        loose & ~verified
        & data["has_recon_after_last_seen"].fillna(False).to_numpy()
        & data["failure_onset_on"].isna().to_numpy()
    )
    imputed_onset = pd.to_datetime(data["installed_on"]) + pd.to_timedelta(
        data["item_model_code_clean"].map(median_lifetime).fillna(overall_median), unit="D"
    )
    # PART dianggap "berhenti dipakai" pada saat RECON terlihat; kerusakan
    # ditaruh pada perkiraan umur median, dibatasi tidak melewati tanggal itu.
    stop = pd.to_datetime(data["item_last_seen_on"])
    imputed_onset = imputed_onset.where(imputed_onset <= stop, stop)

    horizon = pd.Timedelta(days=30)
    imputed_target = (
        (imputed_onset > data["observation_on"])
        & (imputed_onset <= data["observation_on"] + horizon)
    ).to_numpy()

    print(f"Observasi yang bisa diselamatkan: {candidate.sum():,} "
          f"(dari {(loose & ~verified).sum():,} yang dibuang aturan RECON)")
    print(f"  di antaranya jadi contoh RUSAK hasil imputasi: {int((candidate & imputed_target).sum()):,}")

    target = data["target"].to_numpy().copy()
    target[candidate] = imputed_target[candidate]

    features = data[FEATURES].copy()
    features[CATEGORICAL] = features[CATEGORICAL].astype(str)
    features[NUMERIC] = features[NUMERIC].apply(pd.to_numeric)

    # UJI selalu memakai label terverifikasi - tidak pernah label tebakan.
    test = data["split"].eq("TEST").to_numpy() & verified
    validation = data["split"].eq("VALIDATION").to_numpy() & verified
    print(f"\nData uji (terverifikasi, tidak tersentuh imputasi): {test.sum():,} baris, "
          f"{int(data['target'].to_numpy()[test].sum()):,} rusak\n")

    setups = {
        "RESMI  latih=terverifikasi saja": train_period & verified,
        "IMPUTASI  latih=terverifikasi + RECON": (train_period & verified) | (train_period & candidate),
    }
    print(f"{'konfigurasi':40s}{'baris latih':>13s}{'rusak':>8s}{'ROC uji':>9s}{'PR uji':>8s}{'lift':>7s}")
    print("-" * 86)
    # Label sungguhan, dipakai untuk menilai - bukan label hasil imputasi.
    truth = data["target"].to_numpy()[test]
    truth_validation = data["target"].to_numpy()[validation]
    for name, mask in setups.items():
        model = CatBoostClassifier(**PARAMS)
        model.fit(Pool(features[mask], target[mask], cat_features=CATEGORICAL),
                  eval_set=Pool(features[validation], truth_validation,
                                cat_features=CATEGORICAL))
        score = model.predict_proba(features[test])[:, 1]
        pr = average_precision_score(truth, score)
        print(f"{name:40s}{mask.sum():>13,}{int(target[mask].sum()):>8,}"
              f"{roc_auc_score(truth, score):>9.3f}{pr:>8.3f}{pr / truth.mean():>7.2f}")


# ---------------------------------------------------------------------------
# IDE 2 - kerusakan tanpa kelanjutan dianggap dibuang
# ---------------------------------------------------------------------------

IDEA2_SQL = f"""
SELECT f.journey_id, f.item_identifier_clean, f.failure_onset_on, f.item_type_clean,
    f.next_failure_outcome_status AS outcome, f.next_installed_on,
    b.data_end, c.installed_on, h.prior_failure_count, h.prior_repaired_count,
    h.first_ever_event_on
FROM analytics.failure_event_flow f
CROSS JOIN (SELECT MAX(created_on) AS data_end
            FROM analytics.item_journey_operational_timeline) b
LEFT JOIN LATERAL (
    SELECT ic.installed_on FROM analytics.item_installation_cycle ic
    WHERE ic.item_identifier_clean = f.item_identifier_clean
      AND ic.installed_on <= f.failure_onset_on
    ORDER BY ic.installed_on DESC LIMIT 1
) c ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*) FILTER (WHERE o.event_semantic='FAILURE_ONSET') AS prior_failure_count,
           COUNT(*) FILTER (WHERE o.status_clean='REPAIRED') AS prior_repaired_count,
           MIN(o.created_on) AS first_ever_event_on
    FROM analytics.item_journey_operational_timeline o
    WHERE o.item_identifier_clean = f.item_identifier_clean
      AND (o.created_on, o.journey_id) <= (f.failure_onset_on, f.journey_id)
) h ON TRUE
WHERE f.failure_onset_on >= DATE '{SCRAP_ERA}' AND f.is_initial_model_cohort
"""


def scrap_model() -> VotingClassifier:
    """Model yang sama dengan yang dipakai production - supaya perbandingannya adil."""
    cats, nums = ["item_type_category"], [
        "log_age_total", "log_cycle_age", "log_prior_repaired_count",
        "has_prior_repair", "log_prior_failure_count", "is_first_failure_ever",
    ]
    scaled = ColumnTransformer([("n", StandardScaler(), nums),
                                ("c", OneHotEncoder(handle_unknown="ignore", sparse_output=False), cats)])
    plain = ColumnTransformer([("n", "passthrough", nums),
                               ("c", OneHotEncoder(handle_unknown="ignore", sparse_output=False), cats)])
    return VotingClassifier([
        ("lr", Pipeline([("p", scaled), ("m", LogisticRegression(
            max_iter=5000, class_weight="balanced", C=0.3, random_state=42))])),
        ("rf", Pipeline([("p", plain), ("m", RandomForestClassifier(
            n_estimators=500, max_depth=4, min_samples_leaf=10,
            class_weight="balanced", random_state=42, n_jobs=-1))])),
    ], voting="soft")


def run_idea_2() -> None:
    print("\n" + "=" * 78)
    print("IDE 2 - kerusakan tanpa kelanjutan dianggap berakhir dibuang")
    print("=" * 78)
    data = query(IDEA2_SQL)
    data["failure_onset_on"] = pd.to_datetime(data["failure_onset_on"])
    data_end = pd.Timestamp(data["data_end"].iloc[0])
    onset = data["failure_onset_on"]

    scrapped = data["outcome"].isin(SCRAP_STATUS)
    survived = data["outcome"].eq("REPAIRED") | data["next_installed_on"].notna()
    unresolved = ~scrapped & ~survived
    hanging_days = (data_end - onset).dt.total_seconds() / 86400.0
    past_embargo = onset <= data_end - pd.Timedelta(days=30)

    features = pd.DataFrame(index=data.index)
    counts = data["item_type_clean"].value_counts()
    frequent = counts[counts >= 20].index
    features["item_type_category"] = (
        data["item_type_clean"].where(data["item_type_clean"].isin(frequent), "LOW_SUPPORT")
        .fillna("UNKNOWN").astype(str))
    repaired = pd.to_numeric(data["prior_repaired_count"]).fillna(0)
    failures = pd.to_numeric(data["prior_failure_count"]).fillna(0)
    features["log_age_total"] = np.log1p(
        ((onset - pd.to_datetime(data["first_ever_event_on"])).dt.total_seconds() / 86400).fillna(0).clip(lower=0))
    features["log_cycle_age"] = np.log1p(
        ((onset - pd.to_datetime(data["installed_on"])).dt.total_seconds() / 86400).fillna(0).clip(lower=0))
    features["log_prior_repaired_count"] = np.log1p(repaired)
    features["has_prior_repair"] = (repaired > 0).astype(float)
    features["log_prior_failure_count"] = np.log1p(failures)
    features["is_first_failure_ever"] = (failures <= 1).astype(float)

    # UJI selalu memakai label terverifikasi saja.
    test = ((onset >= SCRAP_TEST) & (scrapped | survived) & past_embargo).to_numpy()
    truth = scrapped.to_numpy()[test]
    dev = (onset < SCRAP_TEST).to_numpy() & past_embargo.to_numpy()
    print(f"Data uji (terverifikasi): {test.sum()} kerusakan, {truth.sum()} dibuang "
          f"({truth.mean():.1%})")
    print(f"Kerusakan tanpa kelanjutan di periode latih: "
          f"{int((dev & unresolved.to_numpy()).sum())}\n")

    print(f"{'konfigurasi':46s}{'baris latih':>12s}{'dibuang':>9s}{'ROC uji':>9s}{'PR uji':>8s}{'lift':>7s}")
    print("-" * 92)
    setups = {"RESMI  buang yang tanpa kelanjutan": (None, None)}
    for minimum in [0, 90, 180, 270]:
        setups[f"IMPUTASI  anggap dibuang bila menggantung >{minimum} hari"] = (minimum, None)

    for name, (minimum, _) in setups.items():
        if minimum is None:
            mask = dev & (scrapped | survived).to_numpy()
            target = scrapped.to_numpy()
        else:
            impute = unresolved.to_numpy() & (hanging_days > minimum).to_numpy()
            mask = dev & ((scrapped | survived).to_numpy() | impute)
            target = scrapped.to_numpy() | impute
        if target[mask].sum() < 5:
            continue
        model = scrap_model()
        model.fit(features[mask], target[mask])
        score = model.predict_proba(features[test])[:, 1]
        pr = average_precision_score(truth, score)
        print(f"{name:46s}{mask.sum():>12,}{int(target[mask].sum()):>9,}"
              f"{roc_auc_score(truth, score):>9.3f}{pr:>8.3f}{pr / truth.mean():>7.2f}")


def run_controls() -> None:
    """Uji kontrol: apakah perbaikan Ide 2 benar karena tebakannya TEPAT,
    atau sekadar karena jumlah contoh positif bertambah?

    Kalau menambah positif apa pun sama bagusnya, berarti yang bekerja cuma
    penyeimbangan kelas - bukan kebenaran asumsinya. Dua pembanding di bawah
    memakai jumlah contoh yang SAMA PERSIS, hanya labelnya yang berbeda.
    """
    print("\n" + "=" * 78)
    print("UJI KONTROL - apakah tebakannya benar, atau cuma tambah data?")
    print("=" * 78)
    data = query(IDEA2_SQL)
    data["failure_onset_on"] = pd.to_datetime(data["failure_onset_on"])
    data_end = pd.Timestamp(data["data_end"].iloc[0])
    onset = data["failure_onset_on"]

    scrapped = data["outcome"].isin(SCRAP_STATUS)
    survived = data["outcome"].eq("REPAIRED") | data["next_installed_on"].notna()
    unresolved = (~scrapped & ~survived).to_numpy()
    hanging = ((data_end - onset).dt.total_seconds() / 86400.0).to_numpy()
    past_embargo = (onset <= data_end - pd.Timedelta(days=30)).to_numpy()

    features = pd.DataFrame(index=data.index)
    counts = data["item_type_clean"].value_counts()
    frequent = counts[counts >= 20].index
    features["item_type_category"] = (
        data["item_type_clean"].where(data["item_type_clean"].isin(frequent), "LOW_SUPPORT")
        .fillna("UNKNOWN").astype(str))
    repaired = pd.to_numeric(data["prior_repaired_count"]).fillna(0)
    failures = pd.to_numeric(data["prior_failure_count"]).fillna(0)
    features["log_age_total"] = np.log1p(
        ((onset - pd.to_datetime(data["first_ever_event_on"])).dt.total_seconds() / 86400).fillna(0).clip(lower=0))
    features["log_cycle_age"] = np.log1p(
        ((onset - pd.to_datetime(data["installed_on"])).dt.total_seconds() / 86400).fillna(0).clip(lower=0))
    features["log_prior_repaired_count"] = np.log1p(repaired)
    features["has_prior_repair"] = (repaired > 0).astype(float)
    features["log_prior_failure_count"] = np.log1p(failures)
    features["is_first_failure_ever"] = (failures <= 1).astype(float)

    test = ((onset >= SCRAP_TEST).to_numpy() & (scrapped | survived).to_numpy() & past_embargo)
    truth = scrapped.to_numpy()[test]
    dev = (onset < SCRAP_TEST).to_numpy() & past_embargo
    verified = (scrapped | survived).to_numpy()
    impute = unresolved & (hanging > 270)

    generator = np.random.default_rng(42)
    wanted = int((impute & dev).sum())

    # Kontrol ACAK: ambil kerusakan tanpa kelanjutan sebanyak yang SAMA, tetapi
    # dipilih acak tanpa memandang lama menggantung. Kalau hasilnya sama
    # bagusnya, berarti yang bekerja cuma jumlah contoh - bukan aturannya.
    pool = np.flatnonzero(unresolved & dev)
    random_pick = np.zeros(len(data), dtype=bool)
    random_pick[generator.choice(pool, size=min(wanted, len(pool)), replace=False)] = True

    # Kontrol PENDEK: pakai yang menggantungnya justru SEBENTAR.
    short = unresolved & dev & (hanging <= 90)
    short_pick = np.zeros(len(data), dtype=bool)
    short_pool = np.flatnonzero(short)
    if len(short_pool):
        short_pick[generator.choice(short_pool, size=min(wanted, len(short_pool)), replace=False)] = True

    variants = {
        "ASLI      menggantung >270 hari -> DIBUANG": (impute, scrapped.to_numpy() | impute),
        "KEBALIKAN menggantung >270 hari -> DIPERBAIKI": (impute, scrapped.to_numpy()),
        "ACAK      pilih acak, jumlah sama": (random_pick, scrapped.to_numpy() | random_pick),
        "PENDEK    justru yang baru menggantung": (short_pick, scrapped.to_numpy() | short_pick),
    }
    print(f"{'varian':46s}{'baris latih':>12s}{'dibuang':>9s}{'ROC uji':>9s}{'PR uji':>8s}{'lift':>7s}")
    print("-" * 92)
    for name, (added, target) in variants.items():
        mask = dev & (verified | added)
        if target[mask].sum() < 5:
            continue
        model = scrap_model()
        model.fit(features[mask], target[mask])
        score = model.predict_proba(features[test])[:, 1]
        pr = average_precision_score(truth, score)
        print(f"{name:46s}{mask.sum():>12,}{int(target[mask].sum()):>9,}"
              f"{roc_auc_score(truth, score):>9.3f}{pr:>8.3f}{pr / truth.mean():>7.2f}")

    # Bukti tak langsung: pada kerusakan yang vonisnya SUDAH diketahui, apakah
    # lama tak dipasang ulang memang pertanda dibuang?
    resolved = verified & past_embargo & (onset < SCRAP_TEST).to_numpy()
    gap = np.where(data["next_installed_on"].notna().to_numpy(),
                   (pd.to_datetime(data["next_installed_on"]) - onset).dt.total_seconds().to_numpy() / 86400.0,
                   hanging)
    print("\nPada kerusakan yang vonisnya SUDAH diketahui - apakah lama tidak")
    print("dipasang ulang memang pertanda dibuang?")
    for low, high in [(0, 30), (30, 90), (90, 180), (180, 270), (270, 1e9)]:
        band = resolved & (gap >= low) & (gap < high)
        if band.sum() < 5:
            continue
        label = f"{low:.0f}-{high:.0f} hari" if high < 1e9 else f">{low:.0f} hari"
        print(f"   {label:>14s}: {band.sum():5d} kerusakan, "
              f"{scrapped.to_numpy()[band].mean():6.1%} berakhir dibuang")


def main() -> int:
    import sys as _sys
    only = _sys.argv[1] if len(_sys.argv) > 1 else "all"
    if only in ("all", "1"):
        run_idea_1()
    if only in ("all", "2"):
        run_idea_2()
    if only in ("all", "2", "kontrol"):
        run_controls()
    print("\nCatatan: seluruh angka uji di atas memakai label TERVERIFIKASI.")
    print("Label hasil imputasi hanya dipakai untuk melatih, tidak pernah untuk menilai.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
