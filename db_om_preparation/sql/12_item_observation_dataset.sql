-- Dataset klasifikasi 30 hari; fitur hanya memakai event pada/before snapshot.
DROP VIEW IF EXISTS analytics.eda_failure_readiness_summary;
DROP VIEW IF EXISTS analytics.eda_failure_rate_by_year;
DROP VIEW IF EXISTS analytics.eda_feature_missingness;
DROP MATERIALIZED VIEW IF EXISTS analytics.item_observation_30d;

CREATE MATERIALIZED VIEW analytics.item_observation_30d AS
WITH snapshot AS (
    SELECT c.*, gs.observation_on,
        c.failure_onset_on IS NOT NULL
          AND c.failure_onset_on > gs.observation_on
          AND c.failure_onset_on <= gs.observation_on + INTERVAL '30 days' AS target_failure_30d,
        (c.failure_onset_on IS NOT NULL
          AND c.failure_onset_on > gs.observation_on
          AND c.failure_onset_on <= gs.observation_on + INTERVAL '30 days')
        OR gs.observation_on + INTERVAL '30 days' <= LEAST(c.cycle_end_on, c.dataset_max_event_on)
          AS is_target_observable
    FROM analytics.item_installation_cycle c
    CROSS JOIN LATERAL generate_series(c.installed_on, c.cycle_end_on - INTERVAL '1 microsecond', INTERVAL '30 days') gs(observation_on)
    WHERE c.is_initial_model_cohort AND c.installed_on < c.cycle_end_on
), features AS (
    SELECT s.*, h.*
    FROM snapshot s
    LEFT JOIN LATERAL (
        SELECT COUNT(*) AS total_prior_events,
            COUNT(*) FILTER (WHERE o.event_semantic = 'FAILURE_ONSET') AS prior_failure_count,
            COUNT(*) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE') AS prior_corrective_count,
            COUNT(*) FILTER (WHERE o.event_semantic = 'RELOCATION') AS prior_relocation_count,
            COUNT(*) FILTER (WHERE o.event_semantic = 'PREVENTIVE') AS prior_preventive_count,
            COUNT(*) FILTER (WHERE o.event_semantic = 'REPAIR_PROCESS') AS prior_repair_process_count,
            COUNT(DISTINCT o.place_clean) AS prior_distinct_places,
            MAX(o.created_on) AS last_event_on,
            MAX(o.created_on) FILTER (WHERE o.event_semantic = 'FAILURE_ONSET') AS last_failure_on,
            (ARRAY_AGG(o.status_clean ORDER BY o.created_on DESC, o.journey_id DESC))[1] AS last_status_clean,
            (ARRAY_AGG(o.place_clean ORDER BY o.created_on DESC, o.journey_id DESC)
                FILTER (WHERE o.place_clean IS NOT NULL))[1] AS last_place_clean
        FROM analytics.item_journey_operational_timeline o
        WHERE o.item_identifier_clean = s.item_identifier_clean AND o.created_on <= s.observation_on
    ) h ON TRUE
)
SELECT installation_cycle_id, item_identifier_clean, observation_on,
    observation_on::date AS observation_date, item_model_code_clean, item_type_clean,
    installed_client_clean, installed_place_clean, last_place_clean, installed_on,
    EXTRACT(EPOCH FROM (observation_on - installed_on)) / 86400.0 AS days_since_installation,
    COALESCE(total_prior_events, 0) AS total_prior_events,
    COALESCE(prior_failure_count, 0) AS prior_failure_count,
    COALESCE(prior_corrective_count, 0) AS prior_corrective_count,
    COALESCE(prior_relocation_count, 0) AS prior_relocation_count,
    COALESCE(prior_preventive_count, 0) AS prior_preventive_count,
    COALESCE(prior_repair_process_count, 0) AS prior_repair_process_count,
    COALESCE(prior_distinct_places, 0) AS prior_distinct_places,
    EXTRACT(EPOCH FROM (observation_on - last_event_on)) / 86400.0 AS days_since_last_event,
    EXTRACT(EPOCH FROM (observation_on - last_failure_on)) / 86400.0 AS days_since_last_failure,
    last_status_clean, failure_onset_on AS next_failure_on, target_failure_30d,
    is_target_observable, is_target_observable AS is_training_eligible,
    CASE WHEN target_failure_30d THEN 'POSITIVE_FAILURE_WITHIN_30D'
         WHEN is_target_observable THEN 'NEGATIVE_FULL_30D_FOLLOWUP'
         ELSE 'EXCLUDED_INCOMPLETE_30D_FOLLOWUP' END AS target_quality_status
FROM features;

CREATE UNIQUE INDEX item_observation_30d_key_idx ON analytics.item_observation_30d (installation_cycle_id, observation_on);
CREATE INDEX item_observation_30d_target_idx ON analytics.item_observation_30d (is_training_eligible, target_failure_30d, observation_on);
CREATE INDEX item_observation_30d_model_idx ON analytics.item_observation_30d (item_model_code_clean, observation_on);
