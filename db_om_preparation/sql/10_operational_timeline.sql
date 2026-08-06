-- Interpretasi event untuk kebutuhan analisis/model. Tabel dan clean view sumber
-- tidak diubah. Timeline audit tetap tersedia di item_journey_clean.

-- Aman saat file ini dijalankan ulang secara mandiri.
DROP VIEW IF EXISTS analytics.eda_location_lifecycle_summary;
DROP VIEW IF EXISTS analytics.eda_location_lifecycle_detail;
DROP VIEW IF EXISTS analytics.eda_daily_activity_anomaly;
DROP VIEW IF EXISTS analytics.eda_item_location_installation_summary;
DROP VIEW IF EXISTS analytics.eda_activity_calendar_summary;
DROP VIEW IF EXISTS analytics.eda_location_activity_summary;
DROP VIEW IF EXISTS analytics.eda_item_activity_summary;
DROP VIEW IF EXISTS analytics.eda_outlier_summary;
DROP VIEW IF EXISTS analytics.eda_incomplete_failure_summary;
DROP VIEW IF EXISTS analytics.eda_incomplete_failure_detail;
DROP VIEW IF EXISTS analytics.failure_outcome_missing_onset_review;
DROP MATERIALIZED VIEW IF EXISTS analytics.failure_event_flow;
DROP VIEW IF EXISTS analytics.failure_event_flow_live;
DROP MATERIALIZED VIEW IF EXISTS analytics.item_journey_operational_timeline;
DROP VIEW IF EXISTS analytics.item_journey_operational_timeline_live;
DROP MATERIALIZED VIEW IF EXISTS analytics.item_journey_semantic;
DROP VIEW IF EXISTS analytics.item_journey_semantic_live;

CREATE OR REPLACE VIEW analytics.item_journey_semantic_live AS
WITH work_order_context AS (
    SELECT DISTINCT ON (analytics.clean_code(wo.wo_code))
        analytics.clean_code(wo.wo_code) AS wo_code_clean,
        COALESCE(
            analytics.clean_code(mwt.work_type),
            analytics.clean_code(wo.work_type_code)
        ) AS work_order_type_clean
    FROM journal.t_work_order wo
    LEFT JOIN master.t_mtr_work_type mwt
        ON analytics.clean_code(mwt.work_type_code)
            = analytics.clean_code(wo.work_type_code)
        OR analytics.clean_code(mwt.work_type)
            = analytics.clean_code(wo.work_type_code)
    WHERE analytics.clean_code(wo.wo_code) IS NOT NULL
    ORDER BY analytics.clean_code(wo.wo_code), wo.wo_id DESC
),
classified AS (
    SELECT
        e.*,
        woc.work_order_type_clean,
        f.journey_id IS NOT NULL AS is_confirmed_failure_onset,
        f.event_label_basis AS confirmed_failure_basis,
        COUNT(*) OVER (
            PARTITION BY e.created_on::date, e.status_clean,
                e.activity_clean, e.place_clean
        ) >= 100 AS is_bulk_activity_context,
        (
            COALESCE(e.wo_type_clean = 'RECON', FALSE)
            OR COALESCE(woc.work_order_type_clean = 'RECON', FALSE)
            OR COALESCE(
                e.status_clean = 'DISMANTLED' AND e.activity_clean = 'RECON',
                FALSE
            )
            OR COALESCE(
                e.status_clean = 'INSTALLED'
                AND (
                    e.done_by_clean LIKE '%RECON%'
                    OR UPPER(COALESCE(e.remark, '')) LIKE '%RECON%'
                ),
                FALSE
            )
        ) AS is_admin_recon_context,
        (
            e.created_on IS NOT NULL
            AND e.created_on::date >= DATE '1971-01-01'
            AND e.created_on <= CURRENT_TIMESTAMP
        ) AS is_valid_operational_date
    FROM analytics.item_journey_event_cache e
    LEFT JOIN work_order_context woc
        ON woc.wo_code_clean = e.wo_code_clean
    LEFT JOIN analytics.failure_event_clean f
        ON f.journey_id = e.journey_id
)
SELECT
    c.*,
    CASE
        WHEN c.created_on IS NULL
          OR c.created_on::date < DATE '1971-01-01'
          OR c.created_on > CURRENT_TIMESTAMP
            THEN 'INVALID_DATE'
        WHEN c.created_on < TIMESTAMP '2025-01-01'
            THEN 'LEGACY_2013_2024'
        ELSE 'DETAILED_REPAIR_2025_PLUS'
    END AS data_era,
    CASE
        WHEN c.is_admin_recon_context THEN 'ADMIN_RECON'
        WHEN c.status_clean = 'OK'
          AND c.activity_clean = 'RECEPTION'
          AND c.is_bulk_activity_context
            THEN 'BULK_WAREHOUSE_RECEPTION'
        WHEN c.status_clean = 'OK' AND c.activity_clean = 'RECEPTION'
            THEN 'WAREHOUSE_RECEPTION'
        WHEN c.is_confirmed_failure_onset
            THEN 'FAILURE_ONSET'
        WHEN c.status_clean = 'DISMANTLED' AND c.wo_type_clean = 'DISMANTLE'
            THEN 'RELOCATION'
        WHEN c.status_clean IN (
            'SENDREP', 'RECEIVE', 'CHECKING', 'NEED REPAIR', 'REPAIRING',
            'HOLD', 'WAITING', 'POSTPONED'
        ) THEN 'REPAIR_PROCESS'
        WHEN c.status_clean IN ('UNREPAIRABLE', 'BROKEN', 'SENDLOG (BROKEN)')
            THEN 'FAILURE_OUTCOME'
        WHEN c.status_clean = 'REPAIRED' THEN 'REPAIR_COMPLETED'
        WHEN c.status_clean = 'RETURNED' THEN 'RETURN_FLOW'
        WHEN c.wo_type_clean = 'PREVENTIVE' THEN 'PREVENTIVE'
        ELSE 'NORMAL_OPERATION'
    END AS event_semantic,
    NOT c.is_admin_recon_context AS is_non_recon_event,
    c.is_valid_operational_date AND NOT c.is_admin_recon_context
        AS is_operational_event,
    c.is_confirmed_failure_onset AS is_failure_onset,
    COALESCE(
        c.status_clean = 'DISMANTLED' AND c.wo_type_clean = 'DISMANTLE',
        FALSE
    )
        AS is_relocation_event,
    c.is_valid_operational_date AND NOT c.is_admin_recon_context
        AS is_trusted_event_time
FROM classified c;

CREATE MATERIALIZED VIEW analytics.item_journey_semantic AS
SELECT * FROM analytics.item_journey_semantic_live;

CREATE INDEX item_journey_semantic_item_date_idx
    ON analytics.item_journey_semantic (item_identifier_clean, created_on, journey_id);

CREATE INDEX item_journey_semantic_type_date_idx
    ON analytics.item_journey_semantic (event_semantic, created_on);

CREATE INDEX item_journey_semantic_era_idx
    ON analytics.item_journey_semantic (data_era, event_semantic);

-- Timeline ini hanya memakai waktu yang layak secara operasional. RECON tetap
-- tersimpan di semantic/audit layer, tetapi tidak memengaruhi LAG/LEAD/durasi.
CREATE OR REPLACE VIEW analytics.item_journey_operational_timeline_live AS
SELECT
    s.*,
    ROW_NUMBER() OVER operational_order AS operational_sequence_number,
    LAG(s.status_clean) OVER operational_order AS previous_operational_status_clean,
    LEAD(s.status_clean) OVER operational_order AS next_operational_status_clean,
    LAG(s.activity_clean) OVER operational_order AS previous_operational_activity_clean,
    LEAD(s.activity_clean) OVER operational_order AS next_operational_activity_clean,
    LAG(s.event_semantic) OVER operational_order AS previous_event_semantic,
    LEAD(s.event_semantic) OVER operational_order AS next_event_semantic,
    LAG(s.place_canonical_clean) OVER operational_order
        AS previous_operational_place_clean,
    LEAD(s.place_canonical_clean) OVER operational_order
        AS next_operational_place_clean,
    LAG(s.created_on) OVER operational_order AS previous_operational_created_on,
    LEAD(s.created_on) OVER operational_order AS next_operational_created_on
FROM analytics.item_journey_semantic s
WHERE s.is_operational_event
WINDOW operational_order AS (
    PARTITION BY s.item_identifier_clean
    ORDER BY s.created_on, s.journey_id
);

CREATE MATERIALIZED VIEW analytics.item_journey_operational_timeline AS
SELECT
    t.*,
    EXTRACT(EPOCH FROM (t.created_on - t.previous_operational_created_on)) / 86400.0
        AS days_since_previous_operational_event,
    EXTRACT(EPOCH FROM (t.next_operational_created_on - t.created_on)) / 86400.0
        AS days_to_next_operational_event
FROM analytics.item_journey_operational_timeline_live t;

CREATE INDEX item_journey_operational_item_date_idx
    ON analytics.item_journey_operational_timeline (
        item_identifier_clean, created_on, journey_id
    );

CREATE INDEX item_journey_operational_status_idx
    ON analytics.item_journey_operational_timeline (
        item_identifier_clean, status_clean, created_on, journey_id
    );

CREATE INDEX item_journey_operational_semantic_idx
    ON analytics.item_journey_operational_timeline (event_semantic, created_on);

-- Konfirmasi flow setelah onset. RETURN adalah ekspektasi proses, tetapi record
-- tanpa RETURN tidak diubah menjadi non-failure; statusnya open/incomplete.
CREATE OR REPLACE VIEW analytics.failure_event_flow_live AS
WITH boundaries AS (
    SELECT
        f.*,
        onset.previous_operational_status_clean,
        onset.previous_operational_activity_clean,
        onset.previous_operational_created_on,
        onset.days_since_previous_operational_event,
        next_install.journey_id AS next_installed_journey_id,
        next_install.created_on AS next_installed_on,
        next_failure.journey_id AS next_failure_journey_id,
        next_failure.failure_onset_on AS next_failure_onset_on,
        CASE
            WHEN next_install.created_on IS NULL THEN next_failure.failure_onset_on
            WHEN next_failure.failure_onset_on IS NULL THEN next_install.created_on
            ELSE LEAST(next_install.created_on, next_failure.failure_onset_on)
        END AS cycle_boundary_on
    FROM analytics.failure_event_clean f
    LEFT JOIN analytics.item_journey_operational_timeline onset
        ON onset.journey_id = f.journey_id
    LEFT JOIN LATERAL (
        SELECT o.journey_id, o.created_on
        FROM analytics.item_journey_operational_timeline o
        WHERE o.item_identifier_clean = f.item_identifier_clean
          AND o.status_clean = 'INSTALLED'
          AND (
              o.created_on > f.failure_onset_on
              OR (o.created_on = f.failure_onset_on AND o.journey_id > f.journey_id)
          )
        ORDER BY o.created_on, o.journey_id
        LIMIT 1
    ) next_install ON TRUE
    LEFT JOIN LATERAL (
        SELECT n.journey_id, n.failure_onset_on
        FROM analytics.failure_event_clean n
        WHERE n.item_identifier_clean = f.item_identifier_clean
          AND (
              n.failure_onset_on > f.failure_onset_on
              OR (n.failure_onset_on = f.failure_onset_on AND n.journey_id > f.journey_id)
          )
        ORDER BY n.failure_onset_on, n.journey_id
        LIMIT 1
    ) next_failure ON TRUE
),
followup AS (
    SELECT
        b.*,
        returned.created_on AS next_returned_on,
        repair_process.status_clean AS next_repair_process_status,
        repair_process.created_on AS next_repair_process_on,
        outcome.status_clean AS next_failure_outcome_status,
        outcome.created_on AS next_failure_outcome_on
    FROM boundaries b
    LEFT JOIN LATERAL (
        SELECT o.created_on
        FROM analytics.item_journey_operational_timeline o
        WHERE o.item_identifier_clean = b.item_identifier_clean
          AND o.status_clean = 'RETURNED'
          AND o.created_on >= b.failure_onset_on
          AND (b.cycle_boundary_on IS NULL OR o.created_on <= b.cycle_boundary_on)
        ORDER BY o.created_on, o.journey_id
        LIMIT 1
    ) returned ON TRUE
    LEFT JOIN LATERAL (
        SELECT o.status_clean, o.created_on
        FROM analytics.item_journey_operational_timeline o
        WHERE o.item_identifier_clean = b.item_identifier_clean
          AND o.event_semantic = 'REPAIR_PROCESS'
          AND o.created_on >= b.failure_onset_on
          AND (b.cycle_boundary_on IS NULL OR o.created_on <= b.cycle_boundary_on)
        ORDER BY o.created_on, o.journey_id
        LIMIT 1
    ) repair_process ON TRUE
    LEFT JOIN LATERAL (
        SELECT o.status_clean, o.created_on
        FROM analytics.item_journey_operational_timeline o
        WHERE o.item_identifier_clean = b.item_identifier_clean
          AND o.event_semantic IN ('FAILURE_OUTCOME', 'REPAIR_COMPLETED')
          AND o.created_on >= b.failure_onset_on
          AND (b.cycle_boundary_on IS NULL OR o.created_on <= b.cycle_boundary_on)
        ORDER BY o.created_on, o.journey_id
        LIMIT 1
    ) outcome ON TRUE
)
SELECT
    f.*,
    CASE
        WHEN f.failure_onset_on < TIMESTAMP '2025-01-01'
            THEN 'LEGACY_2013_2024'
        ELSE 'DETAILED_REPAIR_2025_PLUS'
    END AS data_era,
    EXTRACT(EPOCH FROM (f.next_returned_on - f.failure_onset_on)) / 86400.0
        AS days_to_return,
    CASE
        WHEN f.next_returned_on IS NOT NULL
         AND f.next_returned_on <= f.failure_onset_on + INTERVAL '30 days'
            THEN 'CONFIRMED_RETURN_30D'
        WHEN f.next_returned_on IS NOT NULL
            THEN 'CONFIRMED_RETURN_LATE'
        WHEN f.next_repair_process_on IS NOT NULL
            THEN 'CONFIRMED_REPAIR_PROCESS_NO_RETURN'
        WHEN f.next_failure_outcome_on IS NOT NULL
            THEN 'CONFIRMED_OUTCOME_NO_RETURN'
        ELSE 'OPEN_OR_INCOMPLETE_FLOW'
    END AS flow_confirmation_status,
    (
        f.next_returned_on IS NOT NULL
        OR f.next_repair_process_on IS NOT NULL
        OR f.next_failure_outcome_on IS NOT NULL
    ) AS is_flow_confirmed
FROM followup f;

CREATE MATERIALIZED VIEW analytics.failure_event_flow AS
SELECT * FROM analytics.failure_event_flow_live;

CREATE INDEX failure_event_flow_status_idx
    ON analytics.failure_event_flow (flow_confirmation_status, failure_onset_on);

CREATE INDEX failure_event_flow_item_date_idx
    ON analytics.failure_event_flow (item_identifier_clean, failure_onset_on);

-- Satu entry point refresh dengan urutan dependency yang benar.
CREATE OR REPLACE PROCEDURE analytics.refresh_cached_views()
LANGUAGE plpgsql
AS $refresh$
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
END;
$refresh$;

SELECT event_semantic, COUNT(*) AS event_count
FROM analytics.item_journey_semantic
GROUP BY event_semantic
ORDER BY event_count DESC;

SELECT data_era, flow_confirmation_status, COUNT(*) AS failure_count
FROM analytics.failure_event_flow
GROUP BY data_era, flow_confirmation_status
ORDER BY data_era, failure_count DESC;
