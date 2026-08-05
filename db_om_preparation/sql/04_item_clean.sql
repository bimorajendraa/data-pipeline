CREATE OR REPLACE VIEW analytics.item_clean AS
WITH master_item AS (
    SELECT DISTINCT analytics.clean_code(item_model_code) AS item_model_code_clean
    FROM master.t_mtr_item
),
master_location AS (
    SELECT DISTINCT analytics.clean_code(location_code) AS location_code_clean
    FROM master.t_mtr_location
),
master_status AS (
    SELECT analytics.clean_code(status_code) AS status_clean FROM master.t_mtr_status
    UNION
    SELECT analytics.clean_code(status_name) FROM master.t_mtr_status
)
SELECT
    i.item_id,
    i.item_model_code AS item_model_code_original,
    analytics.clean_code(i.item_model_code) AS item_model_code_clean,
    i.item_pairing_code AS item_pairing_code_original,
    analytics.clean_code(i.item_pairing_code) AS item_pairing_code_clean,
    i.sn_ref AS sn_ref_original,
    analytics.clean_code(i.sn_ref) AS sn_ref_clean,
    i.ref_doc_code AS ref_doc_code_original,
    analytics.clean_code(i.ref_doc_code) AS ref_doc_code_clean,
    i.location_code AS location_code_original,
    analytics.clean_code(i.location_code) AS location_code_clean,
    i.status AS status_original,
    analytics.clean_code(i.status) AS status_clean,
    i.supplier_warranty_end_date,
    i.received_date,
    i.is_active,
    i.repair_seq,
    i.updated_on,
    analytics.clean_name(i.pic) AS pic_clean,
    analytics.clean_text(i.remark) AS remark,
    analytics.clean_code(i.item_pairing_code) IS NULL
        AND analytics.clean_code(i.sn_ref) IS NULL AS is_missing_item_identifier,
    mi.item_model_code_clean IS NOT NULL AS is_item_model_found,
    ml.location_code_clean IS NOT NULL AS is_location_found,
    analytics.clean_code(i.status) IS NULL
        OR ms.status_clean IS NOT NULL AS is_status_found,
    i.received_date IS NOT NULL
        AND i.received_date >= DATE '1971-01-01'
        AND i.created_on IS NOT NULL
        AND i.created_on::date >= DATE '1971-01-01'
        AND (i.updated_on IS NULL OR i.received_date <= i.updated_on::date)
        AND (i.updated_on IS NULL OR i.created_on <= i.updated_on)
        AS is_valid_date,
    i.received_date > CURRENT_DATE
        OR i.created_on > CURRENT_TIMESTAMP
        OR i.updated_on > CURRENT_TIMESTAMP AS is_future_date,
    i.received_date IS NULL
        OR i.received_date < DATE '1971-01-01'
        OR i.created_on IS NULL
        OR i.created_on::date < DATE '1971-01-01'
        OR (i.updated_on IS NOT NULL AND i.received_date > i.updated_on::date)
        OR (i.updated_on IS NOT NULL AND i.created_on > i.updated_on)
        OR (i.supplier_warranty_end_date IS NOT NULL
            AND i.supplier_warranty_end_date < i.received_date)
        AS is_suspicious_date,
    CASE
        WHEN i.item_id IS NULL THEN 'CRITICAL'
        WHEN mi.item_model_code_clean IS NULL
          OR (analytics.clean_code(i.item_pairing_code) IS NULL
              AND analytics.clean_code(i.sn_ref) IS NULL)
          OR ml.location_code_clean IS NULL
          OR (analytics.clean_code(i.status) IS NOT NULL AND ms.status_clean IS NULL)
          OR i.received_date IS NULL
          OR i.received_date < DATE '1971-01-01'
          OR i.created_on IS NULL
          OR i.created_on::date < DATE '1971-01-01'
          OR (i.updated_on IS NOT NULL AND i.received_date > i.updated_on::date)
          OR (i.updated_on IS NOT NULL AND i.created_on > i.updated_on)
          OR (i.supplier_warranty_end_date IS NOT NULL
              AND i.supplier_warranty_end_date < i.received_date)
        THEN 'WARNING'
        ELSE 'OK'
    END AS data_quality_status,
    i.created_on,
    CASE
        WHEN analytics.clean_code(i.item_model_code) IS NOT NULL
         AND analytics.clean_code(i.item_pairing_code) IS NOT NULL
         AND analytics.clean_code(i.repair_seq) IS NOT NULL
        THEN analytics.clean_code(
            i.item_model_code || '-' || i.item_pairing_code || '-' || i.repair_seq
        )
    END AS host_serial_code_clean,
    i.updated_on IS NULL OR i.created_on <= i.updated_on
        AS is_created_updated_order_valid,
    i.supplier_warranty_end_date > CURRENT_DATE AS is_warranty_end_in_future
FROM inventory.t_item i
LEFT JOIN master_item mi
    ON mi.item_model_code_clean = analytics.clean_code(i.item_model_code)
LEFT JOIN master_location ml
    ON ml.location_code_clean = analytics.clean_code(i.location_code)
LEFT JOIN master_status ms
    ON ms.status_clean = analytics.clean_code(i.status);
