CREATE OR REPLACE VIEW analytics.work_order_history_clean AS
WITH source AS (
    SELECT
        h.*,
        analytics.clean_code(h.wo_code) AS wo_code_clean,
        analytics.clean_code(h.status) AS status_clean,
        LAG(h.created_on) OVER (
            PARTITION BY analytics.clean_code(h.wo_code)
            ORDER BY h.wo_history_id
        ) AS previous_created_on
    FROM journal.t_work_order_history h
),
work_orders AS (
    SELECT DISTINCT analytics.clean_code(wo_code) AS wo_code_clean
    FROM journal.t_work_order
)
SELECT
    h.wo_history_id,
    h.wo_code AS wo_code_original,
    h.wo_code_clean,
    h.activity AS activity_original,
    analytics.clean_code(h.activity) AS activity_clean,
    h.activity_code AS activity_code_original,
    analytics.clean_code(h.activity_code) AS activity_code_clean,
    h.place AS place_original,
    analytics.clean_code(h.place) AS place_clean,
    h.status AS status_original,
    h.status_clean,
    analytics.clean_text(h.remark) AS remark,
    h.created_on,
    h.created_by,
    h.previous_created_on,
    wo.wo_code_clean IS NOT NULL AS is_work_order_found,
    h.status_clean IS NULL OR ms.status_code_clean IS NOT NULL AS is_status_found,
    h.created_on IS NOT NULL
        AND h.created_on::date >= DATE '1971-01-01' AS is_valid_date,
    h.created_on > CURRENT_TIMESTAMP AS is_future_date,
    h.created_on IS NULL
        OR h.created_on::date < DATE '1971-01-01'
        OR h.created_on > CURRENT_TIMESTAMP AS is_suspicious_date,
    h.previous_created_on IS NULL
        OR h.created_on >= h.previous_created_on AS is_activity_sequence_valid,
    CASE
        WHEN h.wo_history_id IS NULL OR h.wo_code_clean IS NULL THEN 'CRITICAL'
        WHEN wo.wo_code_clean IS NULL
          OR (h.status_clean IS NOT NULL AND ms.status_code_clean IS NULL)
          OR (analytics.clean_code(h.place) IS NOT NULL
              AND ml.location_value_clean IS NULL)
          OR h.created_on IS NULL
          OR h.created_on::date < DATE '1971-01-01'
          OR h.created_on > CURRENT_TIMESTAMP
        THEN 'WARNING'
        ELSE 'OK'
    END AS data_quality_status,
    ms.status_code_clean,
    analytics.clean_code(h.place) IS NULL
        OR ml.location_value_clean IS NOT NULL AS is_place_found
FROM source h
LEFT JOIN work_orders wo ON wo.wo_code_clean = h.wo_code_clean
LEFT JOIN analytics.master_work_status_lookup ms ON ms.status_value_clean = h.status_clean
LEFT JOIN analytics.master_location_lookup ml
    ON ml.location_value_clean = analytics.clean_code(h.place);
