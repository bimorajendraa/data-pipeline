-- Seluruh view pendukung EDA berada dalam satu tahap agar dependency bisnis,
-- quality review, lifecycle, dan refresh dapat dibaca dari satu tempat.

-- =========================================================
-- A. READINESS DAN COVERAGE
-- =========================================================
-- Ringkasan ringan untuk notebook dan pemeriksaan lewat SQL.
DROP MATERIALIZED VIEW IF EXISTS analytics.eda_feature_stability_monthly;

CREATE OR REPLACE VIEW analytics.eda_failure_readiness_summary AS
SELECT 'installation_cycles'::text metric, COUNT(*)::numeric value FROM analytics.item_installation_cycle
UNION ALL SELECT 'valid_model_cohort_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE is_initial_model_cohort
UNION ALL SELECT 'invalid_zero_duration_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE NOT is_cycle_time_valid
UNION ALL SELECT 'cycles_with_failure', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE has_observed_failure
UNION ALL SELECT 'right_censored_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE is_right_censored
UNION ALL SELECT 'unknown_reinstall_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE cycle_end_reason = 'REINSTALL_WITHOUT_RECORDED_FAILURE'
UNION ALL SELECT 'right_censored_coverage_unconfirmed_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE cycle_quality_status = 'RIGHT_CENSORED_ACTIVITY_COVERAGE_UNCONFIRMED'
UNION ALL SELECT 'all_observations', COUNT(*)::numeric FROM analytics.item_observation_30d
UNION ALL SELECT 'training_eligible_observations', COUNT(*)::numeric FROM analytics.item_observation_30d WHERE is_training_eligible
UNION ALL SELECT 'strict_training_eligible_observations', COUNT(*)::numeric FROM analytics.item_observation_30d WHERE is_strict_training_eligible
UNION ALL SELECT 'positive_30d_observations', COUNT(*)::numeric FROM analytics.item_observation_30d WHERE is_training_eligible AND target_failure_30d
UNION ALL SELECT 'excluded_incomplete_followup', COUNT(*)::numeric FROM analytics.item_observation_30d WHERE NOT is_target_observable;

CREATE OR REPLACE VIEW analytics.eda_failure_rate_by_year AS
SELECT EXTRACT(YEAR FROM observation_on)::integer observation_year, COUNT(*) observation_count,
    COUNT(*) FILTER (WHERE target_failure_30d) positive_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE target_failure_30d) / NULLIF(COUNT(*), 0), 4) positive_percentage
FROM analytics.item_observation_30d WHERE is_training_eligible
GROUP BY EXTRACT(YEAR FROM observation_on)::integer;

CREATE OR REPLACE VIEW analytics.eda_target_class_distribution AS
WITH class_count AS (
    SELECT target_failure_30d AS target_value, COUNT(*)::bigint AS snapshot_count
    FROM analytics.item_observation_30d
    WHERE is_training_eligible
    GROUP BY target_failure_30d
), total AS (
    SELECT SUM(snapshot_count)::bigint AS total_snapshot,
        SUM(snapshot_count) FILTER (WHERE target_value)::bigint AS positive_snapshot,
        SUM(snapshot_count) FILTER (WHERE NOT target_value)::bigint AS negative_snapshot
    FROM class_count
)
SELECT c.target_value::integer AS label_value,
    CASE WHEN c.target_value THEN 'FAILURE_WITHIN_30D' ELSE 'NO_FAILURE_WITHIN_30D' END
        AS label_name,
    c.snapshot_count,
    ROUND(100.0 * c.snapshot_count / NULLIF(t.total_snapshot, 0), 4)
        AS class_percentage,
    ROUND(t.negative_snapshot::numeric / NULLIF(t.positive_snapshot, 0), 2)
        AS negative_to_positive_ratio,
    CASE
        WHEN 100.0 * t.positive_snapshot / NULLIF(t.total_snapshot, 0) < 2
            THEN 'SEVERE_RARE_EVENT_LT_2PCT'
        WHEN 100.0 * t.positive_snapshot / NULLIF(t.total_snapshot, 0) < 10
            THEN 'IMBALANCED_LT_10PCT'
        ELSE 'MODERATE_OR_BALANCED'
    END AS imbalance_status
FROM class_count c
CROSS JOIN total t;

CREATE OR REPLACE VIEW analytics.eda_snapshot_master_coverage AS
WITH eligible AS (
    SELECT * FROM analytics.item_observation_30d WHERE is_training_eligible
), location_category AS (
    SELECT last_place_clean AS category_value, COUNT(*)::bigint AS snapshot_count
    FROM eligible WHERE last_place_clean IS NOT NULL GROUP BY last_place_clean
), client_category AS (
    SELECT installed_client_clean AS category_value, COUNT(*)::bigint AS snapshot_count
    FROM eligible WHERE installed_client_clean IS NOT NULL GROUP BY installed_client_clean
), summary AS (
    SELECT 'LOCATION'::text AS feature_name,
        COUNT(*)::bigint AS total_snapshot,
        COUNT(*) FILTER (WHERE is_location_feature_eligible)::bigint AS matched_snapshot,
        COUNT(*) FILTER (WHERE NOT is_location_feature_eligible)::bigint AS unmatched_snapshot,
        COUNT(DISTINCT last_place_clean) FILTER (WHERE last_place_clean IS NOT NULL)::bigint
            AS category_count,
        (SELECT COUNT(*) FROM location_category WHERE snapshot_count < 100)::bigint
            AS rare_category_count,
        (SELECT COALESCE(SUM(snapshot_count), 0) FROM location_category
         WHERE snapshot_count < 100)::bigint AS rare_snapshot_count
    FROM eligible
    UNION ALL
    SELECT 'CLIENT', COUNT(*)::bigint,
        COUNT(*) FILTER (WHERE installed_client_clean IS NOT NULL)::bigint,
        COUNT(*) FILTER (WHERE installed_client_clean IS NULL)::bigint,
        COUNT(DISTINCT installed_client_clean) FILTER (
            WHERE installed_client_clean IS NOT NULL
        )::bigint,
        (SELECT COUNT(*) FROM client_category WHERE snapshot_count < 100)::bigint,
        (SELECT COALESCE(SUM(snapshot_count), 0) FROM client_category
         WHERE snapshot_count < 100)::bigint
    FROM eligible
)
SELECT *,
    ROUND(100.0 * unmatched_snapshot / NULLIF(total_snapshot, 0), 4)
        AS unmatched_percentage,
    ROUND(100.0 * rare_snapshot_count / NULLIF(total_snapshot, 0), 4)
        AS rare_snapshot_percentage,
    CASE
        WHEN 100.0 * unmatched_snapshot / NULLIF(total_snapshot, 0) >= 5
            THEN 'HIGH_MISSING_REVIEW_BEFORE_USE'
        WHEN 100.0 * unmatched_snapshot / NULLIF(total_snapshot, 0) >= 1
            THEN 'USE_WITH_UNKNOWN_FLAG_AND_COMPARE_MODEL'
        ELSE 'COVERAGE_SAFE_KEEP_UNKNOWN_FALLBACK'
    END AS feature_decision
FROM summary;

CREATE OR REPLACE VIEW analytics.eda_feature_missingness AS
SELECT feature_name, missing_count,
    ROUND(100.0 * missing_count / NULLIF(total_count, 0), 4) missing_percentage,
    total_count, total_count - missing_count AS available_count,
    recommended_handling
FROM (
    SELECT 'item_model_code_clean'::text feature_name,
        COUNT(*) FILTER (WHERE item_model_code_clean IS NULL) missing_count,
        COUNT(*) total_count,
        'EXCLUDE_ROW_IF_MISSING_CORE_IDENTITY'::text recommended_handling
    FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'installed_client_clean',
        COUNT(*) FILTER (WHERE installed_client_clean IS NULL), COUNT(*),
        'UNKNOWN_CATEGORY_PLUS_MISSING_FLAG'
    FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'last_place_clean',
        COUNT(*) FILTER (WHERE last_place_clean IS NULL), COUNT(*),
        'UNKNOWN_CATEGORY_PLUS_FLAG_COMPARE_WITHOUT_LOCATION'
    FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'days_since_installation',
        COUNT(*) FILTER (WHERE days_since_installation IS NULL), COUNT(*),
        'EXCLUDE_IF_MISSING_CYCLE_START'
    FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'days_since_last_event',
        COUNT(*) FILTER (WHERE days_since_last_event IS NULL), COUNT(*),
        'MEDIAN_BY_MODEL_PLUS_MISSING_FLAG'
    FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'days_since_last_failure',
        COUNT(*) FILTER (WHERE days_since_last_failure IS NULL), COUNT(*),
        'STRUCTURAL_NO_PRIOR_FAILURE_USE_INDICATOR_AND_SENTINEL'
    FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'days_since_last_corrective',
        COUNT(*) FILTER (WHERE days_since_last_corrective IS NULL), COUNT(*),
        'STRUCTURAL_NO_PRIOR_CORRECTIVE_USE_INDICATOR_AND_SENTINEL'
    FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'days_at_last_location',
        COUNT(*) FILTER (WHERE days_at_last_location IS NULL), COUNT(*),
        'MISSING_FLAG_AND_COMPARE_MODEL_WITHOUT_LOCATION_AGE'
    FROM analytics.item_observation_30d WHERE is_training_eligible
) q;

-- =========================================================
-- E. FEATURE DAN TEMPORAL STABILITY
-- =========================================================
CREATE MATERIALIZED VIEW analytics.eda_feature_stability_monthly AS
WITH feature_long AS (
    SELECT DATE_TRUNC('month', o.observation_on)::date AS observation_month_start,
        f.feature_name, f.feature_value
    FROM analytics.item_observation_30d o
    CROSS JOIN LATERAL (VALUES
        ('days_since_installation'::text, o.days_since_installation::numeric),
        ('days_since_last_event', o.days_since_last_event::numeric),
        ('days_since_last_corrective', o.days_since_last_corrective::numeric),
        ('days_at_last_location', o.days_at_last_location::numeric),
        ('prior_events_90d', o.prior_events_90d::numeric),
        ('prior_corrective_90d', o.prior_corrective_90d::numeric),
        ('prior_preventive_90d', o.prior_preventive_90d::numeric),
        ('prior_failure_365d', o.prior_failure_365d::numeric)
    ) f(feature_name, feature_value)
    WHERE o.is_training_eligible
)
SELECT observation_month_start, feature_name,
    COUNT(*)::bigint AS observation_count,
    COUNT(*) FILTER (WHERE feature_value IS NULL)::bigint AS missing_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE feature_value IS NULL)
        / NULLIF(COUNT(*), 0), 4) AS missing_percentage,
    ROUND(AVG(feature_value), 4) AS mean_value,
    ROUND(STDDEV_POP(feature_value), 4) AS stddev_value,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY feature_value)::numeric, 4)
        AS median_value,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY feature_value)::numeric, 4)
        AS p90_value
FROM feature_long
GROUP BY observation_month_start, feature_name;

CREATE INDEX eda_feature_stability_monthly_idx
    ON analytics.eda_feature_stability_monthly (feature_name, observation_month_start);

-- =========================================================
-- D. LIFECYCLE, FAILURE, DAN REVIEW LABEL
-- =========================================================
-- Pemeriksaan EDA lanjutan: cadence snapshot, unit analisis, incomplete flow,
-- kandidat failure tanpa onset, dan ringkasan nilai ekstrem.
DROP MATERIALIZED VIEW IF EXISTS analytics.eda_snapshot_cadence_comparison;
DROP VIEW IF EXISTS analytics.eda_outlier_summary;
DROP VIEW IF EXISTS analytics.eda_failure_unit_comparison;
DROP VIEW IF EXISTS analytics.eda_incomplete_failure_summary;
DROP VIEW IF EXISTS analytics.eda_incomplete_failure_detail;
DROP VIEW IF EXISTS analytics.failure_outcome_missing_onset_review;

CREATE MATERIALIZED VIEW analytics.eda_snapshot_cadence_comparison AS
WITH cadence AS (
    SELECT * FROM (VALUES (7), (30)) value(cadence_days)
), generated AS (
    SELECT
        cadence.cadence_days,
        c.installation_cycle_id,
        c.has_observed_failure,
        gs.observation_on,
        c.failure_onset_on IS NOT NULL
          AND c.failure_onset_on > gs.observation_on
          AND c.failure_onset_on <= gs.observation_on + INTERVAL '30 days'
            AS target_failure_30d,
        (c.failure_onset_on IS NOT NULL
          AND c.failure_onset_on > gs.observation_on
          AND c.failure_onset_on <= gs.observation_on + INTERVAL '30 days')
        OR (
            c.is_negative_cycle_eligible
            AND gs.observation_on + INTERVAL '30 days'
                <= LEAST(c.cycle_end_on, c.dataset_max_event_on)
        )
            AS is_target_observable
    FROM analytics.item_installation_cycle c
    CROSS JOIN cadence
    CROSS JOIN LATERAL generate_series(
        c.installed_on,
        c.cycle_end_on - INTERVAL '1 microsecond',
        make_interval(days => cadence.cadence_days)
    ) gs(observation_on)
    WHERE c.is_initial_model_cohort
      AND c.installed_on < c.cycle_end_on
), summary AS (
    SELECT
        cadence_days,
        COUNT(*) AS all_snapshots,
        COUNT(*) FILTER (WHERE is_target_observable) AS eligible_snapshots,
        COUNT(*) FILTER (WHERE NOT is_target_observable) AS incomplete_followup_snapshots,
        COUNT(*) FILTER (WHERE is_target_observable AND target_failure_30d)
            AS positive_snapshots,
        COUNT(DISTINCT installation_cycle_id)
            FILTER (WHERE has_observed_failure) AS failure_cycles,
        COUNT(DISTINCT installation_cycle_id)
            FILTER (WHERE target_failure_30d) AS captured_failure_cycles
    FROM generated
    GROUP BY cadence_days
)
SELECT
    cadence_days,
    all_snapshots,
    eligible_snapshots,
    incomplete_followup_snapshots,
    positive_snapshots,
    ROUND(100.0 * positive_snapshots / NULLIF(eligible_snapshots, 0), 4)
        AS positive_percentage,
    failure_cycles,
    captured_failure_cycles,
    failure_cycles - captured_failure_cycles AS uncaptured_failure_cycles,
    ROUND(positive_snapshots::numeric / NULLIF(captured_failure_cycles, 0), 2)
        AS average_positive_snapshots_per_failure
FROM summary;

CREATE UNIQUE INDEX eda_snapshot_cadence_comparison_idx
    ON analytics.eda_snapshot_cadence_comparison (cadence_days);

CREATE OR REPLACE VIEW analytics.eda_failure_unit_comparison AS
SELECT
    'SNAPSHOT_30D'::text AS analysis_unit,
    COUNT(*)::bigint AS population_count,
    COUNT(*) FILTER (WHERE target_failure_30d)::bigint AS positive_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE target_failure_30d)
        / NULLIF(COUNT(*), 0), 4) AS positive_percentage,
    'Kondisi PART pada satu tanggal; satu PART dapat muncul berkali-kali'::text
        AS explanation
FROM analytics.item_observation_30d
WHERE is_training_eligible
UNION ALL
SELECT
    'INSTALLATION_CYCLE',
    COUNT(*)::bigint,
    COUNT(*) FILTER (WHERE has_observed_failure)::bigint,
    ROUND(100.0 * COUNT(*) FILTER (WHERE has_observed_failure)
        / NULLIF(COUNT(*), 0), 4),
    'Satu periode sejak PART dipasang sampai failure, reinstall, atau akhir data'
FROM analytics.item_installation_cycle
WHERE is_initial_model_cohort
UNION ALL
SELECT
    'UNIQUE_PART',
    COUNT(DISTINCT item_identifier_clean)::bigint,
    COUNT(DISTINCT item_identifier_clean)
        FILTER (WHERE has_observed_failure)::bigint,
    ROUND(100.0 * COUNT(DISTINCT item_identifier_clean)
        FILTER (WHERE has_observed_failure)
        / NULLIF(COUNT(DISTINCT item_identifier_clean), 0), 4),
    'Satu PART hanya dihitung sekali walaupun mempunyai banyak cycle dan snapshot'
FROM analytics.item_installation_cycle
WHERE is_initial_model_cohort;

CREATE OR REPLACE VIEW analytics.eda_incomplete_failure_detail AS
WITH boundary AS (
    SELECT MAX(created_on) AS dataset_cutoff_on
    FROM analytics.item_journey_operational_timeline
)
SELECT
    f.*,
    b.dataset_cutoff_on,
    EXTRACT(EPOCH FROM (b.dataset_cutoff_on - f.failure_onset_on)) / 86400.0
        AS days_from_failure_to_cutoff,
    CASE
        WHEN f.failure_onset_on > b.dataset_cutoff_on - INTERVAL '30 days'
            THEN 'LIKELY_ONGOING_0_30D'
        WHEN f.failure_onset_on > b.dataset_cutoff_on - INTERVAL '180 days'
            THEN 'REVIEW_31_180D'
        ELSE 'LIKELY_HISTORY_GAP_GT_180D'
    END AS followup_review_group
FROM analytics.failure_event_flow f
CROSS JOIN boundary b
WHERE f.flow_confirmation_status = 'OPEN_OR_INCOMPLETE_FLOW';

CREATE OR REPLACE VIEW analytics.eda_incomplete_failure_summary AS
SELECT
    followup_review_group,
    COUNT(*) AS failure_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count,
    MIN(failure_onset_on)::date AS earliest_failure_date,
    MAX(failure_onset_on)::date AS latest_failure_date
FROM analytics.eda_incomplete_failure_detail
GROUP BY followup_review_group;

CREATE OR REPLACE VIEW analytics.failure_outcome_missing_onset_review AS
SELECT DISTINCT ON (c.installation_cycle_id)
    c.installation_cycle_id,
    c.item_identifier_clean,
    c.item_model_code_clean,
    c.installed_on,
    c.installed_place_clean,
    o.journey_id AS outcome_journey_id,
    o.created_on AS outcome_on,
    o.status_clean AS outcome_status,
    o.place_canonical_clean AS outcome_place_clean,
    'FAILURE_WITH_MISSING_ONSET_REVIEW'::text AS suggested_label,
    FALSE AS is_primary_model_label
FROM analytics.item_installation_cycle c
JOIN analytics.item_journey_operational_timeline o
  ON o.item_identifier_clean = c.item_identifier_clean
 AND o.created_on > c.installed_on
 AND o.created_on <= c.cycle_end_on
WHERE NOT c.has_observed_failure
  AND o.event_semantic = 'FAILURE_OUTCOME'
ORDER BY c.installation_cycle_id, o.created_on, o.journey_id;

-- =========================================================
-- B. DATA QUALITY DAN REVIEW
-- =========================================================
CREATE OR REPLACE VIEW analytics.eda_outlier_summary AS
SELECT 'OPERATIONAL_GAP_GT_10Y'::text AS check_name,
    COUNT(*)::bigint AS affected_count,
    'Jarak dari event operasional sebelumnya lebih dari 10 tahun'::text AS explanation
FROM analytics.item_journey_operational_timeline
WHERE days_since_previous_operational_event > 3652.5
UNION ALL
SELECT 'ZERO_OR_NEGATIVE_DURATION_CYCLE', COUNT(*)::bigint,
    'Cycle tidak mempunyai durasi waktu positif'
FROM analytics.item_installation_cycle
WHERE NOT is_cycle_time_valid
UNION ALL
SELECT 'FAILURE_NOT_PRECEDED_BY_INSTALLED', COUNT(*)::bigint,
    'Status operasional tepat sebelum failure bukan INSTALLED atau tidak tersedia'
FROM analytics.failure_event_flow
WHERE previous_operational_status_clean IS DISTINCT FROM 'INSTALLED'
UNION ALL
SELECT 'ITEM_WITH_5_PLUS_FAILURES', COUNT(*)::bigint,
    'Jumlah PART yang memiliki sedikitnya lima failure'
FROM (
    SELECT item_identifier_clean
    FROM analytics.failure_event_clean
    GROUP BY item_identifier_clean
    HAVING COUNT(*) >= 5
) repeated
UNION ALL
SELECT 'JOURNEY_MODEL_INCONSISTENT', COUNT(*)::bigint,
    'Journey menggunakan model yang tidak konsisten dengan inventory'
FROM analytics.item_journey_clean
WHERE is_item_model_consistent IS NOT TRUE
UNION ALL
SELECT 'INVALID_OR_FUTURE_JOURNEY_DATE', COUNT(*)::bigint,
    'Journey mempunyai tanggal invalid atau berada di masa depan'
FROM analytics.item_journey_clean
WHERE NOT is_valid_date OR is_future_date
UNION ALL
SELECT 'SNAPSHOT_WITHOUT_MASTER_LOCATION', COUNT(*)::bigint,
    'Snapshot training tidak mempunyai lokasi canonical dari master'
FROM analytics.item_observation_30d
WHERE is_training_eligible AND NOT is_location_feature_eligible
UNION ALL
SELECT 'REINSTALL_WITHOUT_RECORDED_FAILURE', COUNT(*)::bigint,
    'Cycle berakhir dengan reinstall tetapi tidak memiliki failure tercatat; tidak otomatis dijadikan label negatif'
FROM analytics.item_installation_cycle
WHERE cycle_end_reason = 'REINSTALL_WITHOUT_RECORDED_FAILURE'
UNION ALL
SELECT 'RIGHT_CENSORED_ACTIVITY_COVERAGE_UNCONFIRMED', COUNT(*)::bigint,
    'Cycle masih terbuka, tetapi PART sudah lama tidak terlihat sehingga kepastian label negatif perlu diuji secara ketat'
FROM analytics.item_installation_cycle
WHERE cycle_quality_status = 'RIGHT_CENSORED_ACTIVITY_COVERAGE_UNCONFIRMED';


-- =========================================================
-- B. DATA QUALITY DAN REVIEW JOURNEY
-- =========================================================
-- EDA journal lengkap: kualitas, univariat, hubungan item-lokasi/waktu,
-- lifecycle pada lokasi yang sama, dan lonjakan aktivitas.
DROP VIEW IF EXISTS analytics.eda_location_lifecycle_summary;
DROP VIEW IF EXISTS analytics.eda_location_lifecycle_detail;
DROP VIEW IF EXISTS analytics.eda_daily_activity_anomaly;
DROP VIEW IF EXISTS analytics.eda_item_location_installation_summary;
DROP VIEW IF EXISTS analytics.eda_activity_calendar_summary;
DROP VIEW IF EXISTS analytics.eda_location_activity_summary;
DROP VIEW IF EXISTS analytics.eda_item_activity_summary;
DROP VIEW IF EXISTS analytics.eda_fuzzy_mapping_review;
DROP VIEW IF EXISTS analytics.eda_cleaning_review_detail;
DROP VIEW IF EXISTS analytics.eda_journey_quality_summary;

CREATE OR REPLACE VIEW analytics.eda_journey_quality_summary AS
WITH exact_duplicate_group AS (
    SELECT COUNT(*) AS row_count
    FROM analytics.item_journey_clean
    GROUP BY item_identifier_clean, created_on, item_category_clean,
        item_type_clean, item_model_code_clean, client_clean,
        ref_doc_code_clean, wo_type_clean, wo_code_clean, place_clean,
        activity_clean, status_clean, done_by_clean, remark
    HAVING COUNT(*) > 1
), exact_duplicate AS (
    SELECT COUNT(*) AS duplicate_groups,
        COALESCE(SUM(row_count - 1), 0)::bigint AS extra_rows
    FROM exact_duplicate_group
), source_type AS (
    SELECT COUNT(*) FILTER (
        WHERE data_type NOT IN (
            'timestamp without time zone', 'timestamp with time zone', 'date'
        )
    )::bigint AS invalid_type_count
    FROM information_schema.columns
    WHERE table_schema = 'journal'
      AND table_name = 't_item_journey'
      AND column_name = 'created_on'
)
SELECT * FROM (
    SELECT 1 AS check_order, 'MISSING_ITEM_IDENTIFIER'::text AS check_name,
        COUNT(*) FILTER (WHERE is_missing_item_identifier)::bigint AS affected_count,
        'Identifier item kosong'::text AS explanation
    FROM analytics.item_journey_clean
    UNION ALL SELECT 2, 'MISSING_ITEM_MODEL',
        COUNT(*) FILTER (WHERE item_model_code_clean IS NULL)::bigint,
        'Kode model item kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 3, 'MISSING_ITEM_TYPE',
        COUNT(*) FILTER (WHERE item_type_clean IS NULL)::bigint,
        'Tipe item kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 4, 'MISSING_ITEM_CATEGORY',
        COUNT(*) FILTER (WHERE item_category_clean IS NULL)::bigint,
        'Kategori PART atau TERMINAL kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 5, 'MISSING_CLIENT',
        COUNT(*) FILTER (WHERE client_clean IS NULL)::bigint,
        'Klien kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 6, 'MISSING_LOCATION',
        COUNT(*) FILTER (WHERE place_clean IS NULL)::bigint,
        'Lokasi mentah kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 7, 'LOCATION_NOT_IN_MASTER',
        COUNT(*) FILTER (
            WHERE place_clean IS NOT NULL AND place_canonical_clean IS NULL
        )::bigint,
        'Lokasi terisi tetapi tidak dapat dipetakan ke master'
        FROM analytics.item_journey_clean
    UNION ALL SELECT 8, 'CLIENT_NOT_IN_MASTER',
        COUNT(*) FILTER (
            WHERE client_clean IS NOT NULL AND client_canonical_clean IS NULL
        )::bigint,
        'Klien terisi tetapi tidak dapat dipetakan ke master'
        FROM analytics.item_journey_clean
    UNION ALL SELECT 9, 'MISSING_STATUS',
        COUNT(*) FILTER (WHERE status_clean IS NULL)::bigint,
        'Status journey kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 10, 'MISSING_DATE',
        COUNT(*) FILTER (WHERE created_on IS NULL)::bigint,
        'Tanggal journey kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 11, 'INVALID_OR_FUTURE_DATE',
        COUNT(*) FILTER (WHERE NOT is_valid_date OR is_future_date)::bigint,
        'Tanggal terlalu lama, invalid, atau melewati waktu ekstraksi'
        FROM analytics.item_journey_clean
    UNION ALL SELECT 12, 'DUPLICATE_JOURNEY_ID',
        COUNT(*) FILTER (WHERE is_duplicate_journey_id)::bigint,
        'journey_id tercatat lebih dari satu kali' FROM analytics.item_journey_clean
    UNION ALL SELECT 13, 'EXACT_LOG_DUPLICATE_EXTRA_ROWS', extra_rows,
        'Baris tambahan setelah seluruh isi bisnis log dibandingkan'
        FROM exact_duplicate
    UNION ALL SELECT 14, 'CREATED_ON_NOT_DATETIME', invalid_type_count,
        'Kolom created_on sumber bukan tipe date/timestamp' FROM source_type
) checks;

CREATE OR REPLACE VIEW analytics.eda_cleaning_review_detail AS
WITH flagged AS (
    SELECT j.*,
        COUNT(*) OVER (
            PARTITION BY item_identifier_clean, created_on, item_category_clean,
                item_type_clean, item_model_code_clean, client_clean,
                ref_doc_code_clean, wo_type_clean, wo_code_clean, place_clean,
                activity_clean, status_clean, done_by_clean, remark
        ) > 1 AS is_exact_duplicate_content
    FROM analytics.item_journey_clean j
)
SELECT journey_id, item_identifier_clean, item_model_code_clean,
    item_category_clean, status_clean, activity_clean, wo_type_clean,
    place_clean, place_canonical_clean, client_clean, created_on,
    ARRAY_REMOVE(ARRAY[
        CASE WHEN is_missing_item_identifier THEN 'MISSING_ITEM_IDENTIFIER' END,
        CASE WHEN item_model_code_clean IS NULL THEN 'MISSING_ITEM_MODEL' END,
        CASE WHEN created_on IS NULL THEN 'MISSING_DATE' END,
        CASE WHEN NOT is_valid_date OR is_future_date
            THEN 'INVALID_OR_FUTURE_DATE' END,
        CASE WHEN place_clean IS NOT NULL AND place_canonical_clean IS NULL
            THEN 'LOCATION_NOT_IN_MASTER' END,
        CASE WHEN client_clean IS NOT NULL AND client_canonical_clean IS NULL
            THEN 'CLIENT_NOT_IN_MASTER' END,
        CASE WHEN is_item_model_consistent IS NOT TRUE
            THEN 'JOURNEY_MODEL_INCONSISTENT' END,
        CASE WHEN is_duplicate_journey_id THEN 'DUPLICATE_JOURNEY_ID' END,
        CASE WHEN is_exact_duplicate_content
            THEN 'EXACT_DUPLICATE_CONTENT' END
    ], NULL)::text[] AS review_issues,
    CASE
        WHEN is_missing_item_identifier OR item_model_code_clean IS NULL
          OR created_on IS NULL OR NOT is_valid_date OR is_future_date
            THEN 'EXCLUDE_FROM_TIME_MODEL_AND_REVIEW_SOURCE'
        WHEN is_duplicate_journey_id
            THEN 'EXCLUDE_DUPLICATE_KEY_AND_REVIEW_SOURCE'
        WHEN is_item_model_consistent IS NOT TRUE
            THEN 'EXCLUDE_FROM_INITIAL_MODEL_COHORT'
        WHEN is_exact_duplicate_content
            THEN 'REVIEW_BEFORE_DEDUPLICATION'
        WHEN place_clean IS NOT NULL AND place_canonical_clean IS NULL
            THEN 'KEEP_EVENT_EXCLUDE_LOCATION_FEATURE'
        WHEN client_clean IS NOT NULL AND client_canonical_clean IS NULL
            THEN 'KEEP_EVENT_EXCLUDE_CLIENT_FEATURE'
        ELSE 'REVIEW'
    END AS suggested_action
FROM flagged
WHERE is_missing_item_identifier
   OR item_model_code_clean IS NULL
   OR created_on IS NULL
   OR NOT is_valid_date
   OR is_future_date
   OR (place_clean IS NOT NULL AND place_canonical_clean IS NULL)
   OR (client_clean IS NOT NULL AND client_canonical_clean IS NULL)
   OR is_item_model_consistent IS NOT TRUE
   OR is_duplicate_journey_id
   OR is_exact_duplicate_content;

CREATE OR REPLACE VIEW analytics.eda_fuzzy_mapping_review AS
SELECT 'LOCATION'::text AS mapping_type,
    place_clean AS source_value,
    place_canonical_clean AS canonical_value,
    COALESCE(place_fuzzy_candidate_name_clean, place_master_name_clean)
        AS best_candidate,
    place_mapping_method AS mapping_method,
    place_fuzzy_score AS similarity_score,
    place_fuzzy_margin AS score_margin,
    COUNT(*) AS event_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count
FROM analytics.item_journey_clean
WHERE place_clean IS NOT NULL AND place_mapping_method <> 'EXACT'
GROUP BY place_clean, place_canonical_clean,
    COALESCE(place_fuzzy_candidate_name_clean, place_master_name_clean),
    place_mapping_method, place_fuzzy_score, place_fuzzy_margin
UNION ALL
SELECT 'CLIENT', client_clean, client_canonical_clean,
    COALESCE(client_fuzzy_candidate_name_clean, client_master_name_clean),
    client_mapping_method, client_fuzzy_score, client_fuzzy_margin,
    COUNT(*), COUNT(DISTINCT item_identifier_clean)
FROM analytics.item_journey_clean
WHERE client_clean IS NOT NULL AND client_mapping_method <> 'EXACT'
GROUP BY client_clean, client_canonical_clean,
    COALESCE(client_fuzzy_candidate_name_clean, client_master_name_clean),
    client_mapping_method, client_fuzzy_score, client_fuzzy_margin;

-- =========================================================
-- C. DESCRIPTIVE EDA DAN TREN
-- =========================================================
CREATE OR REPLACE VIEW analytics.eda_item_activity_summary AS
SELECT item_category_clean, item_model_code_clean,
    COUNT(*) AS event_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count,
    COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
    COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
    COUNT(*) FILTER (WHERE event_semantic = 'FAILURE_ONSET') AS failure_count,
    MIN(created_on)::date AS first_activity_date,
    MAX(created_on)::date AS last_activity_date
FROM analytics.item_journey_operational_timeline
WHERE item_model_code_clean IS NOT NULL
GROUP BY item_category_clean, item_model_code_clean;

CREATE OR REPLACE VIEW analytics.eda_location_activity_summary AS
SELECT place_canonical_clean,
    COUNT(*) AS event_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count,
    COUNT(DISTINCT item_model_code_clean) AS model_count,
    COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
    COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
    COUNT(*) FILTER (WHERE event_semantic = 'FAILURE_ONSET') AS failure_count,
    MIN(created_on)::date AS first_activity_date,
    MAX(created_on)::date AS last_activity_date
FROM analytics.item_journey_operational_timeline
WHERE place_canonical_clean IS NOT NULL
GROUP BY place_canonical_clean;

CREATE OR REPLACE VIEW analytics.eda_activity_calendar_summary AS
SELECT created_on::date AS activity_date,
    DATE_TRUNC('month', created_on)::date AS activity_month,
    EXTRACT(ISODOW FROM created_on)::integer AS iso_day_of_week,
    EXTRACT(ISODOW FROM created_on)::integer IN (6, 7) AS is_weekend,
    COUNT(*) AS event_count,
    COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
    COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
    COUNT(*) FILTER (WHERE event_semantic = 'FAILURE_ONSET') AS failure_count
FROM analytics.item_journey_operational_timeline
GROUP BY created_on::date, DATE_TRUNC('month', created_on)::date,
    EXTRACT(ISODOW FROM created_on)::integer;

CREATE OR REPLACE VIEW analytics.eda_item_location_installation_summary AS
SELECT item_model_code_clean, place_canonical_clean,
    COUNT(*) AS installation_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count,
    MIN(created_on)::date AS first_installed_date,
    MAX(created_on)::date AS last_installed_date
FROM analytics.item_journey_operational_timeline
WHERE item_category_clean = 'PART'
  AND status_clean = 'INSTALLED'
  AND item_model_code_clean IS NOT NULL
  AND place_canonical_clean IS NOT NULL
GROUP BY item_model_code_clean, place_canonical_clean;

-- =========================================================
-- D. LIFECYCLE DAN FAILURE
-- =========================================================
CREATE OR REPLACE VIEW analytics.eda_location_lifecycle_detail AS
WITH installed AS (
    SELECT o.journey_id AS installation_journey_id,
        o.item_identifier_clean, o.item_model_code_clean,
        o.created_on AS installed_on,
        o.place_canonical_clean AS installed_place_clean,
        LEAD(o.created_on) OVER (
            PARTITION BY o.item_identifier_clean
            ORDER BY o.created_on, o.journey_id
        ) AS next_installed_on
    FROM analytics.item_journey_operational_timeline o
    WHERE o.status_clean = 'INSTALLED'
      AND o.item_category_clean = 'PART'
)
SELECT i.*,
    d.journey_id AS dismantle_journey_id,
    d.created_on AS dismantled_on,
    d.place_canonical_clean AS dismantled_place_clean,
    EXTRACT(EPOCH FROM (d.created_on - i.installed_on)) / 86400.0
        AS days_installed_to_dismantle,
    d.journey_id IS NOT NULL AS has_next_dismantle,
    i.installed_place_clean IS NOT NULL
      AND d.place_canonical_clean = i.installed_place_clean
        AS is_same_location,
    i.installed_place_clean IS NOT NULL
      AND d.place_canonical_clean IS NOT NULL
      AND d.place_canonical_clean <> i.installed_place_clean
        AS is_location_mismatch
FROM installed i
LEFT JOIN LATERAL (
    SELECT o.journey_id, o.created_on, o.place_canonical_clean
    FROM analytics.item_journey_operational_timeline o
    WHERE o.item_identifier_clean = i.item_identifier_clean
      AND o.status_clean = 'DISMANTLED'
      AND (
          o.created_on > i.installed_on
          OR (
              o.created_on = i.installed_on
              AND o.journey_id > i.installation_journey_id
          )
      )
      AND (i.next_installed_on IS NULL OR o.created_on < i.next_installed_on)
    ORDER BY o.created_on, o.journey_id
    LIMIT 1
) d ON TRUE;

CREATE OR REPLACE VIEW analytics.eda_location_lifecycle_summary AS
SELECT installed_place_clean,
    COUNT(*) AS installation_count,
    COUNT(*) FILTER (WHERE is_same_location) AS matched_lifecycle_count,
    ROUND(AVG(days_installed_to_dismantle)
        FILTER (WHERE is_same_location)::numeric, 2) AS average_days,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY days_installed_to_dismantle
    ) FILTER (WHERE is_same_location)::numeric, 2) AS median_days,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (
        ORDER BY days_installed_to_dismantle
    ) FILTER (WHERE is_same_location)::numeric, 2) AS p90_days
FROM analytics.eda_location_lifecycle_detail
GROUP BY installed_place_clean;

CREATE OR REPLACE VIEW analytics.eda_daily_activity_anomaly AS
WITH daily AS (
    SELECT created_on::date AS activity_date,
        COUNT(*) AS event_count,
        COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
        COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
        COUNT(*) FILTER (WHERE is_admin_recon_context) AS admin_recon_count,
        COUNT(*) FILTER (
            WHERE event_semantic = 'BULK_WAREHOUSE_RECEPTION'
        ) AS bulk_warehouse_reception_count
    FROM analytics.item_journey_semantic
    WHERE is_valid_operational_date
    GROUP BY created_on::date
), boundary AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY event_count) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY event_count) AS q3
    FROM daily
)
SELECT d.*,
    b.q3 + 3 * (b.q3 - b.q1) AS extreme_event_limit,
    d.event_count > b.q3 + 3 * (b.q3 - b.q1) AS is_extreme_activity_day
FROM daily d
CROSS JOIN boundary b;


-- =========================================================
-- F. HIERARKI PART-TERMINAL DAN ANALISIS BIVARIAT
-- =========================================================
-- eda_part_terminal_cycle_link dan eda_item_observation_30d_hierarchy pindah
-- ke sql/12b_item_terminal_hierarchy.sql (dijalankan sebelum file ini) karena
-- keduanya adalah sumber fitur produksi untuk 14_feature_engineering.sql, bukan
-- sekadar tabel eksplorasi. Bagian di bawah ini murni EDA: ringkasan struktur
-- relasi dan analisis bivariat terhadap target, dibangun di atas hierarchy
-- tersebut.
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
DROP VIEW IF EXISTS analytics.eda_bivariate_association_summary;
DROP VIEW IF EXISTS analytics.eda_bivariate_terminal_model_target;
DROP VIEW IF EXISTS analytics.eda_bivariate_terminal_type_target;
DROP VIEW IF EXISTS analytics.eda_part_terminal_structure_summary;

CREATE VIEW analytics.eda_part_terminal_structure_summary AS
WITH cycle_summary AS (
    SELECT COUNT(*)::numeric AS cycle_count,
        COUNT(*) FILTER (WHERE is_parent_link_valid)::numeric AS valid_cycle_count,
        COUNT(*) FILTER (
            WHERE is_parent_link_recorded_after_installation
        )::numeric AS recorded_after_cycle_count,
        COUNT(DISTINCT item_identifier_clean) FILTER (
            WHERE is_parent_link_valid
        )::numeric AS linked_part_count,
        COUNT(DISTINCT terminal_pairing_code) FILTER (
            WHERE is_parent_link_valid
        )::numeric AS linked_terminal_count
    FROM analytics.eda_part_terminal_cycle_link
), observation_summary AS (
    SELECT COUNT(*)::numeric AS observation_count,
        COUNT(*) FILTER (WHERE is_parent_link_valid)::numeric
            AS valid_observation_count
    FROM analytics.eda_item_observation_30d_hierarchy
    WHERE is_training_eligible
)
SELECT 'installation_cycles'::text AS metric, cycle_count AS value,
    'Seluruh installation cycle PART'::text AS interpretation
FROM cycle_summary
UNION ALL SELECT 'valid_parent_terminal_cycles', valid_cycle_count,
    'Cycle dengan parent yang valid di master dan inventory TERMINAL'
FROM cycle_summary
UNION ALL SELECT 'parent_link_recorded_after_installation_cycles',
    recorded_after_cycle_count,
    'Relasi historis yang dicatat setelah waktu installation; audit backfill'
FROM cycle_summary
UNION ALL SELECT 'linked_unique_parts', linked_part_count,
    'PART unik yang mempunyai parent TERMINAL valid pada sedikitnya satu cycle'
FROM cycle_summary
UNION ALL SELECT 'linked_unique_terminals', linked_terminal_count,
    'TERMINAL fisik unik yang menjadi parent pada installation cycle'
FROM cycle_summary
UNION ALL SELECT 'training_observations', observation_count,
    'Seluruh snapshot yang layak training'
FROM observation_summary
UNION ALL SELECT 'valid_parent_terminal_training_observations',
    valid_observation_count,
    'Snapshot training dengan konteks parent TERMINAL valid'
FROM observation_summary;

CREATE VIEW analytics.eda_bivariate_terminal_type_target AS
WITH eligible AS (
    SELECT target_failure_30d,
        CASE WHEN is_parent_link_valid THEN terminal_type ELSE 'UNMAPPED' END
            AS feature_value,
        item_identifier_clean,
        terminal_pairing_code
    FROM analytics.eda_item_observation_30d_hierarchy
    WHERE is_training_eligible
), overall AS (
    SELECT COUNT(*)::numeric AS total_n,
        COUNT(*) FILTER (WHERE target_failure_30d)::numeric AS total_positive
    FROM eligible
), grouped AS (
    SELECT feature_value,
        COUNT(*)::numeric AS snapshot_count,
        COUNT(DISTINCT item_identifier_clean)::numeric AS part_count,
        COUNT(DISTINCT terminal_pairing_code)::numeric AS terminal_count,
        COUNT(*) FILTER (WHERE target_failure_30d)::numeric AS positive_count
    FROM eligible
    GROUP BY feature_value
), scored AS (
    SELECT g.*, positive_count / NULLIF(snapshot_count, 0) AS p,
        o.total_positive / NULLIF(o.total_n, 0) AS overall_p
    FROM grouped g CROSS JOIN overall o
)
SELECT feature_value AS terminal_type,
    snapshot_count::bigint, part_count::bigint, terminal_count::bigint,
    positive_count::bigint,
    ROUND(100.0 * p, 4) AS positive_percentage,
    ROUND(p / NULLIF(overall_p, 0), 4) AS risk_ratio_to_overall,
    ROUND(100.0 * GREATEST(0,
        (p + 3.8416 / (2 * snapshot_count)
         - 1.96 * SQRT((p * (1-p) + 3.8416 / (4*snapshot_count))
                       / snapshot_count))
        / (1 + 3.8416 / snapshot_count)), 4) AS wilson_lower_95_pct,
    ROUND(100.0 * LEAST(1,
        (p + 3.8416 / (2 * snapshot_count)
         + 1.96 * SQRT((p * (1-p) + 3.8416 / (4*snapshot_count))
                       / snapshot_count))
        / (1 + 3.8416 / snapshot_count)), 4) AS wilson_upper_95_pct,
    terminal_count >= 20 AND positive_count >= 10 AS meets_minimum_support
FROM scored;

CREATE VIEW analytics.eda_bivariate_terminal_model_target AS
WITH eligible AS (
    SELECT target_failure_30d,
        CASE WHEN is_parent_link_valid THEN terminal_model_code END
            AS terminal_model_code,
        CASE WHEN is_parent_link_valid THEN terminal_type END AS terminal_type,
        item_identifier_clean, terminal_pairing_code
    FROM analytics.eda_item_observation_30d_hierarchy
    WHERE is_training_eligible
), overall AS (
    SELECT COUNT(*)::numeric AS total_n,
        COUNT(*) FILTER (WHERE target_failure_30d)::numeric AS total_positive
    FROM eligible
), grouped AS (
    SELECT terminal_model_code, terminal_type,
        COUNT(*)::numeric AS snapshot_count,
        COUNT(DISTINCT item_identifier_clean)::numeric AS part_count,
        COUNT(DISTINCT terminal_pairing_code)::numeric AS terminal_count,
        COUNT(*) FILTER (WHERE target_failure_30d)::numeric AS positive_count
    FROM eligible
    WHERE terminal_model_code IS NOT NULL
    GROUP BY terminal_model_code, terminal_type
)
SELECT g.terminal_model_code, g.terminal_type,
    snapshot_count::bigint, part_count::bigint, terminal_count::bigint,
    positive_count::bigint,
    ROUND(100.0 * positive_count / NULLIF(snapshot_count, 0), 4)
        AS positive_percentage,
    ROUND((positive_count / NULLIF(snapshot_count, 0))
        / NULLIF(o.total_positive / NULLIF(o.total_n, 0), 0), 4)
        AS risk_ratio_to_overall,
    terminal_count >= 20 AND positive_count >= 10 AS meets_minimum_support
FROM grouped g CROSS JOIN overall o;

CREATE VIEW analytics.eda_bivariate_association_summary AS
WITH terminal_target AS (
    SELECT terminal_type,
        COUNT(*) FILTER (WHERE target_failure_30d)::numeric AS positive_count,
        COUNT(*) FILTER (WHERE NOT target_failure_30d)::numeric AS negative_count
    FROM analytics.eda_item_observation_30d_hierarchy
    WHERE is_training_eligible AND is_parent_link_valid
    GROUP BY terminal_type
), target_total AS (
    SELECT SUM(positive_count)::numeric AS positive_total,
        SUM(negative_count)::numeric AS negative_total,
        SUM(positive_count + negative_count)::numeric AS total_n
    FROM terminal_target
), target_chi AS (
    SELECT SUM(
        (positive_count - (positive_count + negative_count)
            * positive_total / total_n)^2
          / NULLIF((positive_count + negative_count)
            * positive_total / total_n, 0)
        +
        (negative_count - (positive_count + negative_count)
            * negative_total / total_n)^2
          / NULLIF((positive_count + negative_count)
            * negative_total / total_n, 0)
    ) AS chi_square
    FROM terminal_target CROSS JOIN target_total
), part_terminal_cell AS (
    SELECT part_model_code, terminal_type, COUNT(*)::numeric AS cell_count
    FROM analytics.eda_part_terminal_cycle_link
    WHERE is_parent_link_valid
    GROUP BY part_model_code, terminal_type
), part_total AS (
    SELECT part_model_code, SUM(cell_count)::numeric AS row_count
    FROM part_terminal_cell GROUP BY part_model_code
), terminal_total AS (
    SELECT terminal_type, SUM(cell_count)::numeric AS column_count
    FROM part_terminal_cell GROUP BY terminal_type
), hierarchy_total AS (
    SELECT SUM(cell_count)::numeric AS total_n FROM part_terminal_cell
), hierarchy_chi AS (
    SELECT SUM((c.cell_count - p.row_count*t.column_count/h.total_n)^2
        / NULLIF(p.row_count*t.column_count/h.total_n, 0)) AS chi_square
    FROM part_terminal_cell c
    JOIN part_total p USING (part_model_code)
    JOIN terminal_total t USING (terminal_type)
    CROSS JOIN hierarchy_total h
)
SELECT 'TERMINAL_TYPE_VS_TARGET'::text AS association,
    tc.chi_square,
    SQRT(tc.chi_square / tt.total_n) AS cramers_v,
    tt.total_n::bigint AS observation_count,
    'Effect size bivariat; target memiliki dua kelas'::text AS interpretation
FROM target_chi tc CROSS JOIN target_total tt
UNION ALL
SELECT 'PART_MODEL_VS_TERMINAL_TYPE', hc.chi_square,
    SQRT(hc.chi_square / (
        ht.total_n * LEAST(
            (SELECT COUNT(DISTINCT part_model_code) - 1 FROM part_terminal_cell),
            (SELECT COUNT(DISTINCT terminal_type) - 1 FROM part_terminal_cell)
        )
    )), ht.total_n::bigint,
    'Confounding struktur: nilai tinggi menuntut adjustment multivariat'
FROM hierarchy_chi hc CROSS JOIN hierarchy_total ht;


-- =========================================================
-- G. REFRESH PROCEDURE
-- =========================================================
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
END; $refresh$;
