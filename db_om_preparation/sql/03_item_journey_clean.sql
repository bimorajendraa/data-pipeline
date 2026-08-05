-- Clean view utama. Setiap baris sumber tetap dipertahankan.
CREATE OR REPLACE VIEW analytics.item_journey_clean AS
WITH normalized AS (
    SELECT
        j.*,
        analytics.clean_code(j.item_category) AS item_category_clean,
        analytics.clean_code(j.item_type) AS item_type_clean,
        analytics.clean_code(j.item_model_code) AS item_model_code_clean,
        analytics.clean_code(j.item_pairing_code) AS item_pairing_code_clean,
        analytics.clean_code(j.host_serial_code) AS host_serial_code_clean,
        analytics.clean_name(j.client) AS client_clean,
        analytics.clean_code(j.ref_doc_code) AS ref_doc_code_clean,
        analytics.clean_code(j.wo_type) AS wo_type_clean,
        analytics.clean_code(j.wo_code) AS wo_code_clean,
        analytics.clean_code(j.place) AS place_clean,
        analytics.clean_code(j.activity) AS activity_clean,
        analytics.clean_code(j.status) AS status_clean,
        analytics.clean_name(j.done_by) AS done_by_clean,
        COUNT(*) OVER (PARTITION BY j.journey_id) > 1 AS is_duplicate_journey_id
    FROM journal.t_item_journey j
),
cleaned AS (
    SELECT
        n.*,
        COALESCE(
            n.item_pairing_code_clean,
            n.host_serial_code_clean,
            'JOURNEY#' || n.journey_id::text
        ) AS item_identifier_clean,
        ROW_NUMBER() OVER journey_order AS event_sequence_number,
        LAG(n.status_clean) OVER journey_order AS previous_status_clean,
        LEAD(n.status_clean) OVER journey_order AS next_status_clean,
        LAG(n.activity_clean) OVER journey_order AS previous_activity_clean,
        LEAD(n.activity_clean) OVER journey_order AS next_activity_clean,
        LAG(n.created_on) OVER journey_order AS previous_created_on
    FROM normalized n
    WINDOW journey_order AS (
        PARTITION BY COALESCE(
            n.item_pairing_code_clean,
            n.host_serial_code_clean,
            'JOURNEY#' || n.journey_id::text
        )
        ORDER BY n.created_on NULLS LAST, n.journey_id
    )
),
master_item AS (
    SELECT
        analytics.clean_code(m.item_model_code) AS item_model_code_clean,
        MAX(analytics.clean_code(m.item_type)) AS item_type_from_master,
        MAX(analytics.clean_code(m.item_category)) AS item_category_from_master
    FROM master.t_mtr_item m
    WHERE analytics.clean_code(m.item_model_code) IS NOT NULL
    GROUP BY analytics.clean_code(m.item_model_code)
),
inventory_identifier AS (
    SELECT DISTINCT
        analytics.clean_code(i.item_pairing_code) AS item_pairing_code_clean,
        analytics.clean_code(i.sn_ref) AS sn_ref_clean,
        CASE
            WHEN analytics.clean_code(i.item_model_code) IS NOT NULL
             AND analytics.clean_code(i.item_pairing_code) IS NOT NULL
             AND analytics.clean_code(i.repair_seq) IS NOT NULL
            THEN analytics.clean_code(
                i.item_model_code || '-' || i.item_pairing_code || '-' || i.repair_seq
            )
        END AS host_serial_code_clean,
        analytics.clean_code(i.item_model_code) AS item_model_code_clean
    FROM inventory.t_item i
),
inventory_pairing_lookup AS (
    -- Inventory diringkas satu kali agar setiap journey tidak melakukan
    -- correlated scan ke seluruh inventory.
    SELECT
        item_pairing_code_clean AS identifier_clean,
        COUNT(DISTINCT item_model_code_clean) AS nonnull_model_count,
        BOOL_OR(item_model_code_clean IS NULL) AS has_null_model,
        MIN(item_model_code_clean) AS only_model_code
    FROM inventory_identifier
    WHERE item_pairing_code_clean IS NOT NULL
    GROUP BY item_pairing_code_clean
),
inventory_host_lookup AS (
    SELECT
        value.identifier_clean,
        COUNT(DISTINCT i.item_model_code_clean) AS nonnull_model_count,
        BOOL_OR(i.item_model_code_clean IS NULL) AS has_null_model,
        MIN(i.item_model_code_clean) AS only_model_code
    FROM inventory_identifier i
    CROSS JOIN LATERAL (VALUES
        (i.host_serial_code_clean),
        (i.sn_ref_clean)
    ) value(identifier_clean)
    WHERE value.identifier_clean IS NOT NULL
    GROUP BY value.identifier_clean
),
inventory_model AS (
    SELECT DISTINCT item_model_code_clean
    FROM inventory_identifier
    WHERE item_model_code_clean IS NOT NULL
),
master_work_type AS (
    -- wo_type pada journey adalah sumber utama. Code dan nama master hanya
    -- membentuk representasi canonical, bukan mengganti nilai journey.
    SELECT
        work_type_value_clean,
        MIN(work_type_code_clean) AS work_type_code_clean,
        MIN(work_type_name_clean) AS work_type_name_clean
    FROM (
        SELECT
            analytics.clean_code(w.work_type_code) AS work_type_code_clean,
            analytics.clean_code(w.work_type) AS work_type_name_clean,
            value.work_type_value_clean
        FROM master.t_mtr_work_type w
        CROSS JOIN LATERAL (VALUES
            (analytics.clean_code(w.work_type_code)),
            (analytics.clean_code(w.work_type))
        ) value(work_type_value_clean)
        WHERE value.work_type_value_clean IS NOT NULL
    ) work_type_value
    GROUP BY work_type_value_clean
),
work_orders AS (
    -- Work order hanya dipakai sebagai validasi tambahan jika wo_code tersedia.
    SELECT DISTINCT ON (analytics.clean_code(wo.wo_code))
        analytics.clean_code(wo.wo_code) AS wo_code_clean,
        mwt.work_type_code_clean,
        mwt.work_type_name_clean
    FROM journal.t_work_order wo
    LEFT JOIN master_work_type mwt
        ON mwt.work_type_value_clean = analytics.clean_code(wo.work_type_code)
    WHERE analytics.clean_code(wo.wo_code) IS NOT NULL
    ORDER BY analytics.clean_code(wo.wo_code), wo.wo_id DESC
),
master_status AS (
    SELECT analytics.clean_code(s.status_code) AS status_clean
    FROM master.t_mtr_status s
    WHERE analytics.clean_code(s.status_code) IS NOT NULL
    UNION
    SELECT analytics.clean_code(s.status_name)
    FROM master.t_mtr_status s
    WHERE analytics.clean_code(s.status_name) IS NOT NULL
),
master_location AS (
    SELECT DISTINCT location_value_clean
    FROM master.t_mtr_location l
    CROSS JOIN LATERAL (VALUES
        (analytics.clean_code(l.location_code)),
        (analytics.clean_code(l.location_name))
    ) value(location_value_clean)
    WHERE location_value_clean IS NOT NULL
),
master_client AS (
    SELECT DISTINCT client_value_clean
    FROM master.t_mtr_client c
    CROSS JOIN LATERAL (VALUES
        (analytics.clean_name(c.client_code)),
        (analytics.clean_name(c.client_name))
    ) value(client_value_clean)
    WHERE client_value_clean IS NOT NULL
)
SELECT
    c.journey_id,
    c.item_category AS item_category_original,
    c.item_category_clean,
    c.item_type AS item_type_original,
    c.item_type_clean,
    c.item_model_code AS item_model_code_original,
    c.item_model_code_clean,
    c.item_pairing_code AS item_pairing_code_original,
    c.item_pairing_code_clean,
    c.host_serial_code AS host_serial_code_original,
    c.host_serial_code_clean,
    c.client AS client_original,
    c.client_clean,
    c.ref_doc_code AS ref_doc_code_original,
    c.ref_doc_code_clean,
    c.wo_type AS wo_type_original,
    c.wo_type_clean,
    c.wo_code AS wo_code_original,
    c.wo_code_clean,
    c.place AS place_original,
    c.place_clean,
    c.activity AS activity_original,
    c.activity_clean,
    c.status AS status_original,
    c.status_clean,
    c.done_by AS done_by_original,
    c.done_by_clean,
    analytics.clean_text(c.remark) AS remark,
    c.created_on,
    c.created_on::date AS created_date,
    EXTRACT(YEAR FROM c.created_on)::integer AS created_year,
    EXTRACT(MONTH FROM c.created_on)::integer AS created_month,
    DATE_TRUNC('month', c.created_on) AS created_year_month,
    c.created_by,
    c.created_on IS NOT NULL
        AND c.created_on::date >= DATE '1971-01-01' AS is_valid_date,
    c.created_on > CURRENT_TIMESTAMP AS is_future_date,
    c.created_on IS NULL
        OR c.created_on::date < DATE '1971-01-01'
        OR c.created_on > CURRENT_TIMESTAMP AS is_suspicious_date,
    c.item_pairing_code_clean IS NULL
        AND c.host_serial_code_clean IS NULL AS is_missing_item_identifier,
    pairing_inventory.identifier_clean IS NOT NULL
        OR host_inventory.identifier_clean IS NOT NULL AS is_item_found,
    inventory_model.item_model_code_clean IS NOT NULL
        AS is_item_model_in_inventory,
    mi.item_model_code_clean IS NOT NULL AS is_item_model_found,
    mi.item_type_from_master,
    mi.item_category_from_master,
    mi.item_model_code_clean IS NOT NULL
        AND c.item_type_clean IS NOT DISTINCT FROM mi.item_type_from_master
        AS is_item_type_consistent,
    mi.item_model_code_clean IS NOT NULL
        AND c.item_category_clean IS NOT DISTINCT FROM mi.item_category_from_master
        AS is_item_category_consistent,
    (pairing_inventory.identifier_clean IS NOT NULL
        OR host_inventory.identifier_clean IS NOT NULL)
    AND CASE
        WHEN pairing_inventory.identifier_clean IS NULL THEN TRUE
        WHEN c.item_model_code_clean IS NULL
            THEN pairing_inventory.nonnull_model_count = 0
        ELSE NOT pairing_inventory.has_null_model
         AND pairing_inventory.nonnull_model_count = 1
         AND pairing_inventory.only_model_code = c.item_model_code_clean
    END
    AND CASE
        WHEN host_inventory.identifier_clean IS NULL THEN TRUE
        WHEN c.item_model_code_clean IS NULL
            THEN host_inventory.nonnull_model_count = 0
        ELSE NOT host_inventory.has_null_model
         AND host_inventory.nonnull_model_count = 1
         AND host_inventory.only_model_code = c.item_model_code_clean
    END AS is_item_model_consistent,
    wo.wo_code_clean IS NOT NULL AS is_work_order_found,
    c.status_clean IS NULL
        OR ms.status_clean IS NOT NULL AS is_status_found,
    c.place_clean IS NULL
        OR ml.location_value_clean IS NOT NULL AS is_place_found,
    c.is_duplicate_journey_id,
    CASE
        WHEN c.journey_id IS NULL OR c.is_duplicate_journey_id THEN 'CRITICAL'
        WHEN (c.item_pairing_code_clean IS NULL AND c.host_serial_code_clean IS NULL)
          OR mi.item_model_code_clean IS NULL
          OR (c.wo_code_clean IS NOT NULL AND wo.wo_code_clean IS NULL)
          OR c.created_on IS NULL
          OR c.created_on::date < DATE '1971-01-01'
          OR c.created_on > CURRENT_TIMESTAMP
          OR (c.status_clean IS NOT NULL AND ms.status_clean IS NULL)
          OR (c.place_clean IS NOT NULL AND ml.location_value_clean IS NULL)
          OR (c.client_clean IS NOT NULL AND mc.client_value_clean IS NULL)
          OR (c.wo_type_clean IS NOT NULL AND journey_wt.work_type_value_clean IS NULL)
          OR (
              c.wo_type_clean IS NOT NULL
              AND c.wo_code_clean IS NOT NULL
              AND wo.wo_code_clean IS NOT NULL
              AND journey_wt.work_type_code_clean IS NOT NULL
              AND wo.work_type_code_clean IS NOT NULL
              AND journey_wt.work_type_code_clean <> wo.work_type_code_clean
          )
        THEN 'WARNING'
        ELSE 'OK'
    END AS data_quality_status,
    c.client_clean IS NULL
        OR mc.client_value_clean IS NOT NULL AS is_client_found,
    c.wo_type_clean IS NULL
        OR journey_wt.work_type_value_clean IS NOT NULL AS is_work_type_found,
    c.item_identifier_clean,
    c.event_sequence_number,
    c.previous_status_clean,
    c.next_status_clean,
    c.previous_activity_clean,
    c.next_activity_clean,
    c.previous_created_on,
    EXTRACT(EPOCH FROM (c.created_on - c.previous_created_on)) / 86400.0
        AS days_since_previous_event,
    journey_wt.work_type_code_clean AS journey_work_type_code_clean,
    journey_wt.work_type_name_clean AS journey_work_type_name_clean,
    wo.work_type_code_clean AS work_order_work_type_code_clean,
    wo.work_type_name_clean AS work_order_work_type_name_clean,
    CASE
        WHEN c.wo_type_clean IS NULL
          OR c.wo_code_clean IS NULL
          OR wo.wo_code_clean IS NULL
        THEN NULL
        WHEN journey_wt.work_type_code_clean IS NULL
          OR wo.work_type_code_clean IS NULL
        THEN FALSE
        ELSE journey_wt.work_type_code_clean = wo.work_type_code_clean
    END AS is_work_type_consistent
FROM cleaned c
LEFT JOIN master_item mi
    ON mi.item_model_code_clean = c.item_model_code_clean
LEFT JOIN inventory_pairing_lookup pairing_inventory
    ON pairing_inventory.identifier_clean = c.item_pairing_code_clean
LEFT JOIN inventory_host_lookup host_inventory
    ON host_inventory.identifier_clean = c.host_serial_code_clean
LEFT JOIN inventory_model
    ON inventory_model.item_model_code_clean = c.item_model_code_clean
LEFT JOIN work_orders wo
    ON wo.wo_code_clean = c.wo_code_clean
LEFT JOIN master_status ms
    ON ms.status_clean = c.status_clean
LEFT JOIN master_location ml
    ON ml.location_value_clean = c.place_clean
LEFT JOIN master_client mc
    ON mc.client_value_clean = c.client_clean
LEFT JOIN master_work_type journey_wt
    ON journey_wt.work_type_value_clean = c.wo_type_clean;

-- Profil transisi berdasarkan urutan aktual item. Ini tidak memberi label bisnis
-- seperti failure/normal; hanya merangkum status yang benar-benar muncul berurutan.
CREATE OR REPLACE VIEW analytics.item_journey_transition_profile_live AS
WITH ordered AS (
    SELECT
        j.*,
        LAG(j.status_clean) OVER (
            PARTITION BY j.item_identifier_clean
            ORDER BY j.created_on NULLS LAST, j.journey_id
        ) AS status_before_current
    FROM analytics.item_journey_clean j
    WHERE j.is_valid_date
      AND NOT j.is_future_date
),
status_changes AS (
    SELECT *
    FROM ordered
    WHERE status_clean IS NOT NULL
      AND status_clean IS DISTINCT FROM status_before_current
),
transitions AS (
    SELECT
        item_category_clean,
        item_type_clean,
        wo_type_clean,
        status_clean AS from_status,
        LEAD(status_clean) OVER transition_order AS to_status,
        created_on AS from_created_on,
        LEAD(created_on) OVER transition_order AS to_created_on
    FROM status_changes
    WINDOW transition_order AS (
        PARTITION BY item_identifier_clean
        ORDER BY created_on NULLS LAST, journey_id
    )
)
SELECT
    item_category_clean,
    item_type_clean,
    wo_type_clean,
    from_status,
    to_status,
    COUNT(*) AS transition_count,
    ROUND((
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (to_created_on - from_created_on)) / 86400.0
        )
    )::numeric, 2) AS median_days_to_next_status,
    MIN(from_created_on) AS first_seen_on,
    MAX(from_created_on) AS last_seen_on
FROM transitions
WHERE to_status IS NOT NULL
GROUP BY
    item_category_clean,
    item_type_clean,
    wo_type_clean,
    from_status,
    to_status;

DO $migration$
DECLARE
    object_kind "char";
BEGIN
    SELECT c.relkind
    INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'item_journey_transition_profile';

    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.item_journey_transition_profile';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.item_journey_transition_profile';
    END IF;
END;
$migration$;

CREATE MATERIALIZED VIEW analytics.item_journey_transition_profile AS
SELECT * FROM analytics.item_journey_transition_profile_live;

CREATE INDEX item_journey_transition_lookup_idx
    ON analytics.item_journey_transition_profile (
        item_category_clean,
        item_type_clean,
        wo_type_clean,
        from_status,
        to_status
    );
