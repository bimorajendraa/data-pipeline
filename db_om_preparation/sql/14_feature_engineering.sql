-- Feature engineering untuk baseline dan challenger failure PART 30 hari.
-- View fitur sengaja tidak membawa target, future failure, cycle end, maupun
-- flag observability agar modeling tidak dapat mengambil leakage secara tidak
-- sengaja. Label dan split waktu berada pada view terpisah.

DROP VIEW IF EXISTS analytics.failure_30d_model_audit;
DROP VIEW IF EXISTS analytics.failure_30d_feature_quality_summary;
DROP VIEW IF EXISTS analytics.failure_30d_challenger_features;
DROP VIEW IF EXISTS analytics.failure_30d_model_labels;
DROP VIEW IF EXISTS analytics.failure_30d_feature_catalog;
DO $drop_baseline_features$
DECLARE object_kind "char";
BEGIN
    SELECT c.relkind INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'failure_30d_baseline_features';
    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.failure_30d_baseline_features';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.failure_30d_baseline_features';
    END IF;
END $drop_baseline_features$;

CREATE VIEW analytics.failure_30d_feature_catalog AS
SELECT * FROM (VALUES
    ('part_model_category', 'item_model_code_clean', 'CATEGORICAL',
     'KEEP_BASELINE', 'ONE_HOT_RARE_GROUP', 'UNKNOWN_CATEGORY',
     'Model PART merupakan identitas teknis utama dan risiko berbeda antar-model'),
    ('client_category', 'installed_client_clean', 'CATEGORICAL',
     'KEEP_BASELINE', 'ONE_HOT', 'UNKNOWN_CATEGORY',
     'Empat kategori dengan coverage penuh; konteks operasional yang murah'),
    ('log_days_since_installation', 'days_since_installation', 'DURATION',
     'KEEP_BASELINE', 'LOG1P', 'NOT_NULL_BY_COHORT',
     'Umur cycle informatif tetapi sangat right-skewed'),
    ('installation_age_band', 'days_since_installation', 'DURATION',
     'KEEP_BASELINE', 'BUSINESS_BINS', 'UNKNOWN_CATEGORY',
     'Menangkap hubungan umur non-linear yang tidak diwakili satu koefisien'),
    ('log_total_prior_events', 'total_prior_events', 'COUNT',
     'KEEP_BASELINE', 'LOG1P', 'ZERO_IS_VALID',
     'IV tinggi; intensitas histori tanpa dominasi outlier count'),
    ('log_prior_failure_count', 'prior_failure_count', 'COUNT',
     'KEEP_BASELINE', 'LOG1P', 'ZERO_IS_NEVER_FAILED',
     'Failure berulang kuat membedakan snapshot positif dan negatif'),
    ('has_prior_failure', 'prior_failure_count', 'BINARY',
     'KEEP_BASELINE', 'GREATER_THAN_ZERO', 'FALSE_IS_VALID',
     'Memisahkan PART yang belum pernah failure dari recurrent failure'),
    ('log_prior_corrective_count', 'prior_corrective_count', 'COUNT',
     'KEEP_BASELINE', 'LOG1P', 'ZERO_IS_NEVER_CORRECTIVE',
     'Histori corrective mempunyai IV tinggi dan relevansi bisnis langsung'),
    ('has_prior_corrective', 'prior_corrective_count', 'BINARY',
     'KEEP_BASELINE', 'GREATER_THAN_ZERO', 'FALSE_IS_VALID',
     'Pendamping missing struktural recency corrective'),
    ('log_days_since_last_corrective', 'days_since_last_corrective', 'DURATION',
     'KEEP_BASELINE', 'LOG1P_PLUS_FLAG', 'ZERO_PLUS_HAS_PRIOR_FLAG',
     'Screening IV tertinggi; missing berarti belum pernah corrective'),
    ('log_prior_distinct_places', 'prior_distinct_places', 'COUNT',
     'KEEP_BASELINE', 'LOG1P', 'ZERO_IS_VALID',
     'Mobilitas/lifecycle mempunyai IV tinggi'),
    ('log_prior_corrective_30d', 'prior_corrective_30d', 'COUNT',
     'KEEP_BASELINE', 'LOG1P', 'ZERO_IS_VALID',
     'Window corrective 30 hari kuat pada screening train'),
    ('log_prior_failure_365d', 'prior_failure_365d', 'COUNT',
     'KEEP_BASELINE', 'LOG1P', 'ZERO_IS_VALID',
     'Menangkap failure yang masih relatif baru'),
    ('log_prior_events_180d', 'prior_events_180d', 'COUNT',
     'KEEP_BASELINE', 'LOG1P', 'ZERO_IS_VALID',
     'Window event 180 hari mempunyai IV sedang dan lebih stabil dari window pendek'),
    ('month_sin', 'observation_month', 'CALENDAR',
     'KEEP_BASELINE', 'CYCLIC_SIN', 'NOT_NULL',
     'Musiman tanpa menganggap Desember jauh dari Januari'),
    ('month_cos', 'observation_month', 'CALENDAR',
     'KEEP_BASELINE', 'CYCLIC_COS', 'NOT_NULL',
     'Pasangan month_sin untuk merepresentasikan siklus tahunan'),
    ('location_category', 'last_place_clean', 'CATEGORICAL',
     'KEEP_CHALLENGER', 'ONE_HOT_RARE_GROUP', 'UNKNOWN_CATEGORY',
     'Coverage tinggi dan rate berbeda, tetapi perlu uji generalisasi tanpa lokasi'),
    ('terminal_type_category', 'terminal_type', 'HIERARCHY',
     'KEEP_CHALLENGER', 'ONE_HOT_LOW_SUPPORT_GROUP', 'UNKNOWN_CATEGORY',
     'Ablation study (2026-08) menemukan jenis TERMINAL baru dengan riwayat sedikit (contoh BALANCE READER, mulai dipasang 2023) mempunyai rate failure train vs validasi yang jauh berbeda dan menjatuhkan PR-AUC; dikelompokkan LOW_HISTORICAL_SUPPORT point-in-time (<300 observasi kumulatif) sebelum dipakai'),
    ('terminal_model_category', 'terminal_model_code', 'HIERARCHY',
     'KEEP_CHALLENGER', 'ONE_HOT_LOW_SUPPORT_GROUP', 'UNKNOWN_CATEGORY',
     'Lebih detail daripada tipe terminal sehingga lebih rawan sparsity; memakai pengelompokan dukungan historis point-in-time yang sama seperti terminal_type_category'),
    ('last_status_category', 'last_status_clean', 'CATEGORICAL',
     'KEEP_CHALLENGER', 'ONE_HOT_RARE_GROUP', 'UNKNOWN_CATEGORY',
     'Point-in-time valid, tetapi perlu audit apakah hanya menangkap proses pencatatan'),
    ('part_terminal_type_interaction', 'part_model_code + terminal_type', 'INTERACTION',
     'KEEP_CHALLENGER', 'CONCAT_LOW_SUPPORT_GROUP', 'UNKNOWN_CATEGORY',
     'Compatibility PART-terminal dapat non-linear; memakai terminal_type yang sudah dikelompokkan dukungan historisnya, ditambah minimum support saat encoding'),
    ('part_location_interaction', 'part_model_code + last_place_clean', 'INTERACTION',
     'KEEP_CHALLENGER', 'CONCAT_RARE_GROUP', 'UNKNOWN_CATEGORY',
     'Menguji risiko kombinasi model-lokasi tanpa mengklaim kausalitas'),
    ('log_days_since_last_event', 'days_since_last_event', 'DURATION',
     'KEEP_CHALLENGER', 'LOG1P', 'NOT_NULL_BY_CONSTRUCTION',
     'Informatif tetapi hampir duplikat umur installation; selalu terisi karena setiap cycle minimal punya event INSTALLED-nya sendiri'),
    ('log_days_at_last_location', 'days_at_last_location', 'DURATION',
     'KEEP_CHALLENGER', 'LOG1P', 'NOT_NULL_BY_CONSTRUCTION',
     'Informatif tetapi sangat berkorelasi dengan umur dan last-event recency; selalu terisi karena event pertama sebuah item selalu terhitung sebagai perubahan lokasi'),
    ('day_of_week_sin', 'observation_day_of_week', 'CALENDAR',
     'KEEP_CHALLENGER', 'CYCLIC_SIN', 'NOT_NULL',
     'Efek jadwal mungkin ada, tetapi dapat menjadi artefak cadence snapshot'),
    ('day_of_week_cos', 'observation_day_of_week', 'CALENDAR',
     'KEEP_CHALLENGER', 'CYCLIC_COS', 'NOT_NULL',
     'Pasangan day_of_week_sin'),
    ('observation_year', 'observation_year', 'CALENDAR',
     'AUDIT_ONLY', 'NONE', 'NOT_NULL',
     'Proxy perubahan sistem pencatatan dan tidak aman untuk extrapolation baseline'),
    ('parent_link_quality_status', 'parent_link_quality_status', 'QUALITY',
     'AUDIT_ONLY', 'NONE', 'NOT_NULL',
     'Digunakan untuk sensitivity backfill, bukan shortcut predictor era'),
    ('is_parent_link_recorded_after_installation',
     'is_parent_link_recorded_after_installation', 'QUALITY',
     'AUDIT_ONLY', 'NONE', 'FALSE_OR_TRUE',
     'Flag backfill dapat membocorkan era pencatatan jika dijadikan predictor'),
    ('item_identifier_clean', 'item_identifier_clean', 'IDENTIFIER',
     'AUDIT_ONLY', 'NONE', 'NOT_NULL',
     'Hanya untuk grouping, clustered validation, dan traceability'),
    ('installation_cycle_id', 'installation_cycle_id', 'IDENTIFIER',
     'AUDIT_ONLY', 'NONE', 'NOT_NULL',
     'Hanya key join; one-hot akan memorisasi cycle'),
    ('days_since_last_failure', 'days_since_last_failure', 'DURATION',
     'DROP_REDUNDANT', 'NONE', 'STRUCTURAL_MISSING',
     'Missing 94% dan berkorelasi tinggi dengan corrective recency'),
    ('days_since_last_event', 'days_since_last_event', 'DURATION',
     'DROP_REPLACED', 'REPLACED_BY_OPTIONAL_LOG', 'STRUCTURAL_MISSING',
     'Raw scale sangat skewed dan hampir duplikat umur'),
    ('days_at_last_location', 'days_at_last_location', 'DURATION',
     'DROP_REPLACED', 'REPLACED_BY_OPTIONAL_LOG', 'STRUCTURAL_MISSING',
     'Raw scale hampir duplikat last-event/installation age'),
    ('prior_events_30d', 'prior_events_30d', 'COUNT',
     'DROP_WEAK', 'NONE', 'ZERO_IS_VALID',
     'IV univariat nol pada train'),
    ('prior_events_90d', 'prior_events_90d', 'COUNT',
     'DROP_WEAK', 'NONE', 'ZERO_IS_VALID',
     'IV univariat nol; window 180 hari dipilih sebagai wakil'),
    ('prior_corrective_90d', 'prior_corrective_90d', 'COUNT',
     'DROP_REDUNDANT_WEAK', 'NONE', 'ZERO_IS_VALID',
     'IV nol dan redundan dengan count total/30 hari'),
    ('prior_corrective_180d', 'prior_corrective_180d', 'COUNT',
     'DROP_REDUNDANT_WEAK', 'NONE', 'ZERO_IS_VALID',
     'IV nol dan redundan dengan count total/30 hari'),
    ('prior_preventive_count', 'prior_preventive_count', 'COUNT',
     'DROP_WEAK', 'NONE', 'ZERO_IS_VALID',
     'IV nol dan event preventive sangat jarang'),
    ('prior_preventive_30d_90d_180d', 'prior_preventive_*', 'COUNT',
     'DROP_WEAK', 'NONE', 'ZERO_IS_VALID',
     'Window preventive tidak menunjukkan separation pada EDA'),
    ('prior_relocation_count', 'prior_relocation_count', 'COUNT',
     'DROP_WEAK', 'NONE', 'ZERO_IS_VALID',
     'IV sekitar 0.001; tidak layak menambah kompleksitas baseline'),
    ('prior_repair_process_count', 'prior_repair_process_count', 'COUNT',
     'DROP_WEAK_DRIFT', 'NONE', 'ZERO_IS_VALID',
     'IV nol dan definisi proses berubah sejak 2025'),
    ('observation_quarter', 'observation_quarter', 'CALENDAR',
     'DROP_REDUNDANT', 'NONE', 'NOT_NULL',
     'Redundan dengan representasi siklik bulan'),
    ('is_weekend', 'is_weekend', 'CALENDAR',
     'DROP_REDUNDANT', 'NONE', 'NOT_NULL',
     'Redundan dengan hari dalam minggu dan berpotensi artefak cadence'),
    ('installed_on', 'installed_on', 'RAW_DATETIME',
     'DROP_RAW', 'DERIVE_DURATION_ONLY', 'NOT_NULL',
     'Timestamp absolut mendorong memorisasi era dan sudah diturunkan menjadi umur'),
    ('observation_date', 'observation_date', 'RAW_DATETIME',
     'DROP_RAW', 'DERIVE_CALENDAR_ONLY', 'NOT_NULL',
     'Tanggal absolut tidak dipakai sebagai predictor'),
    ('future_failure_columns', 'next_failure_*', 'LEAKAGE',
     'DROP_LEAKAGE', 'NONE', 'NOT_APPLICABLE',
     'Berisi jawaban atau informasi setelah snapshot'),
    ('cycle_end_and_observability', 'cycle_end_* / is_*observable', 'LEAKAGE',
     'DROP_LEAKAGE', 'NONE', 'NOT_APPLICABLE',
     'Menjelaskan bagaimana label masa depan dapat diketahui')
) AS catalog(
    feature_name, source_column, feature_group, decision,
    transformation, missing_handling, rationale
);

CREATE VIEW analytics.failure_30d_model_labels AS
SELECT installation_cycle_id, item_identifier_clean, observation_on,
    target_failure_30d,
    is_training_eligible,
    is_strict_training_eligible,
    is_recon_verified_training_eligible,
    target_quality_status,
    CASE
        WHEN NOT is_training_eligible THEN 'EXCLUDED_LABEL_QUALITY'
        WHEN observation_on < DATE '2014-01-01' THEN 'EXCLUDED_PRE_2014'
        WHEN observation_on + INTERVAL '30 days' < DATE '2025-01-01'
            THEN 'TRAIN_2014_2024'
        WHEN observation_on < DATE '2025-01-01'
            THEN 'EXCLUDED_TRAIN_EMBARGO'
        WHEN observation_on + INTERVAL '30 days' < DATE '2026-01-01'
            THEN 'VALIDATION_2025'
        WHEN observation_on < DATE '2026-01-01'
            THEN 'EXCLUDED_VALIDATION_EMBARGO'
        ELSE 'TEST_2026'
    END AS temporal_split
FROM analytics.item_observation_30d;

CREATE MATERIALIZED VIEW analytics.failure_30d_baseline_features AS
SELECT
    installation_cycle_id,
    item_identifier_clean,
    observation_on,
    COALESCE(item_model_code_clean, 'UNKNOWN') AS part_model_category,
    COALESCE(installed_client_clean, 'UNKNOWN') AS client_category,
    LN(1.0 + GREATEST(days_since_installation, 0))
        AS log_days_since_installation,
    CASE
        WHEN days_since_installation < 91 THEN '000_090_DAYS'
        WHEN days_since_installation < 181 THEN '091_180_DAYS'
        WHEN days_since_installation < 366 THEN '181_365_DAYS'
        WHEN days_since_installation < 731 THEN '366_730_DAYS'
        WHEN days_since_installation < 1461 THEN '731_1460_DAYS'
        ELSE '1461_PLUS_DAYS'
    END AS installation_age_band,
    LN(1.0 + GREATEST(total_prior_events, 0)) AS log_total_prior_events,
    LN(1.0 + GREATEST(prior_failure_count, 0)) AS log_prior_failure_count,
    prior_failure_count > 0 AS has_prior_failure,
    LN(1.0 + GREATEST(prior_corrective_count, 0))
        AS log_prior_corrective_count,
    prior_corrective_count > 0 AS has_prior_corrective,
    LN(1.0 + GREATEST(COALESCE(days_since_last_corrective, 0), 0))
        AS log_days_since_last_corrective,
    LN(1.0 + GREATEST(prior_distinct_places, 0))
        AS log_prior_distinct_places,
    LN(1.0 + GREATEST(prior_corrective_30d, 0))
        AS log_prior_corrective_30d,
    LN(1.0 + GREATEST(prior_failure_365d, 0))
        AS log_prior_failure_365d,
    LN(1.0 + GREATEST(prior_events_180d, 0)) AS log_prior_events_180d,
    SIN(2.0 * PI() * (observation_month - 1) / 12.0) AS month_sin,
    COS(2.0 * PI() * (observation_month - 1) / 12.0) AS month_cos
FROM analytics.eda_item_observation_30d_hierarchy;

CREATE UNIQUE INDEX failure_30d_baseline_features_key_idx
    ON analytics.failure_30d_baseline_features (
        installation_cycle_id, observation_on
    );
CREATE INDEX failure_30d_baseline_features_item_idx
    ON analytics.failure_30d_baseline_features (
        item_identifier_clean, observation_on
    );

CREATE VIEW analytics.failure_30d_challenger_features AS
SELECT b.*,
    CASE WHEN h.is_location_feature_eligible
         THEN h.last_place_clean ELSE 'UNKNOWN' END AS location_category,
    -- Jenis/model TERMINAL yang dukungan historisnya masih di bawah batas
    -- aman (peralatan baru dengan sedikit riwayat) dikelompokkan tersendiri
    -- alih-alih diberi kategori sendiri, supaya model tidak menghafal pola
    -- dari sampel yang terlalu kecil (lihat catatan pada 12b, kasus
    -- BALANCE READER yang baru mulai dipasang 2023).
    CASE WHEN NOT h.is_parent_link_valid THEN 'UNKNOWN'
         WHEN h.terminal_type_cumulative_support < 300 THEN 'LOW_HISTORICAL_SUPPORT'
         ELSE COALESCE(h.terminal_type, 'UNKNOWN') END
        AS terminal_type_category,
    CASE WHEN NOT h.is_parent_link_valid THEN 'UNKNOWN'
         WHEN h.terminal_model_cumulative_support < 300 THEN 'LOW_HISTORICAL_SUPPORT'
         ELSE COALESCE(h.terminal_model_code, 'UNKNOWN') END
        AS terminal_model_category,
    COALESCE(h.last_status_clean, 'UNKNOWN') AS last_status_category,
    b.part_model_category || '|' ||
        CASE WHEN NOT h.is_parent_link_valid THEN 'UNKNOWN'
             WHEN h.terminal_type_cumulative_support < 300 THEN 'LOW_HISTORICAL_SUPPORT'
             ELSE COALESCE(h.terminal_type, 'UNKNOWN') END
        AS part_terminal_type_interaction,
    b.part_model_category || '|' ||
        CASE WHEN h.is_location_feature_eligible
             THEN h.last_place_clean ELSE 'UNKNOWN' END
        AS part_location_interaction,
    LN(1.0 + GREATEST(COALESCE(h.days_since_last_event, 0), 0))
        AS log_days_since_last_event,
    LN(1.0 + GREATEST(COALESCE(h.days_at_last_location, 0), 0))
        AS log_days_at_last_location,
    SIN(2.0 * PI() * (h.observation_day_of_week - 1) / 7.0)
        AS day_of_week_sin,
    COS(2.0 * PI() * (h.observation_day_of_week - 1) / 7.0)
        AS day_of_week_cos
FROM analytics.failure_30d_baseline_features b
JOIN analytics.eda_item_observation_30d_hierarchy h
  USING (installation_cycle_id, item_identifier_clean, observation_on);

CREATE VIEW analytics.failure_30d_feature_quality_summary AS
WITH baseline AS MATERIALIZED (
    SELECT * FROM analytics.failure_30d_baseline_features
), duplicate_key AS (
    SELECT COUNT(*)::numeric AS duplicate_group_count
    FROM (
        SELECT installation_cycle_id, observation_on
        FROM baseline
        GROUP BY installation_cycle_id, observation_on
        HAVING COUNT(*) > 1
    ) d
), label_key AS (
    SELECT COUNT(*)::numeric AS label_count
    FROM analytics.failure_30d_model_labels
)
SELECT 'baseline_feature_rows'::text AS metric, COUNT(*)::numeric AS value,
    'Harus sama dengan seluruh item_observation_30d'::text AS expectation
FROM baseline
UNION ALL SELECT 'label_rows', label_count,
    'Harus sama dengan baseline_feature_rows' FROM label_key
UNION ALL SELECT 'duplicate_feature_keys', duplicate_group_count,
    'Harus nol' FROM duplicate_key
UNION ALL SELECT 'null_core_categories',
    COUNT(*) FILTER (WHERE part_model_category IS NULL
        OR client_category IS NULL OR installation_age_band IS NULL)::numeric,
    'Harus nol' FROM baseline
UNION ALL SELECT 'null_engineered_numeric',
    COUNT(*) FILTER (WHERE log_days_since_installation IS NULL
        OR log_total_prior_events IS NULL
        OR log_prior_failure_count IS NULL
        OR log_prior_corrective_count IS NULL
        OR log_days_since_last_corrective IS NULL
        OR log_prior_distinct_places IS NULL
        OR log_prior_corrective_30d IS NULL
        OR log_prior_failure_365d IS NULL
        OR log_prior_events_180d IS NULL
        OR month_sin IS NULL OR month_cos IS NULL)::numeric,
    'Harus nol' FROM baseline;

-- View gabungan hanya untuk QA/EDA. Training harus membaca features dan labels
-- secara terpisah, kemudian join eksplisit pada tiga key di bawah.
CREATE VIEW analytics.failure_30d_model_audit AS
SELECT f.*, l.target_failure_30d, l.is_training_eligible,
    l.is_strict_training_eligible, l.target_quality_status, l.temporal_split,
    h.parent_link_quality_status,
    h.is_parent_link_recorded_after_installation,
    h.parent_link_recording_delay_days
FROM analytics.failure_30d_challenger_features f
JOIN analytics.failure_30d_model_labels l
  USING (installation_cycle_id, item_identifier_clean, observation_on)
JOIN analytics.eda_item_observation_30d_hierarchy h
  USING (installation_cycle_id, item_identifier_clean, observation_on);

-- Tahap 14 memperluas refresh procedure tahap 13 dengan cache fitur baseline.
CREATE OR REPLACE PROCEDURE analytics.refresh_cached_views() LANGUAGE plpgsql AS $refresh$
BEGIN
    REFRESH MATERIALIZED VIEW analytics.data_profile;
    REFRESH MATERIALIZED VIEW analytics.item_journey_event_cache;
    REFRESH MATERIALIZED VIEW analytics.item_identifier_model_cache;
    REFRESH MATERIALIZED VIEW analytics.failure_event_clean;
    REFRESH MATERIALIZED VIEW analytics.item_journey_semantic;
    REFRESH MATERIALIZED VIEW analytics.item_journey_operational_timeline;
    REFRESH MATERIALIZED VIEW analytics.item_journey_transition_profile;
    REFRESH MATERIALIZED VIEW analytics.data_quality_summary;
    REFRESH MATERIALIZED VIEW analytics.failure_event_flow;
    REFRESH MATERIALIZED VIEW analytics.item_installation_cycle;
    REFRESH MATERIALIZED VIEW analytics.item_observation_30d;
    REFRESH MATERIALIZED VIEW analytics.eda_part_terminal_cycle_link;
    REFRESH MATERIALIZED VIEW analytics.eda_snapshot_cadence_comparison;
    REFRESH MATERIALIZED VIEW analytics.eda_feature_stability_monthly;
    REFRESH MATERIALIZED VIEW analytics.failure_30d_baseline_features;
END; $refresh$;
