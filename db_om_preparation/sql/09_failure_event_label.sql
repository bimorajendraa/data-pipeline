-- Label event kerusakan yang sudah dikonfirmasi secara bisnis.
-- Clean view sumber tidak diubah; view ini hanya menambahkan interpretasi label.
DROP VIEW IF EXISTS analytics.item_journey_failure_labeled;

-- Hapus cache versi sebelumnya secara berurutan karena failure_event_clean
-- bergantung pada live view dan event cache.
DO $migration$
DECLARE
    object_kind "char";
BEGIN
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS analytics.eda_snapshot_cadence_comparison';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_outlier_summary';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_failure_unit_comparison';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_incomplete_failure_summary';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_incomplete_failure_detail';
    EXECUTE 'DROP VIEW IF EXISTS analytics.failure_outcome_missing_onset_review';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_location_lifecycle_summary';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_location_lifecycle_detail';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_daily_activity_anomaly';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_item_location_installation_summary';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_activity_calendar_summary';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_location_activity_summary';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_item_activity_summary';

    -- Objek EDA tahap 11-13 bergantung pada failure/timeline cache. Hapus
    -- terlebih dahulu agar pipeline lengkap tetap idempotent saat dijalankan ulang.
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_failure_readiness_summary';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_failure_rate_by_year';
    EXECUTE 'DROP VIEW IF EXISTS analytics.eda_feature_missingness';
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS analytics.item_observation_30d';
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS analytics.item_installation_cycle';

    -- Objek tahap semantic/timeline bergantung pada cache di file ini. Hapus
    -- lebih dahulu agar pipeline 01-10 aman dijalankan ulang.
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS analytics.failure_event_flow';
    EXECUTE 'DROP VIEW IF EXISTS analytics.failure_event_flow_live';
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS analytics.item_journey_operational_timeline';
    EXECUTE 'DROP VIEW IF EXISTS analytics.item_journey_operational_timeline_live';
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS analytics.item_journey_semantic';
    EXECUTE 'DROP VIEW IF EXISTS analytics.item_journey_semantic_live';

    SELECT c.relkind
    INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'failure_event_clean';

    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.failure_event_clean';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.failure_event_clean';
    END IF;

    EXECUTE 'DROP VIEW IF EXISTS analytics.failure_event_clean_live';

    SELECT c.relkind
    INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'item_journey_event_cache';

    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.item_journey_event_cache';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.item_journey_event_cache';
    END IF;

    SELECT c.relkind
    INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'item_identifier_model_cache';

    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.item_identifier_model_cache';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.item_identifier_model_cache';
    END IF;
END;
$migration$;

-- Cache ramping untuk pencarian event sebelumnya. Nilai normalisasi sama dengan
-- item_journey_clean, tetapi tidak membawa seluruh join validasi yang berat.
CREATE MATERIALIZED VIEW analytics.item_journey_event_cache AS
SELECT
    journey_id,
    item_category_clean,
    item_type_clean,
    item_model_code_clean,
    item_pairing_code_clean,
    host_serial_code_clean,
    item_identifier_clean,
    client_clean AS client_source_clean,
    client_canonical_clean AS client_clean,
    client_master_code_clean,
    client_master_name_clean,
    client_mapping_method,
    client_fuzzy_score,
    client_fuzzy_margin,
    is_client_fuzzy_accepted,
    is_client_mapping_ambiguous,
    place_clean,
    place_master_code_clean,
    place_master_name_clean,
    place_canonical_clean,
    is_place_found,
    is_place_mapping_ambiguous,
    place_mapping_method,
    place_fuzzy_score,
    place_fuzzy_margin,
    is_place_fuzzy_accepted,
    wo_type_clean,
    wo_code_clean,
    activity_clean,
    status_clean,
    done_by_clean,
    remark,
    created_on
FROM analytics.item_journey_clean;

CREATE INDEX item_journey_event_id_idx
    ON analytics.item_journey_event_cache (journey_id);

CREATE INDEX item_journey_event_order_idx
    ON analytics.item_journey_event_cache (
        item_identifier_clean,
        created_on,
        journey_id
    );

CREATE INDEX item_journey_event_failure_lookup_idx
    ON analytics.item_journey_event_cache (
        status_clean,
        wo_type_clean,
        created_on
    );

-- Lookup identifier inventory diringkas dan di-index satu kali. Ini mencegah
-- agregasi inventory berulang setiap kali eligibility label dibaca.
CREATE MATERIALIZED VIEW analytics.item_identifier_model_cache AS
WITH identifier_values AS (
    SELECT
        'PAIRING'::text AS lookup_type,
        item_pairing_code_clean AS identifier_clean,
        item_model_code_clean
    FROM analytics.item_clean
    WHERE item_pairing_code_clean IS NOT NULL
    UNION ALL
    SELECT 'HOST', host_serial_code_clean, item_model_code_clean
    FROM analytics.item_clean
    WHERE host_serial_code_clean IS NOT NULL
    UNION ALL
    SELECT 'HOST', sn_ref_clean, item_model_code_clean
    FROM analytics.item_clean
    WHERE sn_ref_clean IS NOT NULL
)
SELECT
    lookup_type,
    identifier_clean,
    COUNT(DISTINCT item_model_code_clean) AS nonnull_model_count,
    BOOL_OR(item_model_code_clean IS NULL) AS has_null_model,
    MIN(item_model_code_clean) AS only_model_code
FROM identifier_values
GROUP BY lookup_type, identifier_clean;

CREATE UNIQUE INDEX item_identifier_model_lookup_idx
    ON analytics.item_identifier_model_cache (lookup_type, identifier_clean);

-- Inventory lookup mempertahankan aturan identifier/model dari clean view.
-- Selain corrective dismantle, preventive dismantle menjadi failure bila
-- kemudian dikonfirmasi BROKEN/UNREPAIRABLE sebelum installation berikutnya.
CREATE OR REPLACE VIEW analytics.failure_event_clean_live AS
WITH candidate_onset AS (
    SELECT *
    FROM analytics.item_journey_event_cache
    WHERE status_clean = 'DISMANTLED'
      AND wo_type_clean IN ('CORRECTIVE', 'PREVENTIVE')
),
failure_event AS (
    SELECT
        c.*,
        CASE
            WHEN c.wo_type_clean = 'CORRECTIVE' THEN c.created_on
            ELSE outcome.created_on
        END AS failure_confirmed_on,
        CASE
            WHEN c.wo_type_clean = 'CORRECTIVE' THEN c.status_clean
            ELSE outcome.status_clean
        END AS failure_confirmation_status,
        CASE
            WHEN c.wo_type_clean = 'CORRECTIVE'
                THEN 'CONFIRMED_CORRECTIVE_DISMANTLE'
            ELSE 'CONFIRMED_FAILURE_OUTCOME_AFTER_PREVENTIVE'
        END AS event_label_basis
    FROM candidate_onset c
    LEFT JOIN LATERAL (
        SELECT o.created_on, o.status_clean
        FROM analytics.item_journey_event_cache o
        WHERE c.wo_type_clean = 'PREVENTIVE'
          AND o.item_identifier_clean = c.item_identifier_clean
          AND o.status_clean IN ('UNREPAIRABLE', 'BROKEN', 'SENDLOG (BROKEN)')
          AND (
              o.created_on > c.created_on
              OR (o.created_on = c.created_on AND o.journey_id > c.journey_id)
          )
          AND NOT EXISTS (
              SELECT 1
              FROM analytics.item_journey_event_cache n
              WHERE n.item_identifier_clean = c.item_identifier_clean
                AND n.status_clean = 'INSTALLED'
                AND (
                    n.created_on > c.created_on
                    OR (n.created_on = c.created_on AND n.journey_id > c.journey_id)
                )
                AND (
                    n.created_on < o.created_on
                    OR (n.created_on = o.created_on AND n.journey_id < o.journey_id)
                )
          )
        ORDER BY o.created_on, o.journey_id
        LIMIT 1
    ) outcome ON TRUE
    WHERE c.wo_type_clean = 'CORRECTIVE'
       OR outcome.created_on IS NOT NULL
),
validated AS (
    SELECT
        f.*,
        previous_event.status_clean AS previous_status_clean,
        previous_event.activity_clean AS previous_activity_clean,
        previous_event.created_on AS previous_created_on,
        pairing_inventory.identifier_clean IS NOT NULL
            OR host_inventory.identifier_clean IS NOT NULL AS is_item_found,
        (pairing_inventory.identifier_clean IS NOT NULL
            OR host_inventory.identifier_clean IS NOT NULL)
        AND CASE
            WHEN pairing_inventory.identifier_clean IS NULL THEN TRUE
            WHEN f.item_model_code_clean IS NULL
                THEN pairing_inventory.nonnull_model_count = 0
            ELSE NOT pairing_inventory.has_null_model
             AND pairing_inventory.nonnull_model_count = 1
             AND pairing_inventory.only_model_code = f.item_model_code_clean
        END
        AND CASE
            WHEN host_inventory.identifier_clean IS NULL THEN TRUE
            WHEN f.item_model_code_clean IS NULL
                THEN host_inventory.nonnull_model_count = 0
            ELSE NOT host_inventory.has_null_model
             AND host_inventory.nonnull_model_count = 1
             AND host_inventory.only_model_code = f.item_model_code_clean
        END AS is_item_model_consistent
    FROM failure_event f
    LEFT JOIN LATERAL (
        SELECT p.status_clean, p.activity_clean, p.created_on
        FROM analytics.item_journey_event_cache p
        WHERE p.item_identifier_clean = f.item_identifier_clean
          AND (
              (
                  f.created_on IS NOT NULL
                  AND p.created_on IS NOT NULL
                  AND (
                      p.created_on < f.created_on
                      OR (p.created_on = f.created_on AND p.journey_id < f.journey_id)
                  )
              )
              OR (
                  f.created_on IS NULL
                  AND (
                      p.created_on IS NOT NULL
                      OR (p.created_on IS NULL AND p.journey_id < f.journey_id)
                  )
              )
          )
        ORDER BY p.created_on DESC NULLS FIRST, p.journey_id DESC
        LIMIT 1
    ) previous_event ON TRUE
    LEFT JOIN analytics.item_identifier_model_cache pairing_inventory
        ON pairing_inventory.lookup_type = 'PAIRING'
       AND pairing_inventory.identifier_clean = f.item_pairing_code_clean
    LEFT JOIN analytics.item_identifier_model_cache host_inventory
        ON host_inventory.lookup_type = 'HOST'
       AND host_inventory.identifier_clean = f.host_serial_code_clean
)
SELECT
    journey_id,
    item_identifier_clean,
    item_category_clean,
    item_type_clean,
    item_model_code_clean,
    item_pairing_code_clean,
    host_serial_code_clean,
    client_clean,
    place_clean,
    place_master_code_clean,
    place_master_name_clean,
    place_canonical_clean AS failure_place_clean,
    is_place_found AS is_failure_place_found,
    is_place_mapping_ambiguous AS is_failure_place_mapping_ambiguous,
    created_on AS failure_onset_on,
    created_on::date AS failure_onset_date,
    failure_confirmed_on,
    failure_confirmed_on::date AS failure_confirmed_date,
    failure_confirmation_status,
    previous_status_clean,
    previous_activity_clean,
    previous_created_on,
    EXTRACT(EPOCH FROM (created_on - previous_created_on)) / 86400.0
        AS days_since_previous_event,
    wo_type_clean,
    wo_code_clean,
    activity_clean,
    status_clean,
    place_canonical_clean IS NOT NULL
        AND NOT is_place_mapping_ambiguous AS is_location_feature_eligible,
    (
        item_category_clean = 'PART'
        AND created_on IS NOT NULL
        AND created_on::date >= DATE '1971-01-01'
        AND created_on <= CURRENT_TIMESTAMP
        AND is_item_found
        AND is_item_model_consistent
    ) AS is_initial_model_cohort,
    CASE
        WHEN item_category_clean IS DISTINCT FROM 'PART'
            THEN 'EXCLUDED_NON_PART'
        WHEN created_on IS NULL
          OR created_on::date < DATE '1971-01-01'
          OR created_on > CURRENT_TIMESTAMP
            THEN 'EXCLUDED_INVALID_EVENT_DATE'
        WHEN NOT is_item_found
            THEN 'EXCLUDED_ITEM_NOT_FOUND'
        WHEN is_item_model_consistent IS NOT TRUE
            THEN 'EXCLUDED_MODEL_INCONSISTENT'
        ELSE 'ELIGIBLE'
    END AS model_cohort_status,
    event_label_basis
FROM validated;

CREATE MATERIALIZED VIEW analytics.failure_event_clean AS
SELECT * FROM analytics.failure_event_clean_live;

CREATE INDEX failure_event_item_date_idx
    ON analytics.failure_event_clean (item_identifier_clean, failure_onset_on);

CREATE INDEX failure_event_model_date_idx
    ON analytics.failure_event_clean (item_model_code_clean, failure_onset_on);

CREATE INDEX failure_event_cohort_idx
    ON analytics.failure_event_clean (is_initial_model_cohort, failure_onset_on);

-- Sinkronkan view label event dengan dua dasar failure yang sudah tervalidasi.
CREATE OR REPLACE VIEW analytics.item_journey_failure_labeled AS
SELECT
    j.*,
    f.journey_id IS NOT NULL AS is_failure_onset,
    (
        j.wo_type_clean = 'RECON'
        OR j.journey_work_type_name_clean = 'RECON'
        OR j.work_order_work_type_name_clean = 'RECON'
    ) AS is_planned_recon_context,
    (
        j.item_category_clean = 'PART'
        AND j.is_valid_date
        AND NOT j.is_future_date
        AND j.is_item_found
        AND j.is_item_model_consistent
    ) AS is_initial_model_cohort,
    CASE
        WHEN j.item_category_clean IS DISTINCT FROM 'PART'
            THEN 'EXCLUDED_NON_PART'
        WHEN NOT j.is_valid_date OR j.is_future_date
            THEN 'EXCLUDED_INVALID_EVENT_DATE'
        WHEN NOT j.is_item_found
            THEN 'EXCLUDED_ITEM_NOT_FOUND'
        WHEN j.is_item_model_consistent IS NOT TRUE
            THEN 'EXCLUDED_MODEL_INCONSISTENT'
        ELSE 'ELIGIBLE'
    END AS model_cohort_status,
    CASE
        WHEN f.journey_id IS NOT NULL THEN f.event_label_basis
        WHEN j.wo_type_clean = 'RECON'
          OR j.journey_work_type_name_clean = 'RECON'
          OR j.work_order_work_type_name_clean = 'RECON'
            THEN 'PLANNED_RECON_NON_FAILURE'
        ELSE NULL
    END AS event_label_basis
FROM analytics.item_journey_clean j
LEFT JOIN analytics.failure_event_clean f
    ON f.journey_id = j.journey_id;

-- Perbarui entry point refresh agar cache event dibangun sebelum cache label.
CREATE OR REPLACE PROCEDURE analytics.refresh_cached_views()
LANGUAGE plpgsql
AS $refresh$
BEGIN
    REFRESH MATERIALIZED VIEW analytics.data_profile;
    REFRESH MATERIALIZED VIEW analytics.item_journey_event_cache;
    REFRESH MATERIALIZED VIEW analytics.item_identifier_model_cache;
    REFRESH MATERIALIZED VIEW analytics.item_journey_transition_profile;
    REFRESH MATERIALIZED VIEW analytics.data_quality_summary;
    REFRESH MATERIALIZED VIEW analytics.failure_event_clean;
END;
$refresh$;

SELECT
    COUNT(*) AS confirmed_failure_events,
    COUNT(*) FILTER (WHERE is_initial_model_cohort) AS eligible_part_failure_events,
    COUNT(DISTINCT item_identifier_clean) AS affected_items,
    MIN(failure_onset_on) AS first_failure_onset,
    MAX(failure_onset_on) AS last_failure_onset
FROM analytics.failure_event_clean;
