-- Hasil profiling terstruktur tersedia melalui analytics.data_profile.
-- View ini membaca tabel sumber saja dan tidak menyimpan salinan datanya.
CREATE OR REPLACE FUNCTION analytics.profile_source_data()
RETURNS TABLE (
    table_name text,
    column_name text,
    quality_check text,
    metric_value bigint,
    details jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    cfg record;
    col record;
    qualified_name text;
BEGIN
    FOR cfg IN
        SELECT * FROM (VALUES
            ('journal', 't_item_journey', 'journey_id'),
            ('inventory', 't_item', 'item_id'),
            ('journal', 't_work_order', 'wo_id'),
            ('journal', 't_work_order_history', 'wo_history_id'),
            ('journal', 't_mtbf', 'mtbf_id')
        ) AS x(schema_name, relation_name, primary_key_name)
    LOOP
        qualified_name := format('%I.%I', cfg.schema_name, cfg.relation_name);

        IF to_regclass(qualified_name) IS NULL THEN
            table_name := qualified_name;
            column_name := NULL;
            quality_check := 'TABLE_NOT_FOUND';
            metric_value := 1;
            details := jsonb_build_object('message', 'Tabel sumber tidak ditemukan');
            RETURN NEXT;
            CONTINUE;
        END IF;

        RETURN QUERY EXECUTE format(
            'SELECT %L::text, NULL::text, %L::text, COUNT(*)::bigint, NULL::jsonb FROM %s',
            qualified_name, 'TOTAL_ROWS', qualified_name
        );

        RETURN QUERY EXECUTE format(
            'SELECT %L::text, NULL::text, %L::text,
                    COALESCE(SUM(duplicate_count - 1), 0)::bigint, NULL::jsonb
             FROM (
                 SELECT COUNT(*) AS duplicate_count
                 FROM %s AS source_row
                 GROUP BY to_jsonb(source_row)
                 HAVING COUNT(*) > 1
             ) duplicates',
            qualified_name, 'DUPLICATE_ROWS', qualified_name
        );

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns c
            WHERE c.table_schema = cfg.schema_name
              AND c.table_name = cfg.relation_name
              AND c.column_name = cfg.primary_key_name
        ) THEN
            RETURN QUERY EXECUTE format(
                'SELECT %L::text, %L::text, %L::text,
                        COALESCE(SUM(duplicate_count - 1), 0)::bigint, NULL::jsonb
                 FROM (
                     SELECT COUNT(*) AS duplicate_count
                     FROM %s
                     WHERE %I IS NOT NULL
                     GROUP BY %I
                     HAVING COUNT(*) > 1
                 ) duplicates',
                qualified_name, cfg.primary_key_name, 'DUPLICATE_PRIMARY_KEY',
                qualified_name, cfg.primary_key_name, cfg.primary_key_name
            );
        END IF;

        FOR col IN
            SELECT c.column_name, c.data_type
            FROM information_schema.columns c
            WHERE c.table_schema = cfg.schema_name
              AND c.table_name = cfg.relation_name
              AND (
                  c.column_name IN (
                      'item_category', 'item_type', 'item_model_code',
                      'item_pairing_code', 'host_serial_code', 'sn_ref', 'client',
                      'client_code', 'wo_type', 'wo_code', 'place', 'activity',
                      'status', 'current_status', 'done_by', 'location',
                      'location_code', 'created_on', 'updated_on', 'start_date',
                      'due_date', 'received_date', 'supplier_warranty_end_date'
                  )
              )
            ORDER BY c.ordinal_position
        LOOP
            RETURN QUERY EXECUTE format(
                'WITH metric_values AS MATERIALIZED (
                     SELECT
                         COUNT(*) FILTER (WHERE %1$I IS NULL)::bigint AS null_values,
                         COUNT(*) FILTER (
                             WHERE %1$I IS NOT NULL AND TRIM(%1$I::text) = ''''
                         )::bigint AS empty_strings,
                         COUNT(DISTINCT %1$I)::bigint AS unique_values,
                         COUNT(*) FILTER (
                             WHERE %1$I IS NOT NULL
                               AND %1$I::text <> TRIM(%1$I::text)
                         )::bigint AS leading_or_trailing_space
                     FROM %2$s
                 )
                 SELECT %3$L::text, %4$L::text,
                        metric.quality_check::text,
                        metric.metric_value::bigint,
                        NULL::jsonb
                 FROM metric_values
                 CROSS JOIN LATERAL (VALUES
                     (''NULL_VALUES'', null_values),
                     (''EMPTY_STRINGS'', empty_strings),
                     (''UNIQUE_VALUES'', unique_values),
                     (''LEADING_OR_TRAILING_SPACE'', leading_or_trailing_space)
                 ) metric(quality_check, metric_value)',
                col.column_name, qualified_name, qualified_name, col.column_name
            );

            IF col.data_type IN ('character varying', 'character', 'text') THEN
                RETURN QUERY EXECUTE format(
                    'WITH value_counts AS MATERIALIZED (
                         SELECT
                             %1$I::text AS value,
                             TRIM(%1$I::text) AS trimmed_value,
                             UPPER(TRIM(%1$I::text)) AS normalized_value,
                             COUNT(*)::bigint AS occurrence_count
                         FROM %2$s
                         WHERE NULLIF(TRIM(%1$I::text), '''') IS NOT NULL
                         GROUP BY %1$I
                     ),
                     case_variants AS (
                         SELECT COUNT(*)::bigint AS metric_value
                         FROM (
                             SELECT normalized_value
                             FROM value_counts
                             GROUP BY normalized_value
                             HAVING COUNT(DISTINCT trimmed_value) > 1
                         ) groups_with_variants
                     ),
                     top_ten AS (
                         SELECT value, occurrence_count
                         FROM value_counts
                         ORDER BY occurrence_count DESC, value
                         LIMIT 10
                     ),
                     top_values AS (
                         SELECT
                             COUNT(*)::bigint AS metric_value,
                             COALESCE(jsonb_agg(jsonb_build_object(
                                 ''value'', value, ''count'', occurrence_count
                             ) ORDER BY occurrence_count DESC, value), ''[]''::jsonb)
                                 AS details
                         FROM top_ten
                     )
                     SELECT %3$L::text, %4$L::text, ''CASE_VARIANT_GROUPS''::text,
                            case_variants.metric_value, NULL::jsonb
                     FROM case_variants
                     UNION ALL
                     SELECT %3$L::text, %4$L::text, ''TOP_VALUES''::text,
                            top_values.metric_value, top_values.details
                     FROM top_values',
                    col.column_name, qualified_name, qualified_name, col.column_name
                );
            END IF;

            IF col.data_type IN ('date', 'timestamp without time zone', 'timestamp with time zone') THEN
                RETURN QUERY EXECUTE format(
                    'WITH date_metrics AS MATERIALIZED (
                         SELECT
                             COUNT(%1$I)::bigint AS populated_dates,
                             MIN(%1$I) AS minimum_date,
                             MAX(%1$I) AS maximum_date,
                             COUNT(*) FILTER (
                                 WHERE %1$I IS NOT NULL
                                   AND (%1$I::date < DATE ''1971-01-01''
                                        OR %1$I > CURRENT_TIMESTAMP)
                             )::bigint AS suspicious_dates
                         FROM %2$s
                     )
                     SELECT %3$L::text, %4$L::text, ''DATE_RANGE''::text,
                            populated_dates,
                            jsonb_build_object(''min'', minimum_date, ''max'', maximum_date)
                     FROM date_metrics
                     UNION ALL
                     SELECT %3$L::text, %4$L::text, ''SUSPICIOUS_DATE''::text,
                            suspicious_dates, NULL::jsonb
                     FROM date_metrics',
                    col.column_name, qualified_name, qualified_name, col.column_name
                );
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE VIEW analytics.data_profile_live AS
SELECT * FROM analytics.profile_source_data();

-- Profiling adalah snapshot audit. Nama utama disimpan sebagai materialized
-- view agar DBeaver/export tidak menghitung ratusan scan setiap kali dibuka.
DO $migration$
DECLARE
    object_kind "char";
BEGIN
    SELECT c.relkind
    INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'data_profile';

    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.data_profile';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.data_profile';
    END IF;
END;
$migration$;

CREATE MATERIALIZED VIEW analytics.data_profile AS
SELECT * FROM analytics.data_profile_live;

CREATE INDEX data_profile_lookup_idx
    ON analytics.data_profile (table_name, column_name, quality_check);

/* Query pemeriksaan manual; tidak dieksekusi saat setup pipeline.
-- Pemeriksaan awal yang mudah dijalankan terpisah di DBeaver:
-- Struktur kolom
SELECT table_schema, table_name, ordinal_position, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE (table_schema, table_name) IN (
    ('journal', 't_item_journey'),
    ('inventory', 't_item'),
    ('journal', 't_work_order'),
    ('journal', 't_work_order_history'),
    ('journal', 't_mtbf')
)
ORDER BY table_schema, table_name, ordinal_position;

-- Semua metrik profiling (jumlah data, kosong, unik, duplikat, top value,
-- variasi case/spasi, dan rentang tanggal).
SELECT *
FROM analytics.data_profile
ORDER BY table_name, column_name NULLS FIRST, quality_check;

-- Kandidat standardisasi client/petugas. Tidak ada mapping yang diterapkan otomatis.
SELECT
    'client' AS field_name,
    analytics.name_candidate_key(client) AS candidate_standard,
    ARRAY_AGG(DISTINCT client ORDER BY client) AS original_variants,
    COUNT(*) AS row_count
FROM journal.t_item_journey
WHERE analytics.clean_text(client) IS NOT NULL
GROUP BY analytics.name_candidate_key(client)
HAVING COUNT(DISTINCT client) > 1
UNION ALL
SELECT
    'done_by',
    analytics.name_candidate_key(done_by),
    ARRAY_AGG(DISTINCT done_by ORDER BY done_by),
    COUNT(*)
FROM journal.t_item_journey
WHERE analytics.clean_text(done_by) IS NOT NULL
GROUP BY analytics.name_candidate_key(done_by)
HAVING COUNT(DISTINCT done_by) > 1
ORDER BY field_name, row_count DESC;
*/
