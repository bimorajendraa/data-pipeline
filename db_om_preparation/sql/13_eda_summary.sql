-- Ringkasan ringan untuk notebook dan pemeriksaan lewat SQL.
DROP MATERIALIZED VIEW IF EXISTS analytics.eda_feature_stability_monthly;

CREATE OR REPLACE VIEW analytics.eda_failure_readiness_summary AS
SELECT 'installation_cycles'::text metric, COUNT(*)::numeric value FROM analytics.item_installation_cycle
UNION ALL SELECT 'valid_model_cohort_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE is_initial_model_cohort
UNION ALL SELECT 'invalid_zero_duration_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE NOT is_cycle_time_valid
UNION ALL SELECT 'cycles_with_failure', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE has_observed_failure
UNION ALL SELECT 'right_censored_cycles', COUNT(*)::numeric FROM analytics.item_installation_cycle WHERE is_right_censored
UNION ALL SELECT 'all_observations', COUNT(*)::numeric FROM analytics.item_observation_30d
UNION ALL SELECT 'training_eligible_observations', COUNT(*)::numeric FROM analytics.item_observation_30d WHERE is_training_eligible
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
    REFRESH MATERIALIZED VIEW analytics.eda_feature_stability_monthly;
END; $refresh$;

SELECT * FROM analytics.eda_failure_readiness_summary ORDER BY metric;
SELECT * FROM analytics.eda_failure_rate_by_year ORDER BY observation_year;
SELECT * FROM analytics.eda_target_class_distribution ORDER BY label_value;
SELECT * FROM analytics.eda_snapshot_master_coverage ORDER BY feature_name;
