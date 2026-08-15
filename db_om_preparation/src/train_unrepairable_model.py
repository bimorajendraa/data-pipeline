"""Model risiko SCRAP: saat sebuah PART rusak, apakah kerusakan itu berakhir
UNREPAIRABLE/BROKEN (dibuang) atau REPAIRED (kembali dipakai)?

TERPISAH dari model klasifikasi 30 hari resmi (train_final_model.py) dan tidak
menyentuhnya sama sekali. Model 30 hari menjawab "KAPAN PART akan rusak";
script ini menjawab pertanyaan lanjutan "kalau sudah rusak, apakah PART ini
benar-benar mati".

KENAPA BUKAN MODEL "KAPAN JADI UNREPAIRABLE":
Jarak dari kerusakan ke vonis bengkel sangat pendek - median 2,9 hari untuk
PART yang akhirnya dibuang (dan 2,3 hari untuk yang diperbaiki). Artinya
"kapan" praktis sudah dijawab oleh model 30 hari yang ada: begitu PART rusak,
vonisnya keluar dalam hitungan hari. Yang belum terjawab adalah APAKAH, dan
itu yang dimodelkan di sini. Melatih model survival "waktu menuju
unrepairable" pada 55 kejadian hanya akan memodelkan antrean bengkel, bukan
kondisi PART.

CARA LABEL DITENTUKAN - dua sumber bukti, bukan hanya vonis bengkel:

- DIBUANG  : vonis bengkel UNREPAIRABLE atau BROKEN.
- DIPERBAIKI: vonis bengkel REPAIRED, ATAU PART yang sama terbukti DIPASANG
  KEMBALI setelah kerusakan itu. Pemasangan ulang adalah bukti langsung PART
  kembali dipakai, jadi jelas tidak dibuang.

Memakai vonis bengkel saja akan membuang 861 episode yang sebenarnya sudah
terbukti selamat lewat pemasangan ulang, dan - lebih berbahaya - membuat model
hanya belajar dari episode yang kebetulan dicatat bengkel. Bias itu sempat
membuat base rate terlihat meledak dari 4,3% ke 23,5% dalam satu kuartal;
setelah pemasangan ulang ikut dihitung, angkanya jadi 1,0% ke 6,2% yang jauh
lebih masuk akal.

EMBARGO BATAS DATA: episode dalam 30 hari terakhir dibuang. Alasannya
asimetri - vonis "dibuang" muncul cepat (median 2,9 hari) sementara bukti
"diperbaiki" lewat pemasangan ulang butuh lebih lama (p80 = 30 hari). Tanpa
embargo, periode terbaru akan terlihat penuh kerusakan fatal semata-mata
karena bukti selamatnya belum sempat muncul.

KETERBATASAN YANG HARUS DIBACA SEBELUM MEMAKAI HASIL INI - lihat juga
reports/unrepairable_model_findings.md:

1. Status UNREPAIRABLE baru ada sejak 2025-04-23 (proses repair detail baru).
   Seluruh populasi karena itu dibatasi mulai 2025-04-01. Sebelum itu, PART
   yang dibuang tidak bisa dibedakan dari yang hilang dari catatan.
2. Hanya 46 kejadian scrap. Sampel kecil - metrik uji berisik dan model
   sengaja dibuat sederhana (7 fitur).
3. Episode tanpa vonis DAN tidak pernah dipasang lagi tetap dibuang dari
   pemodelan: bisa jadi dibuang tanpa dicatat, bisa jadi masih di bengkel.
   Tidak ada cara membedakannya dari data yang ada.
4. Base rate masih naik perlahan antar-kuartal, jadi PERINGKAT risiko lebih
   bisa dipercaya daripada angka probabilitas absolutnya.

Jalankan: python src/train_unrepairable_model.py
"""

from __future__ import annotations

import json
import warnings
from datetime import datetime, timezone

import joblib
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.dummy import DummyClassifier
from sklearn.ensemble import (
    ExtraTreesClassifier,
    GradientBoostingClassifier,
    RandomForestClassifier,
    VotingClassifier,
)
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    average_precision_score,
    balanced_accuracy_score,
    confusion_matrix,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.model_selection import (
    RepeatedStratifiedKFold,
    StratifiedKFold,
    cross_val_predict,
    cross_val_score,
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from database import PROJECT_DIR, connect

warnings.filterwarnings("ignore")

# Status yang berarti PART divonis mati (tidak kembali ke layanan).
SCRAP_STATUS = ("UNREPAIRABLE", "BROKEN")
# Sebelum tanggal ini status UNREPAIRABLE belum dipakai sama sekali.
ERA_START = "2025-04-01"
# Lihat docstring modul: bukti "diperbaiki" butuh waktu lebih lama muncul
# daripada vonis "dibuang", jadi ujung data harus dipotong supaya adil.
EMBARGO_DAYS = 30
# Potongan waktu untuk uji akhir dan untuk validasi berbasis waktu.
TEST_START = "2026-04-01"
INNER_VALIDATION_START = "2025-10-01"
ROLLING_CUTOFFS = ["2025-10-01", "2026-01-01", "2026-04-01"]
# Tipe PART dengan episode < 20 digabung supaya model tidak menghafal
# kategori yang sampelnya terlalu kecil.
MIN_TYPE_SUPPORT = 20
RANDOM_STATE = 42

CATEGORICAL_FEATURES = ["item_type_category"]
NUMERIC_FEATURES = [
    "log_age_total",
    "log_cycle_age",
    "log_prior_repaired_count",
    "has_prior_repair",
    "log_prior_failure_count",
    "is_first_failure_ever",
]
FEATURE_COLUMNS = CATEGORICAL_FEATURES + NUMERIC_FEATURES

MODEL_DIR = PROJECT_DIR / "models"
MODEL_PATH = MODEL_DIR / "unrepairable_scrap_model.joblib"
METADATA_PATH = MODEL_DIR / "unrepairable_scrap_metadata.json"

# Riwayat dihitung HANYA dari event pada atau sebelum kejadian kerusakan itu
# sendiri, memakai perbandingan (waktu, journey_id) supaya event yang detiknya
# sama tetap terurut benar dan tidak ada informasi sesudah vonis yang bocor.
DATASET_SQL = f"""
WITH data_boundary AS (
    SELECT MAX(created_on) AS data_end FROM analytics.item_journey_operational_timeline
),
episode AS (
    SELECT f.journey_id AS onset_journey_id, f.item_identifier_clean,
        f.failure_onset_on, f.item_model_code_clean, f.item_type_clean,
        f.client_clean, f.next_failure_outcome_status AS outcome,
        f.next_failure_outcome_on AS outcome_on,
        -- Bukti kedua bahwa PART selamat: dipasang kembali setelah rusak.
        f.next_installed_on, f.is_initial_model_cohort, b.data_end
    FROM analytics.failure_event_flow f
    CROSS JOIN data_boundary b
    WHERE f.failure_onset_on >= DATE '{ERA_START}'
)
SELECT e.*, c.installed_on, c.installation_sequence, h.*
FROM episode e
LEFT JOIN LATERAL (
    SELECT ic.installed_on, ic.installation_sequence
    FROM analytics.item_installation_cycle ic
    WHERE ic.item_identifier_clean = e.item_identifier_clean
      AND ic.installed_on <= e.failure_onset_on
    ORDER BY ic.installed_on DESC LIMIT 1
) c ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE o.event_semantic = 'FAILURE_ONSET') AS prior_failure_count,
        COUNT(*) FILTER (WHERE o.status_clean = 'REPAIRED') AS prior_repaired_count,
        MIN(o.created_on) AS first_ever_event_on
    FROM analytics.item_journey_operational_timeline o
    WHERE o.item_identifier_clean = e.item_identifier_clean
      AND (o.created_on, o.journey_id) <= (e.failure_onset_on, e.onset_journey_id)
) h ON TRUE
"""


def query(sql: str) -> pd.DataFrame:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall(), columns=[d.name for d in cur.description])


def load_dataset() -> tuple[pd.DataFrame, pd.DataFrame, np.ndarray]:
    """Ambil episode kerusakan yang hasilnya sudah bisa dipastikan, lalu bangun
    fitur. Lihat docstring modul untuk aturan label dan embargo."""
    raw = query(DATASET_SQL)
    raw = raw.loc[raw["is_initial_model_cohort"].fillna(False)].reset_index(drop=True)
    raw["failure_onset_on"] = pd.to_datetime(raw["failure_onset_on"])

    is_scrap = raw["outcome"].isin(SCRAP_STATUS)
    # Selamat kalau bengkel memvonis REPAIRED, atau PART terbukti dipasang lagi.
    is_survived = raw["outcome"].eq("REPAIRED") | raw["next_installed_on"].notna()
    data_end = pd.Timestamp(raw["data_end"].iloc[0])
    past_embargo = raw["failure_onset_on"] <= data_end - pd.Timedelta(days=EMBARGO_DAYS)

    raw = raw.loc[(is_scrap | is_survived) & past_embargo].reset_index(drop=True)

    onset = raw["failure_onset_on"]
    age_total = (onset - pd.to_datetime(raw["first_ever_event_on"])).dt.total_seconds() / 86400.0
    cycle_age = (onset - pd.to_datetime(raw["installed_on"])).dt.total_seconds() / 86400.0
    prior_repaired = pd.to_numeric(raw["prior_repaired_count"]).fillna(0)
    prior_failure = pd.to_numeric(raw["prior_failure_count"]).fillna(0)

    type_counts = raw["item_type_clean"].value_counts()
    frequent_types = type_counts[type_counts >= MIN_TYPE_SUPPORT].index

    features = pd.DataFrame(index=raw.index)
    features["item_type_category"] = (
        raw["item_type_clean"]
        .where(raw["item_type_clean"].isin(frequent_types), "LOW_SUPPORT")
        .fillna("UNKNOWN")
        .astype(str)
    )
    # Umur total PART sejak pertama kali tercatat - bukan umur siklus ini saja.
    features["log_age_total"] = np.log1p(age_total.fillna(0).clip(lower=0))
    features["log_cycle_age"] = np.log1p(cycle_age.fillna(0).clip(lower=0))
    # PART yang sudah pernah berhasil diperbaiki terbukti masih bisa
    # diperbaiki; yang baru pertama kali rusak di usia tua justru cenderung
    # langsung dibuang.
    features["log_prior_repaired_count"] = np.log1p(prior_repaired)
    features["has_prior_repair"] = (prior_repaired > 0).astype(int)
    features["log_prior_failure_count"] = np.log1p(prior_failure)
    features["is_first_failure_ever"] = (prior_failure <= 1).astype(int)

    target = raw["outcome"].isin(SCRAP_STATUS).astype(int).to_numpy()
    return raw, features[FEATURE_COLUMNS], target


def candidate_models() -> dict[str, Pipeline]:
    """Kandidat sengaja dibatasi pada model sederhana dan diregularisasi.

    Dengan 25 kejadian scrap di data latih, aturan lazim "minimal 10 kejadian
    per variabel" hanya membenarkan segelintir fitur. Model yang lebih rumit
    memang terlihat lebih baik saat divalidasi, tetapi jatuh saat diuji pada
    periode berikutnya - lihat tabel perbandingan yang dicetak script ini.
    """
    def scaled() -> ColumnTransformer:
        return ColumnTransformer([
            ("num", StandardScaler(), NUMERIC_FEATURES),
            ("cat", OneHotEncoder(handle_unknown="ignore", sparse_output=False), CATEGORICAL_FEATURES),
        ])

    def plain() -> ColumnTransformer:
        return ColumnTransformer([
            ("num", "passthrough", NUMERIC_FEATURES),
            ("cat", OneHotEncoder(handle_unknown="ignore", sparse_output=False), CATEGORICAL_FEATURES),
        ])

    def logistic() -> Pipeline:
        return Pipeline([("prep", scaled()), ("model", LogisticRegression(
            max_iter=5000, class_weight="balanced", C=0.3, random_state=RANDOM_STATE))])

    def forest() -> Pipeline:
        return Pipeline([("prep", plain()), ("model", RandomForestClassifier(
            n_estimators=500, max_depth=4, min_samples_leaf=10, class_weight="balanced",
            random_state=RANDOM_STATE, n_jobs=-1))])

    return {
        "Selalu 'bisa diperbaiki'": Pipeline([("prep", plain()), ("model", DummyClassifier(strategy="prior"))]),
        "Regresi Logistik": logistic(),
        "Random Forest": forest(),
        "Extra Trees": Pipeline([("prep", plain()), ("model", ExtraTreesClassifier(
            n_estimators=500, max_depth=4, min_samples_leaf=10, class_weight="balanced",
            random_state=RANDOM_STATE, n_jobs=-1))]),
        "Gradient Boosting": Pipeline([("prep", plain()), ("model", GradientBoostingClassifier(
            n_estimators=100, max_depth=2, learning_rate=0.05, random_state=RANDOM_STATE))]),
        # Rata-rata dua model yang cara salahnya berbeda: regresi logistik
        # menangkap kecenderungan lurus (makin tua makin sering dibuang),
        # random forest menangkap ambang dan kombinasi. Merata-ratakan
        # keduanya meredam kesalahan masing-masing.
        "Gabungan LogReg + RF": VotingClassifier(
            [("logreg", logistic()), ("forest", forest())], voting="soft"
        ),
    }


def compare_models(features: pd.DataFrame, target: np.ndarray, onset: pd.Series) -> pd.DataFrame:
    """Bandingkan kandidat memakai tiga cara sekaligus.

    Rolling-origin adalah dasar pemilihan: ia menguji tiap kandidat pada
    beberapa periode masa depan berturut-turut, jadi tidak bergantung pada
    satu potongan waktu yang kebetulan menguntungkan.

    Metrik pemilihannya PR-AUC, bukan ROC-AUC. Kejadian scrap jarang (7,8%),
    dan yang dibutuhkan operasional adalah menaruh episode yang benar-benar
    berakhir dibuang di peringkat atas. ROC-AUC ikut dilaporkan sebagai
    pembanding, tetapi pada data sekecil ini selisih ROC-AUC antar-kandidat
    teratas biasanya lebih kecil daripada ketidakpastiannya sendiri.
    """
    is_test = (onset >= pd.Timestamp(TEST_START)).to_numpy()
    inner_validation = (
        (onset >= pd.Timestamp(INNER_VALIDATION_START)) & (onset < pd.Timestamp(TEST_START))
    ).to_numpy()
    inner_train = (onset < pd.Timestamp(INNER_VALIDATION_START)).to_numpy()
    cv = RepeatedStratifiedKFold(n_splits=5, n_repeats=4, random_state=RANDOM_STATE)

    rows = []
    for name, pipeline in candidate_models().items():
        cv_auc = cross_val_score(
            pipeline, features[~is_test], target[~is_test], cv=cv, scoring="roc_auc", n_jobs=1
        ).mean()

        pipeline.fit(features[inner_train], target[inner_train])
        validation_auc = roc_auc_score(
            target[inner_validation],
            pipeline.predict_proba(features[inner_validation])[:, 1],
        )

        rolling_roc, rolling_pr = [], []
        for cutoff in ROLLING_CUTOFFS:
            future = (onset >= pd.Timestamp(cutoff)).to_numpy()
            pipeline.fit(features[~future], target[~future])
            future_probability = pipeline.predict_proba(features[future])[:, 1]
            rolling_roc.append(roc_auc_score(target[future], future_probability))
            rolling_pr.append(average_precision_score(target[future], future_probability))

        pipeline.fit(features[~is_test], target[~is_test])
        probability = pipeline.predict_proba(features[is_test])[:, 1]
        rows.append({
            "model": name,
            "cv_acak": cv_auc,
            "validasi_waktu": validation_auc,
            "rolling_roc": float(np.mean(rolling_roc)),
            "rolling_pr": float(np.mean(rolling_pr)),
            "test_roc_auc": roc_auc_score(target[is_test], probability),
            "test_pr_auc": average_precision_score(target[is_test], probability),
        })
    return pd.DataFrame(rows)


def choose_threshold(pipeline: Pipeline, features: pd.DataFrame, target: np.ndarray) -> float:
    """Pilih ambang dari data LATIH saja (prediksi out-of-fold), bukan dari
    data uji - kalau ambang disetel di data uji, angka yang dilaporkan
    bukan lagi estimasi jujur untuk data baru."""
    folds = StratifiedKFold(n_splits=5, shuffle=True, random_state=RANDOM_STATE)
    out_of_fold = cross_val_predict(
        pipeline, features, target, cv=folds, method="predict_proba", n_jobs=1
    )[:, 1]
    candidates = np.round(np.arange(0.30, 0.86, 0.01), 2)
    scores = [balanced_accuracy_score(target, (out_of_fold >= t).astype(int)) for t in candidates]
    return float(candidates[int(np.argmax(scores))])


def main() -> int:
    MODEL_DIR.mkdir(exist_ok=True)
    raw, features, target = load_dataset()
    onset = raw["failure_onset_on"]
    is_test = (onset >= pd.Timestamp(TEST_START)).to_numpy()

    print(f"Episode kerusakan berlabel sejak {ERA_START} (embargo {EMBARGO_DAYS} hari): {len(raw):,}")
    print(f"  dibuang (scrap) : {target.sum():,} ({target.mean():.1%})")
    print(f"  diperbaiki      : {(1 - target).sum():,}")
    print(f"  LATIH {(~is_test).sum():,} baris / {target[~is_test].sum()} scrap "
          f"({target[~is_test].mean():.1%})   "
          f"UJI {is_test.sum():,} baris / {target[is_test].sum()} scrap "
          f"({target[is_test].mean():.1%})")
    print(f"  Akurasi kalau selalu tebak 'bisa diperbaiki' pada UJI: {1 - target[is_test].mean():.1%}\n")

    comparison = compare_models(features, target, onset)
    print("=== Perbandingan model ===")
    print(comparison.to_string(index=False, float_format=lambda v: f"{v:.3f}"))

    # Pemilihan memakai PR-AUC rolling-origin, bukan angka uji akhir.
    ranked = comparison[comparison.model != "Selalu 'bisa diperbaiki'"].sort_values(
        "rolling_pr", ascending=False
    )
    best_name = ranked.iloc[0]["model"]
    print(f"\nTerpilih menurut PR-AUC rolling-origin: {best_name}")
    if len(ranked) > 1:
        runner_up = ranked.iloc[1]
        print(f"  Pembanding terdekat {runner_up['model']}: "
              f"PR-AUC {runner_up['rolling_pr']:.3f} vs {ranked.iloc[0]['rolling_pr']:.3f}, "
              f"ROC-AUC {runner_up['rolling_roc']:.3f} vs {ranked.iloc[0]['rolling_roc']:.3f}")
        print(f"  Pada {target.sum()} kejadian scrap, selisih sekecil ini belum bisa disebut")
        print("  beda nyata - keduanya sama-sama masuk akal dipakai.")

    pipeline = candidate_models()[best_name]
    threshold = choose_threshold(pipeline, features[~is_test], target[~is_test])
    pipeline.fit(features[~is_test], target[~is_test])

    probability = pipeline.predict_proba(features[is_test])[:, 1]
    predicted = (probability >= threshold).astype(int)
    actual = target[is_test]
    metrics = {
        "threshold": threshold,
        "roc_auc": float(roc_auc_score(actual, probability)),
        "pr_auc": float(average_precision_score(actual, probability)),
        "pr_auc_baseline": float(actual.mean()),
        "accuracy": float(accuracy_score(actual, predicted)),
        "balanced_accuracy": float(balanced_accuracy_score(actual, predicted)),
        "precision": float(precision_score(actual, predicted, zero_division=0)),
        "recall": float(recall_score(actual, predicted)),
        "confusion_matrix": confusion_matrix(actual, predicted).tolist(),
        "rows": int(is_test.sum()),
        "positives": int(actual.sum()),
    }

    print(f"\n=== Hasil pada data uji ({TEST_START} dan sesudahnya) ===")
    print(f"  ROC-AUC           : {metrics['roc_auc']:.3f}")
    print(f"  PR-AUC            : {metrics['pr_auc']:.3f}  (tebakan acak = {metrics['pr_auc_baseline']:.3f})")
    print(f"  Ambang dari latih : {threshold:.2f}")
    print(f"  Akurasi           : {metrics['accuracy']:.1%}")
    print(f"  Balanced accuracy : {metrics['balanced_accuracy']:.1%}")
    print(f"  Presisi / Recall  : {metrics['precision']:.1%} / {metrics['recall']:.1%}")
    matrix = metrics["confusion_matrix"]
    print(f"  Ditandai berisiko : {matrix[0][1] + matrix[1][1]} dari {metrics['rows']} episode, "
          f"menangkap {matrix[1][1]} dari {metrics['positives']} scrap sesungguhnya")

    # Tabel ini BUKAN dasar pemilihan (ambang resmi sudah ditetapkan dari data
    # latih di atas) - hanya memperlihatkan pertukaran yang tersedia kalau
    # operasional ingin menggeser titik kerja.
    print("\n=== Sensitivitas ambang pada data uji (bukan dasar pemilihan) ===")
    print(f"  {'ambang':>7s} {'akurasi':>8s} {'balacc':>7s} {'presisi':>8s} {'recall':>7s} {'ditandai':>9s}")
    for candidate in [0.40, 0.45, 0.51, 0.55, 0.60, 0.65]:
        flagged = (probability >= candidate).astype(int)
        if flagged.sum() == 0:
            continue
        marker = "  <- dipakai" if abs(candidate - threshold) < 1e-9 else ""
        print(f"  {candidate:7.2f} {accuracy_score(actual, flagged):8.1%} "
              f"{balanced_accuracy_score(actual, flagged):7.1%} "
              f"{precision_score(actual, flagged, zero_division=0):8.1%} "
              f"{recall_score(actual, flagged):7.1%} {flagged.sum():9d}{marker}")

    # Kalau yang terpilih model gabungan, kontribusi fitur dibaca dari anggota
    # random forest-nya - gabungan itu sendiri tidak punya angka kontribusi.
    inspected = pipeline
    if isinstance(pipeline, VotingClassifier):
        inspected = dict(pipeline.named_estimators_)["forest"]
    encoder = inspected.named_steps["prep"].named_transformers_["cat"]
    names = NUMERIC_FEATURES + list(encoder.get_feature_names_out(CATEGORICAL_FEATURES))
    estimator = inspected.named_steps["model"]
    if hasattr(estimator, "feature_importances_"):
        importance = pd.Series(estimator.feature_importances_, index=names).sort_values(ascending=False)
        print("\n=== Kontribusi fitur ===")
        print(importance.head(10).to_string())

    joblib.dump(pipeline, MODEL_PATH)
    metadata = {
        "trained_at_utc": datetime.now(timezone.utc).isoformat(),
        "question": "Saat sebuah PART rusak, apakah kerusakan itu berakhir dibuang (UNREPAIRABLE/BROKEN)?",
        "selected_model": best_name,
        "selection_rule": "PR-AUC rata-rata rolling-origin pada 3 titik potong waktu",
        "scrap_status": list(SCRAP_STATUS),
        "era_start": ERA_START,
        "embargo_days": EMBARGO_DAYS,
        "label_rule": {
            "scrap": "vonis bengkel UNREPAIRABLE atau BROKEN",
            "survived": "vonis bengkel REPAIRED, atau PART terbukti dipasang kembali",
            "excluded": "tanpa vonis dan tidak pernah dipasang lagi, atau masuk masa embargo",
        },
        "test_start": TEST_START,
        "feature_columns": FEATURE_COLUMNS,
        "categorical_features": CATEGORICAL_FEATURES,
        "rows": {"total": int(len(raw)), "scrap": int(target.sum())},
        "model_comparison": comparison.to_dict(orient="records"),
        "test_metrics": metrics,
        "limitations": [
            "Status UNREPAIRABLE baru ada sejak 2025-04-23; populasi dibatasi mulai 2025-04-01.",
            "Kejadian scrap masih sedikit - metrik uji berisik.",
            "Base rate masih naik perlahan antar-kuartal; peringkat risiko lebih bisa dipercaya daripada probabilitas absolut.",
            "Episode tanpa vonis DAN tidak pernah dipasang lagi tetap tidak bisa dilabeli, jadi dikeluarkan.",
        ],
    }
    METADATA_PATH.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n[OK] Model disimpan  : {MODEL_PATH}")
    print(f"[OK] Metadata disimpan: {METADATA_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
