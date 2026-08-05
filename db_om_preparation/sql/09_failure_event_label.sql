-- Label event kerusakan yang sudah dikonfirmasi secara bisnis.
-- Clean view sumber tidak diubah; view ini hanya menambahkan interpretasi label.
CREATE OR REPLACE VIEW analytics.item_journey_failure_labeled AS
SELECT
    j.*,
    (
        j.status_clean = 'DISMANTLED'
        AND j.wo_type_clean = 'CORRECTIVE'
    ) AS is_failure_onset,
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
        WHEN j.status_clean = 'DISMANTLED'
         AND j.wo_type_clean = 'CORRECTIVE'
            THEN 'CONFIRMED_CORRECTIVE_DISMANTLE'
        WHEN j.wo_type_clean = 'RECON'
          OR j.journey_work_type_name_clean = 'RECON'
          OR j.work_order_work_type_name_clean = 'RECON'
            THEN 'PLANNED_RECON_NON_FAILURE'
        ELSE NULL
    END AS event_label_basis
FROM analytics.item_journey_clean j;

-- Hapus cache versi sebelumnya secara berurutan karena failure_event_clean
-- bergantung pada live view dan event cache.
DO $migration$
DECLARE
    object_kind "char";
BEGIN
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
    client_clean,
    place_clean,
    wo_type_clean,
    wo_code_clean,
    activity_clean,
    status_clean,
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
CREATE OR REPLACE VIEW analytics.failure_event_clean_live AS
WITH failure_event AS (
    SELECT *
    FROM analytics.item_journey_event_cache
    WHERE status_clean = 'DISMANTLED'
      AND wo_type_clean = 'CORRECTIVE'
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
    created_on AS failure_onset_on,
    created_on::date AS failure_onset_date,
    previous_status_clean,
    previous_activity_clean,
    previous_created_on,
    EXTRACT(EPOCH FROM (created_on - previous_created_on)) / 86400.0
        AS days_since_previous_event,
    wo_type_clean,
    wo_code_clean,
    activity_clean,
    status_clean,
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
    'CONFIRMED_CORRECTIVE_DISMANTLE'::text AS event_label_basis
FROM validated;

CREATE MATERIALIZED VIEW analytics.failure_event_clean AS
SELECT * FROM analytics.failure_event_clean_live;

CREATE INDEX failure_event_item_date_idx
    ON analytics.failure_event_clean (item_identifier_clean, failure_onset_on);

CREATE INDEX failure_event_model_date_idx
    ON analytics.failure_event_clean (item_model_code_clean, failure_onset_on);

CREATE INDEX failure_event_cohort_idx
    ON analytics.failure_event_clean (is_initial_model_cohort, failure_onset_on);

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
