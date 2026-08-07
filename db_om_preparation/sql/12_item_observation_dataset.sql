-- Dataset klasifikasi 30 hari; fitur hanya memakai event pada/before snapshot.
-- Drop layer modeling tahap 14 terlebih dahulu agar pipeline dapat dijalankan
-- ulang ketika view tersebut bergantung pada observation dataset.
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

DROP MATERIALIZED VIEW IF EXISTS analytics.eda_feature_stability_monthly;
DROP MATERIALIZED VIEW IF EXISTS analytics.eda_snapshot_cadence_comparison;
DROP VIEW IF EXISTS analytics.eda_target_class_distribution;
DROP VIEW IF EXISTS analytics.eda_snapshot_master_coverage;
DROP VIEW IF EXISTS analytics.eda_outlier_summary;
DROP VIEW IF EXISTS analytics.eda_failure_unit_comparison;
DROP VIEW IF EXISTS analytics.eda_failure_readiness_summary;
DROP VIEW IF EXISTS analytics.eda_failure_rate_by_year;
DROP VIEW IF EXISTS analytics.eda_feature_missingness;
DROP VIEW IF EXISTS analytics.item_observation_30d_audit;
DROP VIEW IF EXISTS analytics.item_observation_30d_labels;
DROP VIEW IF EXISTS analytics.item_observation_30d_features;
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
        OR (
            c.is_negative_cycle_eligible
            AND gs.observation_on + INTERVAL '30 days'
                <= LEAST(c.cycle_end_on, c.dataset_max_event_on)
        ) AS is_target_observable,
        (c.failure_onset_on IS NOT NULL
          AND c.failure_onset_on > gs.observation_on
          AND c.failure_onset_on <= gs.observation_on + INTERVAL '30 days')
        OR gs.observation_on + INTERVAL '30 days'
            <= LEAST(c.cycle_end_on, c.dataset_max_event_on)
          AS is_legacy_target_observable,
        (c.failure_onset_on IS NOT NULL
          AND c.failure_onset_on > gs.observation_on
          AND c.failure_onset_on <= gs.observation_on + INTERVAL '30 days')
        OR (
            c.is_strict_negative_cycle_eligible
            AND gs.observation_on + INTERVAL '30 days'
                <= LEAST(c.item_observation_end_on, c.dataset_max_event_on)
        ) AS is_strict_target_observable
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
            COUNT(*) FILTER (WHERE o.created_on > s.observation_on - INTERVAL '30 days')
                AS prior_events_30d,
            COUNT(*) FILTER (WHERE o.created_on > s.observation_on - INTERVAL '90 days')
                AS prior_events_90d,
            COUNT(*) FILTER (WHERE o.created_on > s.observation_on - INTERVAL '180 days')
                AS prior_events_180d,
            COUNT(*) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE'
                AND o.created_on > s.observation_on - INTERVAL '30 days')
                AS prior_corrective_30d,
            COUNT(*) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE'
                AND o.created_on > s.observation_on - INTERVAL '90 days')
                AS prior_corrective_90d,
            COUNT(*) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE'
                AND o.created_on > s.observation_on - INTERVAL '180 days')
                AS prior_corrective_180d,
            COUNT(*) FILTER (WHERE o.event_semantic = 'PREVENTIVE'
                AND o.created_on > s.observation_on - INTERVAL '30 days')
                AS prior_preventive_30d,
            COUNT(*) FILTER (WHERE o.event_semantic = 'PREVENTIVE'
                AND o.created_on > s.observation_on - INTERVAL '90 days')
                AS prior_preventive_90d,
            COUNT(*) FILTER (WHERE o.event_semantic = 'PREVENTIVE'
                AND o.created_on > s.observation_on - INTERVAL '180 days')
                AS prior_preventive_180d,
            COUNT(*) FILTER (WHERE o.event_semantic = 'FAILURE_ONSET'
                AND o.created_on > s.observation_on - INTERVAL '365 days')
                AS prior_failure_365d,
            COUNT(DISTINCT o.place_canonical_clean) AS prior_distinct_places,
            MAX(o.created_on) AS last_event_on,
            MAX(o.created_on) FILTER (WHERE o.event_semantic = 'FAILURE_ONSET') AS last_failure_on,
            MAX(o.created_on) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE')
                AS last_corrective_on,
            MAX(o.created_on) FILTER (
                WHERE o.place_canonical_clean IS NOT NULL
                  AND o.place_canonical_clean IS DISTINCT FROM
                      o.previous_operational_place_clean
            ) AS last_location_change_on,
            (ARRAY_AGG(o.status_clean ORDER BY o.created_on DESC, o.journey_id DESC))[1] AS last_status_clean,
            (ARRAY_AGG(o.place_canonical_clean
                ORDER BY o.created_on DESC, o.journey_id DESC))[1]
                AS last_place_clean
        FROM analytics.item_journey_operational_timeline o
        WHERE o.item_identifier_clean = s.item_identifier_clean AND o.created_on <= s.observation_on
    ) h ON TRUE
)
SELECT installation_cycle_id, item_identifier_clean, observation_on,
    observation_on::date AS observation_date,
    EXTRACT(YEAR FROM observation_on)::integer AS observation_year,
    EXTRACT(QUARTER FROM observation_on)::integer AS observation_quarter,
    EXTRACT(MONTH FROM observation_on)::integer AS observation_month,
    EXTRACT(ISODOW FROM observation_on)::integer AS observation_day_of_week,
    EXTRACT(ISODOW FROM observation_on)::integer IN (6, 7) AS is_weekend,
    item_model_code_clean, item_type_clean,
    installed_client_clean, installed_place_source_clean, installed_place_clean,
    is_installed_location_valid, last_place_clean,
    last_place_clean IS NOT NULL AS is_location_feature_eligible,
    installed_on,
    EXTRACT(EPOCH FROM (observation_on - installed_on)) / 86400.0 AS days_since_installation,
    COALESCE(total_prior_events, 0) AS total_prior_events,
    COALESCE(prior_failure_count, 0) AS prior_failure_count,
    COALESCE(prior_corrective_count, 0) AS prior_corrective_count,
    COALESCE(prior_relocation_count, 0) AS prior_relocation_count,
    COALESCE(prior_preventive_count, 0) AS prior_preventive_count,
    COALESCE(prior_repair_process_count, 0) AS prior_repair_process_count,
    COALESCE(prior_events_30d, 0) AS prior_events_30d,
    COALESCE(prior_events_90d, 0) AS prior_events_90d,
    COALESCE(prior_events_180d, 0) AS prior_events_180d,
    COALESCE(prior_corrective_30d, 0) AS prior_corrective_30d,
    COALESCE(prior_corrective_90d, 0) AS prior_corrective_90d,
    COALESCE(prior_corrective_180d, 0) AS prior_corrective_180d,
    COALESCE(prior_preventive_30d, 0) AS prior_preventive_30d,
    COALESCE(prior_preventive_90d, 0) AS prior_preventive_90d,
    COALESCE(prior_preventive_180d, 0) AS prior_preventive_180d,
    COALESCE(prior_failure_365d, 0) AS prior_failure_365d,
    COALESCE(prior_failure_count, 0) > 0 AS has_prior_failure,
    COALESCE(prior_corrective_count, 0) > 0 AS has_prior_corrective,
    COALESCE(prior_distinct_places, 0) AS prior_distinct_places,
    EXTRACT(EPOCH FROM (observation_on - last_event_on)) / 86400.0 AS days_since_last_event,
    EXTRACT(EPOCH FROM (observation_on - last_failure_on)) / 86400.0 AS days_since_last_failure,
    EXTRACT(EPOCH FROM (observation_on - last_corrective_on)) / 86400.0
        AS days_since_last_corrective,
    EXTRACT(EPOCH FROM (observation_on - last_location_change_on)) / 86400.0
        AS days_at_last_location,
    last_status_clean, failure_onset_on AS next_failure_on,
    failure_confirmed_on AS next_failure_confirmed_on,
    failure_label_basis AS next_failure_label_basis,
    failure_place_clean AS next_failure_place_clean,
    target_failure_30d,
    cycle_end_reason, cycle_quality_status, observation_end_reason,
    item_last_seen_on, item_observation_end_on,
    is_activity_coverage_confirmed, is_cycle_label_reliable,
    is_negative_cycle_eligible, is_strict_negative_cycle_eligible,
    is_legacy_target_observable, is_target_observable,
    is_strict_target_observable,
    is_target_observable AS is_training_eligible,
    is_strict_target_observable AS is_strict_training_eligible,
    CASE WHEN target_failure_30d THEN 'POSITIVE_FAILURE_WITHIN_30D'
         WHEN cycle_end_reason = 'REINSTALL_WITHOUT_RECORDED_FAILURE'
            THEN 'EXCLUDED_UNKNOWN_REINSTALL_WITHOUT_FAILURE'
         WHEN is_target_observable THEN 'NEGATIVE_FULL_30D_FOLLOWUP'
         ELSE 'EXCLUDED_INCOMPLETE_30D_FOLLOWUP' END AS target_quality_status
FROM features;

CREATE UNIQUE INDEX item_observation_30d_key_idx ON analytics.item_observation_30d (installation_cycle_id, observation_on);
CREATE INDEX item_observation_30d_target_idx ON analytics.item_observation_30d (is_training_eligible, target_failure_30d, observation_on);
CREATE INDEX item_observation_30d_model_idx ON analytics.item_observation_30d (item_model_code_clean, observation_on);

-- Pemisahan fisik ini mencegah kolom jawaban masa depan ikut terambil ketika
-- modeling. View audit lama tetap tersedia untuk EDA dan penelusuran label.
CREATE OR REPLACE VIEW analytics.item_observation_30d_features AS
SELECT installation_cycle_id, item_identifier_clean, observation_on,
    observation_date, observation_year, observation_quarter, observation_month,
    observation_day_of_week, is_weekend, item_model_code_clean, item_type_clean,
    installed_client_clean, installed_place_clean, last_place_clean,
    is_location_feature_eligible, installed_on, days_since_installation,
    total_prior_events, prior_failure_count, prior_corrective_count,
    prior_relocation_count, prior_preventive_count, prior_repair_process_count,
    prior_events_30d, prior_events_90d, prior_events_180d,
    prior_corrective_30d, prior_corrective_90d, prior_corrective_180d,
    prior_preventive_30d, prior_preventive_90d, prior_preventive_180d,
    prior_failure_365d, has_prior_failure, has_prior_corrective,
    prior_distinct_places, days_since_last_event, days_since_last_failure,
    days_since_last_corrective, days_at_last_location, last_status_clean
FROM analytics.item_observation_30d;

CREATE OR REPLACE VIEW analytics.item_observation_30d_labels AS
SELECT installation_cycle_id, observation_on, target_failure_30d,
    is_training_eligible, is_strict_training_eligible,
    is_legacy_target_observable, is_target_observable,
    is_strict_target_observable, target_quality_status,
    cycle_end_reason, cycle_quality_status, observation_end_reason,
    is_activity_coverage_confirmed, is_cycle_label_reliable,
    is_negative_cycle_eligible, is_strict_negative_cycle_eligible
FROM analytics.item_observation_30d;

CREATE OR REPLACE VIEW analytics.item_observation_30d_audit AS
SELECT * FROM analytics.item_observation_30d;
