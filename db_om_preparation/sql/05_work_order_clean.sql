CREATE OR REPLACE VIEW analytics.work_order_clean AS
WITH latest_history_raw AS (
    SELECT DISTINCT ON (analytics.clean_code(h.wo_code))
        analytics.clean_code(h.wo_code) AS wo_code_clean,
        analytics.clean_code(h.status) AS latest_status_clean,
        h.created_on AS latest_history_created_on
    FROM journal.t_work_order_history h
    WHERE analytics.clean_code(h.wo_code) IS NOT NULL
    ORDER BY
        analytics.clean_code(h.wo_code),
        h.created_on DESC NULLS LAST,
        h.wo_history_id DESC
),
latest_history AS (
    SELECT
        h.*,
        s.status_code_clean AS latest_status_code_clean
    FROM latest_history_raw h
    LEFT JOIN analytics.master_work_status_lookup s
        ON s.status_value_clean = h.latest_status_clean
),
master_work_type AS (
    SELECT DISTINCT work_type_value_clean
    FROM master.t_mtr_work_type w
    CROSS JOIN LATERAL (VALUES
        (analytics.clean_code(w.work_type_code)),
        (analytics.clean_code(w.work_type))
    ) value(work_type_value_clean)
    WHERE work_type_value_clean IS NOT NULL
)
SELECT
    wo.wo_id,
    wo.work_type_code AS work_type_code_original,
    analytics.clean_code(wo.work_type_code) AS work_type_code_clean,
    wo.wo_code AS wo_code_original,
    analytics.clean_code(wo.wo_code) AS wo_code_clean,
    wo.ref_doc_code AS ref_doc_code_original,
    analytics.clean_code(wo.ref_doc_code) AS ref_doc_code_clean,
    wo.location AS location_original,
    analytics.clean_code(wo.location) AS location_clean,
    wo.ro_code AS ro_code_original,
    analytics.clean_code(wo.ro_code) AS ro_code_clean,
    wo.current_status AS current_status_original,
    analytics.clean_code(wo.current_status) AS current_status_clean,
    wo.start_date,
    wo.due_date,
    wo.created_on,
    wo.updated_on,
    wo.is_active,
    lh.latest_status_clean,
    lh.latest_history_created_on,
    lh.wo_code_clean IS NOT NULL AS has_work_order_history,
    lh.wo_code_clean IS NULL
        OR (
            current_status_master.status_code_clean IS NOT NULL
            AND lh.latest_status_code_clean IS NOT NULL
            AND current_status_master.status_code_clean = lh.latest_status_code_clean
        ) AS is_current_status_consistent,
    wo.start_date IS NOT NULL
        AND wo.due_date IS NOT NULL
        AND wo.start_date <= wo.due_date AS is_due_date_valid,
    wo.created_on IS NOT NULL
        AND wo.created_on::date >= DATE '1971-01-01'
        AND (wo.updated_on IS NULL OR wo.created_on <= wo.updated_on)
        AND (wo.start_date IS NULL OR wo.due_date IS NULL OR wo.start_date <= wo.due_date)
        AS is_valid_date,
    wo.created_on > CURRENT_TIMESTAMP
        OR wo.start_date > CURRENT_DATE
        OR wo.due_date > CURRENT_DATE AS is_future_date,
    wo.created_on IS NULL
        OR wo.created_on::date < DATE '1971-01-01'
        OR (wo.updated_on IS NOT NULL AND wo.created_on > wo.updated_on)
        OR (wo.start_date IS NOT NULL AND wo.due_date IS NOT NULL
            AND wo.start_date > wo.due_date) AS is_suspicious_date,
    current_status_master.status_code_clean IS NOT NULL AS is_status_found,
    mwt.work_type_value_clean IS NOT NULL AS is_work_type_found,
    CASE
        WHEN wo.wo_id IS NULL OR analytics.clean_code(wo.wo_code) IS NULL THEN 'CRITICAL'
        WHEN lh.wo_code_clean IS NULL
          OR NOT (
              current_status_master.status_code_clean IS NOT NULL
              AND lh.latest_status_code_clean IS NOT NULL
              AND current_status_master.status_code_clean = lh.latest_status_code_clean
          )
          OR NOT (wo.start_date IS NOT NULL AND wo.due_date IS NOT NULL
                  AND wo.start_date <= wo.due_date)
          OR current_status_master.status_code_clean IS NULL
          OR mwt.work_type_value_clean IS NULL
          OR (analytics.clean_code(wo.location) IS NOT NULL
              AND ml.location_value_clean IS NULL)
        THEN 'WARNING'
        ELSE 'OK'
    END AS data_quality_status,
    current_status_master.status_code_clean AS current_status_code_clean,
    lh.latest_status_code_clean,
    lh.latest_status_clean IS NULL
        OR lh.latest_status_code_clean IS NOT NULL AS is_latest_status_found,
    analytics.clean_code(wo.location) IS NULL
        OR ml.location_value_clean IS NOT NULL AS is_location_found
FROM journal.t_work_order wo
LEFT JOIN latest_history lh
    ON lh.wo_code_clean = analytics.clean_code(wo.wo_code)
LEFT JOIN analytics.master_work_status_lookup current_status_master
    ON current_status_master.status_value_clean = analytics.clean_code(wo.current_status)
LEFT JOIN master_work_type mwt
    ON mwt.work_type_value_clean = analytics.clean_code(wo.work_type_code)
LEFT JOIN analytics.master_location_lookup ml
    ON ml.location_value_clean = analytics.clean_code(wo.location);
