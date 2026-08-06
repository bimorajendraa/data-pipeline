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
        OR gs.observation_on + INTERVAL '30 days'
            <= LEAST(c.cycle_end_on, c.dataset_max_event_on)
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
WHERE is_training_eligible AND NOT is_location_feature_eligible;

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
    REFRESH MATERIALIZED VIEW analytics.eda_snapshot_cadence_comparison;
END; $refresh$;

SELECT * FROM analytics.eda_snapshot_cadence_comparison ORDER BY cadence_days;
SELECT * FROM analytics.eda_failure_unit_comparison ORDER BY analysis_unit;
SELECT * FROM analytics.eda_incomplete_failure_summary ORDER BY followup_review_group;
SELECT * FROM analytics.eda_outlier_summary ORDER BY check_name;
