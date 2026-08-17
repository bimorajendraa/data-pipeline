"""EKSPERIMEN: fitur lintas-PART (kondisi armada), bukan hanya riwayat sendiri.

BUKAN model resmi. Tidak menyentuh model, view, atau script yang sudah ada -
hanya membaca schema analytics dan melaporkan hasilnya.

GAGASANNYA
    18 fitur model resmi semuanya bicara tentang PART itu sendiri: umurnya,
    berapa kali rusak, kapan terakhir diperbaiki. Tidak satu pun melihat
    keadaan di sekelilingnya.

    Yang diuji: apakah "seberapa sering model PART ini rusak belakangan" dan
    "seberapa sering PART di lokasi ini rusak belakangan" menambah daya
    tebak. Bedanya dengan part_model_category yang sudah ada penting -
    kategori hanya tahu IDENTITAS model (statis), sedangkan laju armada tahu
    KONDISI TERKINI, sehingga bisa menangkap cacat satu batch, kohort yang
    menua bersama, atau masalah musiman.

SINYAL AWAL (diperiksa sebelum eksperimen ini ditulis)
    Laju kerusakan armada 90 hari, dinormalkan per jumlah unit aktif, dipisah
    per tahun supaya bukan sekadar tren waktu:

        laju armada       2023   2024   2025   2026
        rendah (<0,5%)    0,37%  0,13%  0,49%  0,66%
        sedang (0,5-2%)   1,82%  1,76%  1,51%  1,71%
        tinggi (>2%)      6,17%  5,84%  4,56%  4,61%

    Gradiennya bertahan di setiap tahun, jadi bukan artefak waktu dan bukan
    efek ukuran armada. Tetapi sinyal univariat kuat BELUM TENTU menambah
    apa-apa di atas 18 fitur yang sudah ada - itulah yang diuji di sini.

TIDAK ADA KEBOCORAN
    Semua hitungan hanya memakai kerusakan yang terjadi SEBELUM tanggal
    observasi, dan jumlah unit aktif pada tanggal itu. Semuanya sudah
    diketahui saat prediksi dilakukan.

Jalankan: python src/experiment_fleet_features.py
"""

from __future__ import annotations

import warnings

import numpy as np
import pandas as pd
from catboost import CatBoostClassifier, Pool
from sklearn.isotonic import IsotonicRegression
from sklearn.metrics import average_precision_score, roc_auc_score

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
BASELINE = CATEGORICAL + NUMERIC
FLEET_MODEL = ["log_model_failures_90d", "model_failure_rate_90d", "log_model_fleet_size"]
FLEET_PLACE = ["log_place_failures_90d", "place_failure_rate_90d", "log_place_fleet_size"]
FLEET_TERMINAL = ["log_terminal_failures_90d", "terminal_failure_rate_90d",
                  "log_terminal_fleet_size"]
FLEET = FLEET_MODEL + FLEET_PLACE + FLEET_TERMINAL
PARAMS = dict(iterations=200, depth=4, learning_rate=0.03, l2_leaf_reg=10,
              loss_function="Logloss", eval_metric="AUC", auto_class_weights="Balanced",
              use_best_model=False, random_seed=42, verbose=False, thread_count=1)
WINDOW_DAYS = 90

OBSERVATION_SQL = f"""
SELECT o.installation_cycle_id, o.observation_on, o.item_model_code_clean,
    o.installed_place_clean, p.terminal_pairing_code, o.target_failure_30d,
    {", ".join("f." + c for c in BASELINE)}
FROM analytics.item_observation_30d o
JOIN analytics.failure_30d_baseline_features f
  USING (installation_cycle_id, item_identifier_clean, observation_on)
LEFT JOIN analytics.eda_part_terminal_cycle_link p
  ON p.installation_cycle_id = o.installation_cycle_id AND p.is_parent_link_valid
WHERE o.is_recon_verified_training_eligible
  AND o.observation_on >= DATE '2014-01-01'
-- Urutan WAJIB dikunci: tanpa ini Postgres boleh mengembalikan baris dalam
-- urutan berbeda tiap kali, dan CatBoost menghasilkan model yang sedikit
-- berbeda pula - cukup untuk menggeser ROC-AUC sekitar 0,006 antar-run.
ORDER BY installation_cycle_id, observation_on
"""

CYCLE_SQL = """
SELECT c.item_model_code_clean, c.installed_place_clean, p.terminal_pairing_code,
    c.installed_on, c.cycle_end_on
FROM analytics.item_installation_cycle c
LEFT JOIN analytics.eda_part_terminal_cycle_link p
  ON p.installation_cycle_id = c.installation_cycle_id AND p.is_parent_link_valid
WHERE c.is_initial_model_cohort
"""

# Kerusakan tingkat mesin induk diambil dari siklus yang ditutupnya, karena
# mesin induk memang melekat pada siklus pemasangan - bukan pada event.
FAILURE_SQL = """
SELECT f.item_model_code_clean, f.failure_place_clean, f.failure_onset_on,
    p.terminal_pairing_code
FROM analytics.failure_event_clean f
LEFT JOIN analytics.item_installation_cycle c
  ON c.item_identifier_clean = f.item_identifier_clean
 AND c.failure_onset_on = f.failure_onset_on
LEFT JOIN analytics.eda_part_terminal_cycle_link p
  ON p.installation_cycle_id = c.installation_cycle_id AND p.is_parent_link_valid
WHERE f.is_initial_model_cohort
"""


def query(sql: str) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])


def _counts_before(times: dict[str, np.ndarray], keys: pd.Series, at: np.ndarray) -> np.ndarray:
    """Berapa kejadian milik kelompok yang sama terjadi SEBELUM tiap titik waktu."""
    result = np.zeros(len(at), dtype="int64")
    for key, rows in keys.groupby(keys, sort=False).indices.items():
        sorted_times = times.get(key)
        if sorted_times is None:
            continue
        result[rows] = np.searchsorted(sorted_times, at[rows], side="left")
    return result


def add_fleet_features(
    observations: pd.DataFrame, cycles: pd.DataFrame, failures: pd.DataFrame,
    key_observation: str, key_cycle: str, key_failure: str, prefix: str,
) -> None:
    """Laju kerusakan dan ukuran armada untuk satu cara pengelompokan.

    Ukuran armada = jumlah siklus yang sedang berjalan pada tanggal itu:
    yang sudah terpasang, dikurangi yang sudah berakhir. Laju = kerusakan
    dalam 90 hari terakhir dibagi ukuran armada, supaya kelompok besar tidak
    otomatis terlihat lebih bermasalah hanya karena jumlahnya banyak.
    """
    at = observations["observation_on"].to_numpy("datetime64[ns]")
    window = at - np.timedelta64(WINDOW_DAYS, "D")
    keys = observations[key_observation].fillna("(kosong)")

    def sorted_by(frame: pd.DataFrame, key: str, column: str) -> dict[str, np.ndarray]:
        valid = frame[frame[column].notna()]
        return {
            name: np.sort(group[column].to_numpy("datetime64[ns]"))
            for name, group in valid.groupby(valid[key].fillna("(kosong)"), sort=False)
        }

    failure_times = sorted_by(failures, key_failure, "failure_onset_on")
    installed = sorted_by(cycles, key_cycle, "installed_on")
    ended = sorted_by(cycles, key_cycle, "cycle_end_on")

    recent = _counts_before(failure_times, keys, at) - _counts_before(failure_times, keys, window)
    fleet = _counts_before(installed, keys, at) - _counts_before(ended, keys, at)
    fleet = np.maximum(fleet, 0)

    observations[f"log_{prefix}_failures_90d"] = np.log1p(np.maximum(recent, 0))
    observations[f"{prefix}_failure_rate_90d"] = recent / np.maximum(fleet, 1)
    observations[f"log_{prefix}_fleet_size"] = np.log1p(fleet)


def assign_split(observed: pd.Series) -> pd.Series:
    """Pembagian waktu resmi, disalin apa adanya."""
    resolved = observed + pd.Timedelta(days=30)
    split = pd.Series("EXCLUDED", index=observed.index)
    split[(observed >= "2014-01-01") & (resolved < "2025-01-01")] = "TRAIN"
    split[(observed >= "2025-01-01") & (resolved < "2026-01-01")] = "VALIDATION"
    split[observed >= "2026-01-01"] = "TEST"
    return split


def main() -> int:
    print("Membaca data...")
    data = query(OBSERVATION_SQL)
    cycles = query(CYCLE_SQL)
    failures = query(FAILURE_SQL)
    data["observation_on"] = pd.to_datetime(data["observation_on"])
    for frame, column in [(cycles, "installed_on"), (cycles, "cycle_end_on"),
                          (failures, "failure_onset_on")]:
        frame[column] = pd.to_datetime(frame[column])
    print(f"  {len(data):,} observasi layak, {len(cycles):,} siklus, {len(failures):,} kerusakan")

    print("Menghitung fitur armada (per model PART dan per lokasi)...")
    add_fleet_features(data, cycles, failures,
                       "item_model_code_clean", "item_model_code_clean",
                       "item_model_code_clean", "model")
    add_fleet_features(data, cycles, failures,
                       "installed_place_clean", "installed_place_clean",
                       "failure_place_clean", "place")
    add_fleet_features(data, cycles, failures,
                       "terminal_pairing_code", "terminal_pairing_code",
                       "terminal_pairing_code", "terminal")

    data["split"] = assign_split(data["observation_on"])
    target = data["target_failure_30d"].astype(bool)
    parts = {name: data["split"].eq(name).to_numpy() for name in ("TRAIN", "VALIDATION", "TEST")}
    print(f"  latih={parts['TRAIN'].sum():,}  validasi={parts['VALIDATION'].sum():,}  "
          f"uji={parts['TEST'].sum():,} ({int(target[parts['TEST']].sum()):,} rusak)\n")

    truth_test = target[parts["TEST"]]
    truth_val = target[parts["VALIDATION"]]
    base_rate = truth_test.mean()

    results = {}
    print(f"{'set fitur':28s}{'jumlah':>8s}{'ROC uji':>10s}{'PR uji':>9s}{'lift':>7s}{'Brier':>9s}")
    print("-" * 72)
    variants = {
        "18 fitur resmi": BASELINE,
        "18 + armada model": BASELINE + FLEET_MODEL,
        "18 + model & lokasi": BASELINE + FLEET_MODEL + FLEET_PLACE,
        "18 + model & mesin induk": BASELINE + FLEET_MODEL + FLEET_TERMINAL,
        "18 + ketiganya": BASELINE + FLEET,
    }
    for name, columns in variants.items():
        features = data[columns].copy()
        features[CATEGORICAL] = features[CATEGORICAL].astype(str)
        numeric = [c for c in columns if c not in CATEGORICAL]
        features[numeric] = features[numeric].apply(pd.to_numeric)

        model = CatBoostClassifier(**PARAMS)
        model.fit(Pool(features[parts["TRAIN"]], target[parts["TRAIN"]], cat_features=CATEGORICAL),
                  eval_set=Pool(features[parts["VALIDATION"]], truth_val, cat_features=CATEGORICAL))
        calibrator = IsotonicRegression(out_of_bounds="clip").fit(
            model.predict_proba(features[parts["VALIDATION"]])[:, 1], truth_val.astype(int))
        raw = model.predict_proba(features[parts["TEST"]])[:, 1]
        results[name] = raw
        pr = average_precision_score(truth_test, raw)
        brier = np.mean((calibrator.predict(raw) - truth_test.to_numpy()) ** 2)
        print(f"{name:28s}{len(columns):>8d}{roc_auc_score(truth_test, raw):>10.4f}"
              f"{pr:>9.4f}{pr / base_rate:>7.2f}{brier:>9.4f}")

        if name.endswith("ketiganya"):
            importance = pd.Series(model.get_feature_importance(), index=columns)
            print("\n   Kontribusi fitur armada (dari 21 fitur):")
            for feature in FLEET:
                rank = int((importance > importance[feature]).sum()) + 1
                print(f"     {feature:26s} {importance[feature]:5.2f}  (peringkat {rank} dari {len(columns)})")
            print()

    # Apakah selisihnya nyata, atau kebetulan sampel uji ini?
    a, b = results["18 + armada model"], results["18 + model & lokasi"]
    actual = truth_test.to_numpy()
    generator = np.random.default_rng(17)
    samples = [generator.integers(0, len(actual), len(actual)) for _ in range(1000)]
    samples = [s for s in samples if 0 < actual[s].sum() < len(actual)]
    difference = [average_precision_score(actual[s], b[s]) - average_precision_score(actual[s], a[s])
                  for s in samples]
    print(f"Selisih PR-AUC (tambah lokasi - model saja): {np.mean(difference):+.4f}, "
          f"95% CI [{np.percentile(difference, 2.5):+.4f}, {np.percentile(difference, 97.5):+.4f}]")
    print(f"Peluang tambahan lokasi benar-benar membantu: {(np.array(difference) > 0).mean():.0%}")

    print(f"\nRecall@K - berapa kerusakan tertangkap kalau menandai K PART teratas?")
    print(f"{'K':>7s}{'model saja':>15s}{'+ lokasi':>15s}")
    for k in [200, 500, 1000, 2000]:
        caught = [int(actual[np.argsort(-score)[:k]].sum()) for score in (a, b)]
        print(f"{k:>7,}{caught[0]:>15,}{caught[1]:>15,}")
    print(f"{'':>7s}{'':>15s}   dari {int(actual.sum()):,} kerusakan")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
