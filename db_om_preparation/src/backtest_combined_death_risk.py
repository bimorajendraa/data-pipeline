"""Backtest gabungan dua model: benarkah mengalikan keduanya lebih baik?

    risiko MATI 30 hari = P(rusak dalam 30 hari) x P(dibuang | rusak)
                          model 30 hari resmi      model scrap

Pertanyaan yang diuji: apakah gabungan itu benar-benar lebih baik menemukan
PART yang akan MATI dalam 30 hari dibanding memakai model 30 hari sendirian?
Kalau model 30 hari saja sudah sama bagusnya, mengalikan dua model hanya
menambah rumit tanpa manfaat.

TIDAK melatih apa pun. Kedua model dipakai apa adanya, dan tidak ada file
model/view yang disentuh.

CARA TARGET DIBUAT - sebuah observasi disebut "MATI dalam 30 hari" kalau ada
kerusakan dalam 30 hari sesudahnya DAN kerusakan itu berakhir dibuang.
Observasi yang kerusakannya terjadi tetapi nasib PART-nya tidak diketahui
DIBUANG dari penilaian: menganggapnya "tidak mati" berarti menilai model
terhadap jawaban karangan.

Populasi dibatasi mulai 2025-04-01 (sejak status UNREPAIRABLE dipakai) dan
diberi embargo 60 hari di ujung data: 30 hari untuk jendela target, ditambah
30 hari supaya bukti "diperbaiki" lewat pemasangan ulang sempat muncul.

Jalankan: python src/backtest_combined_death_risk.py
"""

from __future__ import annotations

import warnings

import joblib
import numpy as np
import pandas as pd
from catboost import CatBoostClassifier
from sklearn.metrics import average_precision_score, roc_auc_score

import train_unrepairable_model as scrap_research
from database import PROJECT_DIR, connect

warnings.filterwarnings("ignore")

ERA_START = "2025-04-01"
EMBARGO_DAYS = 60
TOP_N = [100, 500, 1000, 2000]
BOOTSTRAP_ROUNDS = 500
RANDOM_STATE = 11

FAILURE_FEATURES = [
    "part_model_category", "client_category", "installation_age_band",
    "log_days_since_installation", "log_total_prior_events", "log_prior_failure_count",
    "has_prior_failure", "log_prior_corrective_count", "has_prior_corrective",
    "log_days_since_last_corrective", "log_prior_distinct_places", "log_prior_corrective_30d",
    "log_prior_failure_365d", "log_prior_events_180d", "log_previous_cycle_lifetime_mean",
    "has_previous_cycle", "month_sin", "month_cos",
]
FAILURE_CATEGORICAL = ["part_model_category", "client_category", "installation_age_band"]

DATASET_SQL = f"""
WITH bound AS (
    SELECT MAX(created_on) AS data_end FROM analytics.item_journey_operational_timeline
),
obs AS MATERIALIZED (
    -- Kelayakan dibaca langsung dari matview-nya. failure_30d_model_labels
    -- hanya view di atas tabel yang sama, jadi join ke sana cuma menambah
    -- self-join 1,4 juta baris tanpa menambah informasi apa pun.
    SELECT o.installation_cycle_id, o.item_identifier_clean, o.observation_on,
        o.item_type_clean, o.days_since_installation, o.prior_failure_count,
        o.target_failure_30d, o.next_failure_on
    FROM analytics.item_observation_30d o
    CROSS JOIN bound b
    WHERE o.is_recon_verified_training_eligible
      AND o.observation_on >= DATE '{ERA_START}'
      AND o.observation_on <= b.data_end - INTERVAL '{EMBARGO_DAYS} days'
)
SELECT s.*, flow.next_failure_outcome_status AS outcome, flow.next_installed_on,
    history.prior_repaired_count, history.first_ever_event_on,
    {", ".join("feat." + column for column in FAILURE_FEATURES)}
FROM obs s
JOIN analytics.failure_30d_baseline_features feat
  USING (installation_cycle_id, item_identifier_clean, observation_on)
LEFT JOIN analytics.failure_event_flow flow
  ON flow.item_identifier_clean = s.item_identifier_clean
 AND flow.failure_onset_on = s.next_failure_on
LEFT JOIN LATERAL (
    SELECT COUNT(*) FILTER (WHERE e.status_clean = 'REPAIRED') AS prior_repaired_count,
           MIN(e.created_on) AS first_ever_event_on
    FROM analytics.item_journey_operational_timeline e
    WHERE e.item_identifier_clean = s.item_identifier_clean
      AND e.created_on <= s.observation_on
) history ON TRUE
"""


def load_observations() -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(DATASET_SQL)
            frame = pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])

    frame["observation_on"] = pd.to_datetime(frame["observation_on"])
    frame["target_failure_30d"] = frame["target_failure_30d"].astype(bool)

    is_scrap = frame["outcome"].isin(scrap_research.SCRAP_STATUS)
    outcome_known = frame["outcome"].notna() | frame["next_installed_on"].notna()
    frame["target_death_30d"] = (frame["target_failure_30d"] & is_scrap).astype(int)

    unknown = frame["target_failure_30d"] & ~outcome_known
    print(f"  dibuang karena nasib PART tidak diketahui: {int(unknown.sum()):,}")
    return frame.loc[~unknown].reset_index(drop=True)


def score_failure_model(frame: pd.DataFrame) -> np.ndarray:
    model = CatBoostClassifier()
    model.load_model(str(PROJECT_DIR / "models" / "failure_30d_baseline_catboost.cbm"))
    calibrator = joblib.load(PROJECT_DIR / "models" / "failure_30d_baseline_calibrator.joblib")

    features = frame[FAILURE_FEATURES].copy()
    features[FAILURE_CATEGORICAL] = features[FAILURE_CATEGORICAL].astype(str)
    numeric = [c for c in FAILURE_FEATURES if c not in FAILURE_CATEGORICAL]
    features[numeric] = features[numeric].apply(pd.to_numeric)
    return calibrator.predict(model.predict_proba(features)[:, 1])


def score_scrap_model(frame: pd.DataFrame) -> np.ndarray:
    """Skor 'kalau PART ini rusak, apakah berakhir dibuang' pada tiap observasi.

    Jenis PART yang dikenal model harus SAMA dengan saat model dilatih -
    kalau tidak, PART yang saat latih punya kategori sendiri bisa jatuh ke
    keranjang 'jarang' di sini, dan skornya jadi tidak sebanding.
    """
    training_rows, _, _ = scrap_research.load_dataset()
    type_counts = training_rows["item_type_clean"].value_counts()
    known_types = set(type_counts[type_counts >= scrap_research.MIN_TYPE_SUPPORT].index)

    repaired = pd.to_numeric(frame["prior_repaired_count"]).fillna(0)
    failures = pd.to_numeric(frame["prior_failure_count"]).fillna(0)
    age_total = (
        frame["observation_on"] - pd.to_datetime(frame["first_ever_event_on"])
    ).dt.total_seconds() / 86400.0

    features = pd.DataFrame(index=frame.index)
    features["item_type_category"] = (
        frame["item_type_clean"]
        .where(frame["item_type_clean"].isin(known_types), "LOW_SUPPORT")
        .fillna("UNKNOWN").astype(str)
    )
    features["log_age_total"] = np.log1p(age_total.fillna(0).clip(lower=0))
    features["log_cycle_age"] = np.log1p(
        pd.to_numeric(frame["days_since_installation"]).fillna(0).clip(lower=0)
    )
    features["log_prior_repaired_count"] = np.log1p(repaired)
    features["has_prior_repair"] = (repaired > 0).astype(int)
    features["log_prior_failure_count"] = np.log1p(failures)
    features["is_first_failure_ever"] = (failures <= 1).astype(int)

    model = joblib.load(PROJECT_DIR / "models" / "unrepairable_scrap_model.joblib")
    return model.predict_proba(features[scrap_research.FEATURE_COLUMNS])[:, 1]


def main() -> int:
    print(f"Membaca observasi sejak {ERA_START} (embargo {EMBARGO_DAYS} hari)...")
    frame = load_observations()
    target = frame["target_death_30d"].to_numpy()
    base_rate = target.mean()
    print(f"  {len(frame):,} observasi, {target.sum()} berakhir MATI ({base_rate:.4%})\n")

    failure_score = score_failure_model(frame)
    scrap_score = score_scrap_model(frame)
    scores = {
        "Model 30 hari saja": failure_score,
        "Model scrap saja": scrap_score,
        "GABUNGAN (dikalikan)": failure_score * scrap_score,
    }

    print(f"=== Menemukan PART yang MATI dalam 30 hari (positif={target.sum()}) ===")
    print(f"{'skor yang dipakai':24s}{'ROC-AUC':>9s}{'PR-AUC':>9s}{'lift':>8s}")
    for name, score in scores.items():
        pr_auc = average_precision_score(target, score)
        print(f"{name:24s}{roc_auc_score(target, score):9.3f}{pr_auc:9.4f}"
              f"{pr_auc / base_rate:7.1f}x")

    print(f"\n=== Kalau menandai N PART teratas, berapa yang benar-benar mati? "
          f"(dari {target.sum()}) ===")
    print(f"{'skor':24s}" + "".join(f"{'top ' + str(n):>10s}" for n in TOP_N))
    for name, score in scores.items():
        order = np.argsort(-score)
        print(f"{name:24s}" + "".join(f"{int(target[order[:n]].sum()):10d}" for n in TOP_N))

    # Apakah keunggulan gabungan nyata, atau kebetulan sampel?
    generator = np.random.default_rng(RANDOM_STATE)
    samples = [generator.integers(0, len(target), len(target)) for _ in range(BOOTSTRAP_ROUNDS)]
    samples = [s for s in samples if target[s].sum() > 3]
    difference = [
        average_precision_score(target[s], scores["GABUNGAN (dikalikan)"][s])
        - average_precision_score(target[s], scores["Model 30 hari saja"][s])
        for s in samples
    ]
    print(f"\nSelisih PR-AUC gabungan vs model 30 hari saja: {np.mean(difference):+.4f}, "
          f"95% CI [{np.percentile(difference, 2.5):+.4f}, {np.percentile(difference, 97.5):+.4f}]")
    print(f"Peluang gabungan benar-benar lebih baik: {(np.array(difference) > 0).mean():.0%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
