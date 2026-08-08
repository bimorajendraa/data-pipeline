-- Daftar validasi status lintas tabel. Nilai yang tidak ditemukan hanya ditandai,
-- tidak dipetakan otomatis ke arti bisnis tertentu.
CREATE OR REPLACE VIEW analytics.status_validation AS
WITH source_status AS (
    SELECT
        'journal.t_item_journey'::text AS source_table,
        'INVENTORY'::text AS expected_status_type,
        status::text AS original_status
    FROM journal.t_item_journey
    UNION ALL
    SELECT 'inventory.t_item', 'INVENTORY', status::text FROM inventory.t_item
    UNION ALL
    SELECT 'journal.t_work_order', 'WORK', current_status::text FROM journal.t_work_order
    UNION ALL
    SELECT 'journal.t_work_order_history', 'WORK', status::text FROM journal.t_work_order_history
),
status_count AS (
    SELECT
        source_table,
        expected_status_type,
        original_status,
        analytics.clean_code(original_status) AS status_clean,
        COUNT(*) AS row_count
    FROM source_status
    GROUP BY source_table, expected_status_type, original_status
),
master_status AS (
    SELECT
        status_code::text AS status_code,
        status_name::text AS status_name,
        analytics.clean_code(status_type) AS status_type_clean
    FROM master.t_mtr_status
)
SELECT
    sc.source_table,
    sc.original_status,
    sc.status_clean,
    sc.row_count,
    ms.status_code AS matched_status_code,
    ms.status_name AS matched_status_name,
    ms.status_code IS NOT NULL AS is_status_found,
    CASE
        WHEN sc.status_clean IS NULL THEN 'EMPTY'
        WHEN sc.original_status = ms.status_code OR sc.original_status = ms.status_name
            THEN 'EXACT'
        WHEN ms.status_code IS NOT NULL THEN 'NORMALIZED_CASE_OR_SPACE'
        ELSE 'NOT_FOUND_REVIEW_CANDIDATE'
    END AS match_type,
    sc.expected_status_type
FROM status_count sc
LEFT JOIN LATERAL (
    SELECT m.status_code, m.status_name
    FROM master_status m
    WHERE m.status_type_clean = sc.expected_status_type
      AND (
          analytics.clean_code(m.status_code) = sc.status_clean
          OR analytics.clean_code(m.status_name) = sc.status_clean
      )
    ORDER BY
        CASE WHEN sc.original_status = m.status_code OR sc.original_status = m.status_name
             THEN 0 ELSE 1 END,
        m.status_code
    LIMIT 1
) ms ON TRUE;

CREATE OR REPLACE VIEW analytics.data_quality_summary_live AS
WITH
ij AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(*) FILTER (WHERE is_missing_item_identifier) AS missing_identifier,
        COUNT(*) FILTER (WHERE item_model_code_clean IS NULL) AS missing_model,
        COUNT(*) FILTER (WHERE is_valid_date IS NOT TRUE) AS invalid_date,
        COUNT(*) FILTER (WHERE is_future_date) AS future_date,
        COUNT(*) FILTER (WHERE is_duplicate_journey_id) AS duplicate_id,
        COUNT(*) FILTER (WHERE item_model_code_clean IS NOT NULL AND NOT is_item_model_found) AS model_not_found,
        COUNT(*) FILTER (WHERE wo_code_clean IS NOT NULL AND NOT is_work_order_found) AS wo_not_found,
        COUNT(*) FILTER (WHERE status_clean IS NOT NULL AND NOT is_status_found) AS status_not_found,
        COUNT(*) FILTER (WHERE place_clean IS NOT NULL AND NOT is_place_found) AS location_not_found,
        COUNT(*) FILTER (WHERE client_clean IS NOT NULL AND NOT is_client_found) AS client_not_found,
        COUNT(*) FILTER (WHERE wo_type_clean IS NOT NULL AND NOT is_work_type_found) AS work_type_not_found,
        COUNT(*) FILTER (WHERE is_work_type_consistent IS FALSE) AS work_type_inconsistent,
        COUNT(*) FILTER (WHERE is_item_found IS NOT TRUE AND NOT is_missing_item_identifier) AS item_not_found,
        COUNT(*) FILTER (WHERE is_item_found AND is_item_model_consistent IS NOT TRUE) AS model_inconsistent
    FROM analytics.item_journey_clean
),
item AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(*) FILTER (WHERE is_missing_item_identifier) AS missing_identifier,
        COUNT(*) FILTER (WHERE item_model_code_clean IS NULL) AS missing_model,
        COUNT(*) FILTER (WHERE item_model_code_clean IS NOT NULL AND NOT is_item_model_found) AS model_not_found,
        COUNT(*) FILTER (WHERE location_code_clean IS NOT NULL AND NOT is_location_found) AS location_not_found,
        COUNT(*) FILTER (WHERE status_clean IS NOT NULL AND NOT is_status_found) AS status_not_found,
        COUNT(*) FILTER (WHERE is_valid_date IS NOT TRUE) AS invalid_date,
        COUNT(*) FILTER (WHERE is_future_date) AS future_date
    FROM analytics.item_clean
),
wo AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(*) FILTER (WHERE wo_code_clean IS NULL) AS missing_code,
        COUNT(*) FILTER (WHERE NOT has_work_order_history) AS missing_history,
        COUNT(*) FILTER (WHERE is_current_status_consistent IS NOT TRUE) AS inconsistent_status,
        COUNT(*) FILTER (WHERE is_due_date_valid IS NOT TRUE) AS invalid_due_date,
        COUNT(*) FILTER (WHERE is_valid_date IS NOT TRUE) AS invalid_date,
        COUNT(*) FILTER (WHERE is_future_date) AS future_date,
        COUNT(*) FILTER (WHERE current_status_clean IS NOT NULL AND NOT is_status_found) AS status_not_found,
        COUNT(*) FILTER (WHERE latest_status_clean IS NOT NULL AND NOT is_latest_status_found) AS latest_status_not_found,
        COUNT(*) FILTER (WHERE work_type_code_clean IS NOT NULL AND NOT is_work_type_found) AS work_type_not_found,
        COUNT(*) FILTER (WHERE location_clean IS NOT NULL AND NOT is_location_found) AS location_not_found
    FROM analytics.work_order_clean
),
woh AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(*) FILTER (WHERE NOT is_work_order_found) AS wo_not_found,
        COUNT(*) FILTER (WHERE status_clean IS NOT NULL AND NOT is_status_found) AS status_not_found,
        COUNT(*) FILTER (WHERE is_valid_date IS NOT TRUE) AS invalid_date,
        COUNT(*) FILTER (WHERE is_future_date) AS future_date,
        COUNT(*) FILTER (WHERE is_activity_sequence_valid IS NOT TRUE) AS invalid_sequence,
        COUNT(*) FILTER (WHERE place_clean IS NOT NULL AND NOT is_place_found) AS location_not_found
    FROM analytics.work_order_history_clean
),
mtbf AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(*) FILTER (WHERE is_missing_item_identifier) AS missing_identifier,
        COUNT(*) FILTER (WHERE time_operation < 0) AS negative_time,
        COUNT(*) FILTER (WHERE is_item_model_found IS NOT TRUE) AS model_not_found,
        COUNT(*) FILTER (WHERE is_client_found IS NOT TRUE) AS client_not_found,
        COUNT(*) FILTER (WHERE is_location_found IS NOT TRUE) AS location_not_found,
        COUNT(*) FILTER (WHERE is_active_valid IS NOT TRUE) AS invalid_active,
        COUNT(*) FILTER (WHERE is_repair_valid IS NOT TRUE) AS invalid_repair,
        COUNT(*) FILTER (WHERE is_item_model_ambiguous) AS ambiguous_model,
        COUNT(*) FILTER (WHERE is_valid_date IS NOT TRUE) AS invalid_date,
        COUNT(*) FILTER (WHERE is_future_date) AS future_date
    FROM analytics.mtbf_clean
),
checks(table_name, quality_check, total_rows, failed_rows, severity, description) AS (
    SELECT 'journal.t_item_journey', v.* FROM ij CROSS JOIN LATERAL (VALUES
        ('missing item identifier', ij.total_rows, ij.missing_identifier, 'WARNING', 'Pairing code dan host serial sama-sama kosong'),
        ('missing item model', ij.total_rows, ij.missing_model, 'WARNING', 'Item model kosong setelah normalisasi'),
        ('invalid date', ij.total_rows, ij.invalid_date, 'WARNING', 'Created_on kosong atau tanggal tidak valid'),
        ('future date', ij.total_rows, ij.future_date, 'WARNING', 'Created_on berada di masa depan'),
        ('duplicate journey ID', ij.total_rows, ij.duplicate_id, 'CRITICAL', 'Journey ID digunakan lebih dari satu baris'),
        ('item model not found', ij.total_rows, ij.model_not_found, 'WARNING', 'Item model tidak ditemukan pada master item'),
        ('work order not found', ij.total_rows, ij.wo_not_found, 'WARNING', 'WO code terisi tetapi tidak ditemukan pada work order'),
        ('status not found', ij.total_rows, ij.status_not_found, 'INFO', 'Status tidak ditemukan pada master status'),
        ('location not found', ij.total_rows, ij.location_not_found, 'INFO', 'Place tidak cocok dengan kode maupun nama lokasi master'),
        ('client not found', ij.total_rows, ij.client_not_found, 'INFO', 'Client tidak cocok dengan kode maupun nama client master'),
        ('work type not found', ij.total_rows, ij.work_type_not_found, 'INFO', 'WO type tidak cocok dengan kode maupun nama work type master'),
        ('work type inconsistent', ij.total_rows, ij.work_type_inconsistent, 'WARNING', 'WO type journey berbeda dengan canonical work type pada work order'),
        ('item identifier not found', ij.total_rows, ij.item_not_found, 'WARNING', 'Identifier terisi tetapi tidak ditemukan pada inventory'),
        ('item model inconsistent', ij.total_rows, ij.model_inconsistent, 'WARNING', 'Identifier ditemukan dengan model item berbeda')
    ) v(quality_check, total_rows, failed_rows, severity, description)
    UNION ALL
    SELECT 'inventory.t_item', v.* FROM item CROSS JOIN LATERAL (VALUES
        ('missing item identifier', item.total_rows, item.missing_identifier, 'WARNING', 'Pairing code dan SN reference sama-sama kosong'),
        ('missing item model', item.total_rows, item.missing_model, 'WARNING', 'Item model kosong setelah normalisasi'),
        ('item model not found', item.total_rows, item.model_not_found, 'WARNING', 'Item model tidak ditemukan pada master item'),
        ('location not found', item.total_rows, item.location_not_found, 'WARNING', 'Location code tidak ditemukan pada master lokasi'),
        ('status not found', item.total_rows, item.status_not_found, 'INFO', 'Status tidak ditemukan pada master status'),
        ('invalid date', item.total_rows, item.invalid_date, 'WARNING', 'Received date kosong, terlalu lama, atau urutan tanggal salah'),
        ('future date', item.total_rows, item.future_date, 'WARNING', 'Salah satu tanggal berada di masa depan')
    ) v(quality_check, total_rows, failed_rows, severity, description)
    UNION ALL
    SELECT 'journal.t_work_order', v.* FROM wo CROSS JOIN LATERAL (VALUES
        ('missing work order code', wo.total_rows, wo.missing_code, 'CRITICAL', 'WO code kosong setelah normalisasi'),
        ('missing work order history', wo.total_rows, wo.missing_history, 'WARNING', 'Work order tidak memiliki history'),
        ('current status inconsistent', wo.total_rows, wo.inconsistent_status, 'WARNING', 'Current status berbeda dengan status history terakhir'),
        ('invalid due date', wo.total_rows, wo.invalid_due_date, 'WARNING', 'Start date/due date kosong atau start date melewati due date'),
        ('invalid date', wo.total_rows, wo.invalid_date, 'WARNING', 'Tanggal kosong, terlalu lama, atau urutannya salah'),
        ('future date', wo.total_rows, wo.future_date, 'WARNING', 'Salah satu tanggal berada di masa depan'),
        ('status not found', wo.total_rows, wo.status_not_found, 'INFO', 'Current status tidak ditemukan pada master status'),
        ('latest status not found', wo.total_rows, wo.latest_status_not_found, 'INFO', 'Status history terakhir tidak ditemukan pada master status WORK'),
        ('work type not found', wo.total_rows, wo.work_type_not_found, 'INFO', 'Work type tidak ditemukan pada master work type'),
        ('location not found', wo.total_rows, wo.location_not_found, 'INFO', 'Lokasi WO tidak ditemukan pada master lokasi')
    ) v(quality_check, total_rows, failed_rows, severity, description)
    UNION ALL
    SELECT 'journal.t_work_order_history', v.* FROM woh CROSS JOIN LATERAL (VALUES
        ('work order not found', woh.total_rows, woh.wo_not_found, 'WARNING', 'History memiliki WO code yang tidak ditemukan pada work order'),
        ('status not found', woh.total_rows, woh.status_not_found, 'INFO', 'Status tidak ditemukan pada master status'),
        ('invalid date', woh.total_rows, woh.invalid_date, 'WARNING', 'Created_on kosong atau tidak valid'),
        ('future date', woh.total_rows, woh.future_date, 'WARNING', 'Created_on berada di masa depan'),
        ('invalid activity sequence', woh.total_rows, woh.invalid_sequence, 'WARNING', 'Urutan waktu aktivitas berdasarkan history ID tidak konsisten'),
        ('location not found', woh.total_rows, woh.location_not_found, 'INFO', 'Place tidak cocok dengan kode maupun nama lokasi master')
    ) v(quality_check, total_rows, failed_rows, severity, description)
    UNION ALL
    SELECT 'journal.t_mtbf', v.* FROM mtbf CROSS JOIN LATERAL (VALUES
        ('missing item identifier', mtbf.total_rows, mtbf.missing_identifier, 'WARNING', 'SN reference kosong'),
        ('negative time operation', mtbf.total_rows, mtbf.negative_time, 'CRITICAL', 'Time operation bernilai negatif'),
        ('item model not found', mtbf.total_rows, mtbf.model_not_found, 'WARNING', 'Item model tidak ditemukan pada master item'),
        ('client not found', mtbf.total_rows, mtbf.client_not_found, 'INFO', 'Client tidak ditemukan pada master client'),
        ('location not found', mtbf.total_rows, mtbf.location_not_found, 'WARNING', 'Lokasi tidak ditemukan pada master lokasi'),
        ('invalid is_active', mtbf.total_rows, mtbf.invalid_active, 'INFO', 'Is_active bukan 0 atau 1'),
        ('invalid is_repair', mtbf.total_rows, mtbf.invalid_repair, 'INFO', 'Is_repair bukan 0 atau 1'),
        ('ambiguous item model', mtbf.total_rows, mtbf.ambiguous_model, 'WARNING', 'Nama model cocok dengan lebih dari satu model code master'),
        ('invalid date', mtbf.total_rows, mtbf.invalid_date, 'WARNING', 'Created_on kosong atau tidak valid'),
        ('future date', mtbf.total_rows, mtbf.future_date, 'WARNING', 'Created_on berada di masa depan')
    ) v(quality_check, total_rows, failed_rows, severity, description)
)
SELECT
    table_name,
    quality_check,
    total_rows,
    failed_rows,
    ROUND(100.0 * failed_rows / NULLIF(total_rows, 0), 2) AS failed_percentage,
    severity,
    description
FROM checks;

DO $migration$
DECLARE
    object_kind "char";
BEGIN
    SELECT c.relkind
    INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'data_quality_summary';

    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.data_quality_summary';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.data_quality_summary';
    END IF;
END;
$migration$;

CREATE MATERIALIZED VIEW analytics.data_quality_summary AS
SELECT * FROM analytics.data_quality_summary_live;

CREATE INDEX data_quality_summary_lookup_idx
    ON analytics.data_quality_summary (severity, table_name, quality_check);

-- Satu entry point untuk refresh cache setelah data sumber berubah. Urutan
-- menjaga report turunan diperbarui setelah seluruh sumbernya tersedia.
CREATE OR REPLACE PROCEDURE analytics.refresh_cached_views()
LANGUAGE plpgsql
AS $refresh$
BEGIN
    REFRESH MATERIALIZED VIEW analytics.data_profile;
    REFRESH MATERIALIZED VIEW analytics.item_journey_transition_profile;
    REFRESH MATERIALIZED VIEW analytics.data_quality_summary;
END;
$refresh$;

-- Cleanup objek analytics dari versi pipeline lama. Tabel sumber
-- journal.t_mttr tidak diubah atau dihapus.
DROP VIEW IF EXISTS analytics.mttr_clean;

-- Ringkasan utama merupakan cache dan cepat dibaca. Jika tabel sumber berubah,
-- jalankan: CALL analytics.refresh_cached_views();
-- SELECT *
-- FROM analytics.data_quality_summary
-- ORDER BY
--     CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
--     failed_percentage DESC NULLS LAST,
--     table_name,
--     quality_check;

-- Contoh drill-down record gagal (jalankan sesuai kebutuhan):
-- SELECT * FROM analytics.item_journey_clean WHERE data_quality_status <> 'OK';
-- SELECT * FROM analytics.work_order_clean WHERE data_quality_status <> 'OK';
-- SELECT * FROM analytics.status_validation WHERE match_type = 'NOT_FOUND_REVIEW_CANDIDATE';
