-- EDA journal lengkap: kualitas, univariat, hubungan item-lokasi/waktu,
-- lifecycle pada lokasi yang sama, dan lonjakan aktivitas.
DROP VIEW IF EXISTS analytics.eda_location_lifecycle_summary;
DROP VIEW IF EXISTS analytics.eda_location_lifecycle_detail;
DROP VIEW IF EXISTS analytics.eda_daily_activity_anomaly;
DROP VIEW IF EXISTS analytics.eda_item_location_installation_summary;
DROP VIEW IF EXISTS analytics.eda_activity_calendar_summary;
DROP VIEW IF EXISTS analytics.eda_location_activity_summary;
DROP VIEW IF EXISTS analytics.eda_item_activity_summary;
DROP VIEW IF EXISTS analytics.eda_cleaning_review_detail;
DROP VIEW IF EXISTS analytics.eda_journey_quality_summary;

CREATE OR REPLACE VIEW analytics.eda_journey_quality_summary AS
WITH exact_duplicate_group AS (
    SELECT COUNT(*) AS row_count
    FROM analytics.item_journey_clean
    GROUP BY item_identifier_clean, created_on, item_category_clean,
        item_type_clean, item_model_code_clean, client_clean,
        ref_doc_code_clean, wo_type_clean, wo_code_clean, place_clean,
        activity_clean, status_clean, done_by_clean, remark
    HAVING COUNT(*) > 1
), exact_duplicate AS (
    SELECT COUNT(*) AS duplicate_groups,
        COALESCE(SUM(row_count - 1), 0)::bigint AS extra_rows
    FROM exact_duplicate_group
), source_type AS (
    SELECT COUNT(*) FILTER (
        WHERE data_type NOT IN (
            'timestamp without time zone', 'timestamp with time zone', 'date'
        )
    )::bigint AS invalid_type_count
    FROM information_schema.columns
    WHERE table_schema = 'journal'
      AND table_name = 't_item_journey'
      AND column_name = 'created_on'
)
SELECT * FROM (
    SELECT 1 AS check_order, 'MISSING_ITEM_IDENTIFIER'::text AS check_name,
        COUNT(*) FILTER (WHERE is_missing_item_identifier)::bigint AS affected_count,
        'Identifier item kosong'::text AS explanation
    FROM analytics.item_journey_clean
    UNION ALL SELECT 2, 'MISSING_ITEM_MODEL',
        COUNT(*) FILTER (WHERE item_model_code_clean IS NULL)::bigint,
        'Kode model item kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 3, 'MISSING_ITEM_TYPE',
        COUNT(*) FILTER (WHERE item_type_clean IS NULL)::bigint,
        'Tipe item kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 4, 'MISSING_ITEM_CATEGORY',
        COUNT(*) FILTER (WHERE item_category_clean IS NULL)::bigint,
        'Kategori PART atau TERMINAL kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 5, 'MISSING_CLIENT',
        COUNT(*) FILTER (WHERE client_clean IS NULL)::bigint,
        'Klien kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 6, 'MISSING_LOCATION',
        COUNT(*) FILTER (WHERE place_clean IS NULL)::bigint,
        'Lokasi mentah kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 7, 'LOCATION_NOT_IN_MASTER',
        COUNT(*) FILTER (
            WHERE place_clean IS NOT NULL AND place_canonical_clean IS NULL
        )::bigint,
        'Lokasi terisi tetapi tidak dapat dipetakan ke master'
        FROM analytics.item_journey_clean
    UNION ALL SELECT 8, 'MISSING_STATUS',
        COUNT(*) FILTER (WHERE status_clean IS NULL)::bigint,
        'Status journey kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 9, 'MISSING_DATE',
        COUNT(*) FILTER (WHERE created_on IS NULL)::bigint,
        'Tanggal journey kosong' FROM analytics.item_journey_clean
    UNION ALL SELECT 10, 'INVALID_OR_FUTURE_DATE',
        COUNT(*) FILTER (WHERE NOT is_valid_date OR is_future_date)::bigint,
        'Tanggal terlalu lama, invalid, atau melewati waktu ekstraksi'
        FROM analytics.item_journey_clean
    UNION ALL SELECT 11, 'DUPLICATE_JOURNEY_ID',
        COUNT(*) FILTER (WHERE is_duplicate_journey_id)::bigint,
        'journey_id tercatat lebih dari satu kali' FROM analytics.item_journey_clean
    UNION ALL SELECT 12, 'EXACT_LOG_DUPLICATE_EXTRA_ROWS', extra_rows,
        'Baris tambahan setelah seluruh isi bisnis log dibandingkan'
        FROM exact_duplicate
    UNION ALL SELECT 13, 'CREATED_ON_NOT_DATETIME', invalid_type_count,
        'Kolom created_on sumber bukan tipe date/timestamp' FROM source_type
) checks;

CREATE OR REPLACE VIEW analytics.eda_cleaning_review_detail AS
WITH flagged AS (
    SELECT j.*,
        COUNT(*) OVER (
            PARTITION BY item_identifier_clean, created_on, item_category_clean,
                item_type_clean, item_model_code_clean, client_clean,
                ref_doc_code_clean, wo_type_clean, wo_code_clean, place_clean,
                activity_clean, status_clean, done_by_clean, remark
        ) > 1 AS is_exact_duplicate_content
    FROM analytics.item_journey_clean j
)
SELECT journey_id, item_identifier_clean, item_model_code_clean,
    item_category_clean, status_clean, activity_clean, wo_type_clean,
    place_clean, place_canonical_clean, client_clean, created_on,
    ARRAY_REMOVE(ARRAY[
        CASE WHEN is_missing_item_identifier THEN 'MISSING_ITEM_IDENTIFIER' END,
        CASE WHEN item_model_code_clean IS NULL THEN 'MISSING_ITEM_MODEL' END,
        CASE WHEN created_on IS NULL THEN 'MISSING_DATE' END,
        CASE WHEN NOT is_valid_date OR is_future_date
            THEN 'INVALID_OR_FUTURE_DATE' END,
        CASE WHEN place_clean IS NOT NULL AND place_canonical_clean IS NULL
            THEN 'LOCATION_NOT_IN_MASTER' END,
        CASE WHEN is_item_model_consistent IS NOT TRUE
            THEN 'JOURNEY_MODEL_INCONSISTENT' END,
        CASE WHEN is_duplicate_journey_id THEN 'DUPLICATE_JOURNEY_ID' END,
        CASE WHEN is_exact_duplicate_content
            THEN 'EXACT_DUPLICATE_CONTENT' END
    ], NULL)::text[] AS review_issues,
    CASE
        WHEN is_missing_item_identifier OR item_model_code_clean IS NULL
          OR created_on IS NULL OR NOT is_valid_date OR is_future_date
            THEN 'EXCLUDE_FROM_TIME_MODEL_AND_REVIEW_SOURCE'
        WHEN is_duplicate_journey_id
            THEN 'EXCLUDE_DUPLICATE_KEY_AND_REVIEW_SOURCE'
        WHEN is_item_model_consistent IS NOT TRUE
            THEN 'EXCLUDE_FROM_INITIAL_MODEL_COHORT'
        WHEN is_exact_duplicate_content
            THEN 'REVIEW_BEFORE_DEDUPLICATION'
        WHEN place_clean IS NOT NULL AND place_canonical_clean IS NULL
            THEN 'KEEP_EVENT_EXCLUDE_LOCATION_FEATURE'
        ELSE 'REVIEW'
    END AS suggested_action
FROM flagged
WHERE is_missing_item_identifier
   OR item_model_code_clean IS NULL
   OR created_on IS NULL
   OR NOT is_valid_date
   OR is_future_date
   OR (place_clean IS NOT NULL AND place_canonical_clean IS NULL)
   OR is_item_model_consistent IS NOT TRUE
   OR is_duplicate_journey_id
   OR is_exact_duplicate_content;

CREATE OR REPLACE VIEW analytics.eda_item_activity_summary AS
SELECT item_category_clean, item_model_code_clean,
    COUNT(*) AS event_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count,
    COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
    COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
    COUNT(*) FILTER (WHERE event_semantic = 'FAILURE_ONSET') AS failure_count,
    MIN(created_on)::date AS first_activity_date,
    MAX(created_on)::date AS last_activity_date
FROM analytics.item_journey_operational_timeline
WHERE item_model_code_clean IS NOT NULL
GROUP BY item_category_clean, item_model_code_clean;

CREATE OR REPLACE VIEW analytics.eda_location_activity_summary AS
SELECT place_canonical_clean,
    COUNT(*) AS event_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count,
    COUNT(DISTINCT item_model_code_clean) AS model_count,
    COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
    COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
    COUNT(*) FILTER (WHERE event_semantic = 'FAILURE_ONSET') AS failure_count,
    MIN(created_on)::date AS first_activity_date,
    MAX(created_on)::date AS last_activity_date
FROM analytics.item_journey_operational_timeline
WHERE place_canonical_clean IS NOT NULL
GROUP BY place_canonical_clean;

CREATE OR REPLACE VIEW analytics.eda_activity_calendar_summary AS
SELECT created_on::date AS activity_date,
    DATE_TRUNC('month', created_on)::date AS activity_month,
    EXTRACT(ISODOW FROM created_on)::integer AS iso_day_of_week,
    EXTRACT(ISODOW FROM created_on)::integer IN (6, 7) AS is_weekend,
    COUNT(*) AS event_count,
    COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
    COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
    COUNT(*) FILTER (WHERE event_semantic = 'FAILURE_ONSET') AS failure_count
FROM analytics.item_journey_operational_timeline
GROUP BY created_on::date, DATE_TRUNC('month', created_on)::date,
    EXTRACT(ISODOW FROM created_on)::integer;

CREATE OR REPLACE VIEW analytics.eda_item_location_installation_summary AS
SELECT item_model_code_clean, place_canonical_clean,
    COUNT(*) AS installation_count,
    COUNT(DISTINCT item_identifier_clean) AS item_count,
    MIN(created_on)::date AS first_installed_date,
    MAX(created_on)::date AS last_installed_date
FROM analytics.item_journey_operational_timeline
WHERE item_category_clean = 'PART'
  AND status_clean = 'INSTALLED'
  AND item_model_code_clean IS NOT NULL
  AND place_canonical_clean IS NOT NULL
GROUP BY item_model_code_clean, place_canonical_clean;

CREATE OR REPLACE VIEW analytics.eda_location_lifecycle_detail AS
WITH installed AS (
    SELECT o.journey_id AS installation_journey_id,
        o.item_identifier_clean, o.item_model_code_clean,
        o.created_on AS installed_on,
        o.place_canonical_clean AS installed_place_clean,
        LEAD(o.created_on) OVER (
            PARTITION BY o.item_identifier_clean
            ORDER BY o.created_on, o.journey_id
        ) AS next_installed_on
    FROM analytics.item_journey_operational_timeline o
    WHERE o.status_clean = 'INSTALLED'
      AND o.item_category_clean = 'PART'
)
SELECT i.*,
    d.journey_id AS dismantle_journey_id,
    d.created_on AS dismantled_on,
    d.place_canonical_clean AS dismantled_place_clean,
    EXTRACT(EPOCH FROM (d.created_on - i.installed_on)) / 86400.0
        AS days_installed_to_dismantle,
    d.journey_id IS NOT NULL AS has_next_dismantle,
    i.installed_place_clean IS NOT NULL
      AND d.place_canonical_clean = i.installed_place_clean
        AS is_same_location,
    i.installed_place_clean IS NOT NULL
      AND d.place_canonical_clean IS NOT NULL
      AND d.place_canonical_clean <> i.installed_place_clean
        AS is_location_mismatch
FROM installed i
LEFT JOIN LATERAL (
    SELECT o.journey_id, o.created_on, o.place_canonical_clean
    FROM analytics.item_journey_operational_timeline o
    WHERE o.item_identifier_clean = i.item_identifier_clean
      AND o.status_clean = 'DISMANTLED'
      AND (
          o.created_on > i.installed_on
          OR (
              o.created_on = i.installed_on
              AND o.journey_id > i.installation_journey_id
          )
      )
      AND (i.next_installed_on IS NULL OR o.created_on < i.next_installed_on)
    ORDER BY o.created_on, o.journey_id
    LIMIT 1
) d ON TRUE;

CREATE OR REPLACE VIEW analytics.eda_location_lifecycle_summary AS
SELECT installed_place_clean,
    COUNT(*) AS installation_count,
    COUNT(*) FILTER (WHERE is_same_location) AS matched_lifecycle_count,
    ROUND(AVG(days_installed_to_dismantle)
        FILTER (WHERE is_same_location)::numeric, 2) AS average_days,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY days_installed_to_dismantle
    ) FILTER (WHERE is_same_location)::numeric, 2) AS median_days,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (
        ORDER BY days_installed_to_dismantle
    ) FILTER (WHERE is_same_location)::numeric, 2) AS p90_days
FROM analytics.eda_location_lifecycle_detail
GROUP BY installed_place_clean;

CREATE OR REPLACE VIEW analytics.eda_daily_activity_anomaly AS
WITH daily AS (
    SELECT created_on::date AS activity_date,
        COUNT(*) AS event_count,
        COUNT(*) FILTER (WHERE status_clean = 'INSTALLED') AS installation_count,
        COUNT(*) FILTER (WHERE status_clean = 'DISMANTLED') AS dismantle_count,
        COUNT(*) FILTER (WHERE is_admin_recon_context) AS admin_recon_count
    FROM analytics.item_journey_semantic
    WHERE is_valid_operational_date
    GROUP BY created_on::date
), boundary AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY event_count) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY event_count) AS q3
    FROM daily
)
SELECT d.*,
    b.q3 + 3 * (b.q3 - b.q1) AS extreme_event_limit,
    d.event_count > b.q3 + 3 * (b.q3 - b.q1) AS is_extreme_activity_day
FROM daily d
CROSS JOIN boundary b;

SELECT * FROM analytics.eda_journey_quality_summary ORDER BY check_order;
SELECT suggested_action, COUNT(*) FROM analytics.eda_cleaning_review_detail
GROUP BY suggested_action ORDER BY 2 DESC;
SELECT * FROM analytics.eda_item_activity_summary ORDER BY event_count DESC LIMIT 20;
SELECT * FROM analytics.eda_location_activity_summary ORDER BY event_count DESC LIMIT 20;
SELECT * FROM analytics.eda_location_lifecycle_summary
WHERE matched_lifecycle_count >= 20 ORDER BY median_days DESC;
SELECT * FROM analytics.eda_daily_activity_anomaly
WHERE is_extreme_activity_day ORDER BY event_count DESC LIMIT 20;
