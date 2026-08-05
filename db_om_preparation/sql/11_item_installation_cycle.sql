-- Siklus PART dimulai hanya oleh INSTALLED dengan waktu tepercaya.
-- RECON sudah dikeluarkan dari operational timeline dan tidak membuka siklus.
DROP VIEW IF EXISTS analytics.eda_failure_readiness_summary;
DROP VIEW IF EXISTS analytics.eda_failure_rate_by_year;
DROP VIEW IF EXISTS analytics.eda_feature_missingness;
DROP MATERIALIZED VIEW IF EXISTS analytics.item_observation_30d;
DROP MATERIALIZED VIEW IF EXISTS analytics.item_installation_cycle;

CREATE MATERIALIZED VIEW analytics.item_installation_cycle AS
WITH dataset_boundary AS (
    SELECT MAX(created_on) AS dataset_max_event_on
    FROM analytics.item_journey_operational_timeline
), installed_events AS (
    SELECT o.*,
        ROW_NUMBER() OVER (PARTITION BY o.item_identifier_clean ORDER BY o.created_on, o.journey_id) AS installation_sequence,
        LEAD(o.created_on) OVER (PARTITION BY o.item_identifier_clean ORDER BY o.created_on, o.journey_id) AS next_installed_on
    FROM analytics.item_journey_operational_timeline o
    WHERE o.status_clean = 'INSTALLED'
      AND o.item_category_clean = 'PART'
      AND o.item_identifier_clean IS NOT NULL
), cycle_events AS (
    SELECT i.*, f.journey_id AS failure_journey_id, f.failure_onset_on,
        f.model_cohort_status AS failure_model_cohort_status, b.dataset_max_event_on
    FROM installed_events i
    CROSS JOIN dataset_boundary b
    LEFT JOIN LATERAL (
        SELECT f.journey_id, f.failure_onset_on, f.model_cohort_status
        FROM analytics.failure_event_clean f
        WHERE f.item_identifier_clean = i.item_identifier_clean
          AND f.failure_onset_on > i.created_on
          AND (i.next_installed_on IS NULL OR f.failure_onset_on < i.next_installed_on)
        ORDER BY f.failure_onset_on, f.journey_id LIMIT 1
    ) f ON TRUE
), validated AS (
    SELECT c.*,
        pi.identifier_clean IS NOT NULL OR hi.identifier_clean IS NOT NULL AS is_item_found,
        (pi.identifier_clean IS NOT NULL OR hi.identifier_clean IS NOT NULL)
        AND CASE WHEN pi.identifier_clean IS NULL THEN TRUE
                 WHEN c.item_model_code_clean IS NULL THEN pi.nonnull_model_count = 0
                 ELSE NOT pi.has_null_model AND pi.nonnull_model_count = 1
                      AND pi.only_model_code = c.item_model_code_clean END
        AND CASE WHEN hi.identifier_clean IS NULL THEN TRUE
                 WHEN c.item_model_code_clean IS NULL THEN hi.nonnull_model_count = 0
                 ELSE NOT hi.has_null_model AND hi.nonnull_model_count = 1
                      AND hi.only_model_code = c.item_model_code_clean END AS is_item_model_consistent
    FROM cycle_events c
    LEFT JOIN analytics.item_identifier_model_cache pi ON pi.lookup_type = 'PAIRING' AND pi.identifier_clean = c.item_pairing_code_clean
    LEFT JOIN analytics.item_identifier_model_cache hi ON hi.lookup_type = 'HOST' AND hi.identifier_clean = c.host_serial_code_clean
)
SELECT item_identifier_clean || ':' || installation_sequence::text AS installation_cycle_id,
    item_identifier_clean, installation_sequence, journey_id AS installed_journey_id,
    created_on AS installed_on, item_model_code_clean, item_type_clean,
    item_pairing_code_clean, host_serial_code_clean, client_clean AS installed_client_clean,
    place_clean AS installed_place_clean, next_installed_on, failure_journey_id,
    failure_onset_on, failure_model_cohort_status,
    COALESCE(failure_onset_on, next_installed_on, dataset_max_event_on) AS cycle_end_on,
    CASE WHEN failure_onset_on IS NOT NULL THEN 'FAILURE'
         WHEN next_installed_on IS NOT NULL THEN 'REINSTALL_WITHOUT_RECORDED_FAILURE'
         ELSE 'RIGHT_CENSORED_AT_DATA_END' END AS cycle_end_reason,
    failure_onset_on IS NOT NULL AS has_observed_failure,
    failure_onset_on IS NULL AND next_installed_on IS NULL AS is_right_censored,
    is_item_found, is_item_model_consistent,
    created_on < COALESCE(failure_onset_on, next_installed_on, dataset_max_event_on)
        AS is_cycle_time_valid,
    is_item_found AND is_item_model_consistent
        AND created_on < COALESCE(failure_onset_on, next_installed_on, dataset_max_event_on)
        AS is_initial_model_cohort,
    dataset_max_event_on,
    EXTRACT(EPOCH FROM (failure_onset_on - created_on)) / 86400.0 AS days_installed_to_failure
FROM validated;

CREATE UNIQUE INDEX item_installation_cycle_id_idx ON analytics.item_installation_cycle (installation_cycle_id);
CREATE INDEX item_installation_cycle_item_date_idx ON analytics.item_installation_cycle (item_identifier_clean, installed_on);
CREATE INDEX item_installation_cycle_failure_idx ON analytics.item_installation_cycle (has_observed_failure, failure_onset_on);
