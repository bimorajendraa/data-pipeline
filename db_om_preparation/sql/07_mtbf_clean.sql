-- MTBF dipertahankan sebagai data suplementer. View ini tidak digunakan untuk
-- menentukan flow journey dan tidak menghitung ulang nilai MTBF.
CREATE OR REPLACE VIEW analytics.mtbf_clean AS
WITH master_item AS (
    SELECT
        item_model_value_clean,
        MIN(item_model_code_clean) AS item_model_code_clean,
        MIN(item_model_name_clean) AS item_model_name_clean,
        MIN(item_type_from_master) AS item_type_from_master,
        MIN(item_category_from_master) AS item_category_from_master,
        COUNT(DISTINCT item_model_code_clean) > 1 AS is_item_model_ambiguous
    FROM (
        SELECT
            analytics.clean_code(m.item_model_code) AS item_model_code_clean,
            analytics.clean_code(m.item_model_name) AS item_model_name_clean,
            analytics.clean_code(m.item_type) AS item_type_from_master,
            analytics.clean_code(m.item_category) AS item_category_from_master,
            value.item_model_value_clean
        FROM master.t_mtr_item m
        CROSS JOIN LATERAL (VALUES
            (analytics.clean_code(m.item_model_code)),
            (analytics.clean_code(m.item_model_name))
        ) value(item_model_value_clean)
        WHERE value.item_model_value_clean IS NOT NULL
    ) item_value
    GROUP BY item_model_value_clean
),
master_client AS (
    SELECT
        client_value_clean,
        MIN(client_code_clean) AS client_code_clean
    FROM (
        SELECT
            analytics.clean_code(c.client_code) AS client_code_clean,
            value.client_value_clean
        FROM master.t_mtr_client c
        CROSS JOIN LATERAL (VALUES
            (analytics.clean_name(c.client_code)),
            (analytics.clean_name(c.client_name))
        ) value(client_value_clean)
        WHERE client_value_clean IS NOT NULL
    ) client_value
    GROUP BY client_value_clean
)
SELECT
    m.mtbf_id,
    m.item_category AS item_category_original,
    analytics.clean_code(m.item_category) AS item_category_clean,
    m.item_type AS item_type_original,
    analytics.clean_code(m.item_type) AS item_type_clean,
    m.item_model AS item_model_original,
    analytics.clean_code(m.item_model) AS item_model_clean,
    m.sn_ref AS sn_ref_original,
    analytics.clean_code(m.sn_ref) AS sn_ref_clean,
    m.client_code AS client_code_original,
    analytics.clean_name(m.client_code) AS client_code_clean,
    m.location_code AS location_code_original,
    analytics.clean_code(m.location_code) AS location_code_clean,
    m.time_operation,
    m.time_operation / 60.0 AS time_operation_hours,
    m.is_repair,
    m.is_active,
    m.created_on,
    analytics.clean_code(m.sn_ref) IS NULL AS is_missing_item_identifier,
    m.time_operation IS NOT NULL AND m.time_operation >= 0 AS is_time_operation_valid,
    mi.item_model_value_clean IS NOT NULL AS is_item_model_found,
    mc.client_value_clean IS NOT NULL AS is_client_found,
    ml.location_value_clean IS NOT NULL AS is_location_found,
    m.is_active IN (0, 1) AS is_active_valid,
    m.created_on IS NOT NULL
        AND m.created_on::date >= DATE '1971-01-01' AS is_valid_date,
    m.created_on > CURRENT_TIMESTAMP AS is_future_date,
    m.created_on IS NULL
        OR m.created_on::date < DATE '1971-01-01'
        OR m.created_on > CURRENT_TIMESTAMP AS is_suspicious_date,
    CASE
        WHEN m.mtbf_id IS NULL THEN 'CRITICAL'
        WHEN analytics.clean_code(m.sn_ref) IS NULL
          OR m.time_operation IS NULL OR m.time_operation < 0
          OR mi.item_model_value_clean IS NULL
          OR mi.is_item_model_ambiguous
          OR mc.client_value_clean IS NULL
          OR ml.location_value_clean IS NULL
          OR m.is_active NOT IN (0, 1)
          OR m.is_repair NOT IN (0, 1)
          OR m.created_on IS NULL
          OR m.created_on::date < DATE '1971-01-01'
          OR m.created_on > CURRENT_TIMESTAMP
        THEN 'WARNING'
        ELSE 'OK'
    END AS data_quality_status,
    mi.item_model_code_clean AS item_model_code_from_master,
    mi.item_model_name_clean AS item_model_name_from_master,
    mi.item_type_from_master,
    mi.item_category_from_master,
    mc.client_code_clean AS client_code_from_master,
    mi.is_item_model_ambiguous,
    mi.item_model_value_clean IS NOT NULL
        AND analytics.clean_code(m.item_type) IS NOT DISTINCT FROM mi.item_type_from_master
        AS is_item_type_consistent,
    mi.item_model_value_clean IS NOT NULL
        AND analytics.clean_code(m.item_category) IS NOT DISTINCT FROM mi.item_category_from_master
        AS is_item_category_consistent,
    m.is_repair IN (0, 1) AS is_repair_valid
FROM journal.t_mtbf m
LEFT JOIN master_item mi
    ON mi.item_model_value_clean = analytics.clean_code(m.item_model)
LEFT JOIN master_client mc
    ON mc.client_value_clean = analytics.clean_name(m.client_code)
LEFT JOIN analytics.master_location_lookup ml
    ON ml.location_value_clean = analytics.clean_code(m.location_code);
