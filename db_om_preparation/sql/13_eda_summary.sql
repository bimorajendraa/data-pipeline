-- Ringkasan ringan untuk notebook dan pemeriksaan lewat SQL.
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

CREATE OR REPLACE VIEW analytics.eda_feature_missingness AS
SELECT feature_name, missing_count, ROUND(100.0 * missing_count / NULLIF(total_count, 0), 4) missing_percentage
FROM (
    SELECT 'item_model_code_clean'::text feature_name, COUNT(*) FILTER (WHERE item_model_code_clean IS NULL) missing_count, COUNT(*) total_count FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'last_place_clean', COUNT(*) FILTER (WHERE last_place_clean IS NULL), COUNT(*) FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'days_since_last_event', COUNT(*) FILTER (WHERE days_since_last_event IS NULL), COUNT(*) FROM analytics.item_observation_30d WHERE is_training_eligible
    UNION ALL SELECT 'days_since_last_failure', COUNT(*) FILTER (WHERE days_since_last_failure IS NULL), COUNT(*) FROM analytics.item_observation_30d WHERE is_training_eligible
) q;

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
END; $refresh$;

SELECT * FROM analytics.eda_failure_readiness_summary ORDER BY metric;
SELECT * FROM analytics.eda_failure_rate_by_year ORDER BY observation_year;
