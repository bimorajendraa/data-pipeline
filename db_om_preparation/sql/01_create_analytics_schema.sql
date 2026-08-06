-- Hanya membuat objek baru di schema analytics. Tidak mengubah tabel sumber.
CREATE SCHEMA IF NOT EXISTS analytics;

-- Mapping yang telah disetujui disimpan sebagai data, bukan hard-coded di
-- fungsi/view. Penambahan alias berikutnya tidak memerlukan perubahan SQL.
CREATE TABLE IF NOT EXISTS analytics.text_abbreviation_mapping (
    source_value text PRIMARY KEY,
    canonical_value text NOT NULL,
    mapping_basis text NOT NULL,
    approved_by text NOT NULL,
    approved_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active boolean NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS analytics.verified_location_alias (
    source_value text PRIMARY KEY,
    canonical_value text NOT NULL,
    mapping_basis text NOT NULL,
    approved_by text NOT NULL,
    approved_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active boolean NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS analytics.verified_client_alias (
    source_value text PRIMARY KEY,
    canonical_value text NOT NULL,
    mapping_basis text NOT NULL,
    approved_by text NOT NULL,
    approved_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active boolean NOT NULL DEFAULT TRUE
);

INSERT INTO analytics.text_abbreviation_mapping (
    source_value, canonical_value, mapping_basis, approved_by
) VALUES (
    'JKT', 'JAKARTA', 'COMMON_UNAMBIGUOUS_LOCATION_ABBREVIATION', 'EDA_REVIEW'
) ON CONFLICT (source_value) DO NOTHING;

INSERT INTO analytics.verified_location_alias (
    source_value, canonical_value, mapping_basis, approved_by
) VALUES (
    'GUDANG NUTECH', 'GUDANG NI',
    'VERIFIED_ITEM_OVERLAP_AND_WAREHOUSE_FLOW', 'EDA_REVIEW'
) ON CONFLICT (source_value) DO NOTHING;

CREATE OR REPLACE FUNCTION analytics.clean_code(value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN NULLIF(UPPER(REGEXP_REPLACE(TRIM(value), '\s+', ' ', 'g')), '');

CREATE OR REPLACE FUNCTION analytics.clean_text(value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN NULLIF(REGEXP_REPLACE(TRIM(value), '\s+', ' ', 'g'), '');

-- Cleaning nama bersifat konservatif: underscore tidak langsung dianggap spasi.
CREATE OR REPLACE FUNCTION analytics.clean_name(value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN NULLIF(
    UPPER(REGEXP_REPLACE(TRIM(value), '\s+', ' ', 'g')),
    ''
);

-- Key ini hanya dipakai untuk membuat daftar kandidat standardisasi. View clean
-- tetap memakai clean_name agar dua nama tidak digabung otomatis karena underscore.
CREATE OR REPLACE FUNCTION analytics.name_candidate_key(value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN NULLIF(
    UPPER(REGEXP_REPLACE(TRIM(REPLACE(value, '_', ' ')), '\s+', ' ', 'g')),
    ''
);

-- Key khusus fuzzy matching: tanda baca disamakan dan singkatan umum yang
-- tidak ambigu diperluas. Nilai sumber tidak pernah ditimpa oleh fungsi ini.
CREATE OR REPLACE FUNCTION analytics.fuzzy_match_key(value text)
RETURNS text
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $function$
DECLARE
    normalized_value text;
    mapping record;
BEGIN
    normalized_value := ' ' || UPPER(
        REGEXP_REPLACE(TRIM(value), '[^A-Za-z0-9]+', ' ', 'g')
    ) || ' ';
    FOR mapping IN
        SELECT UPPER(source_value) AS source_value,
            UPPER(canonical_value) AS canonical_value
        FROM analytics.text_abbreviation_mapping
        WHERE is_active
        ORDER BY CHAR_LENGTH(source_value) DESC, source_value
    LOOP
        normalized_value := REPLACE(
            normalized_value,
            ' ' || mapping.source_value || ' ',
            ' ' || mapping.canonical_value || ' '
        );
    END LOOP;
    RETURN NULLIF(TRIM(REGEXP_REPLACE(normalized_value, '\s+', ' ', 'g')), '');
END;
$function$;

-- Implementasi Levenshtein mandiri agar pipeline tidak bergantung pada
-- extension database atau package Python tambahan.
CREATE OR REPLACE FUNCTION analytics.levenshtein_distance(left_value text, right_value text)
RETURNS integer
LANGUAGE plpgsql
STABLE
STRICT
PARALLEL SAFE
AS $function$
DECLARE
    left_key text := analytics.fuzzy_match_key(left_value);
    right_key text := analytics.fuzzy_match_key(right_value);
    left_length integer;
    right_length integer;
    previous_row integer[];
    current_row integer[];
    substitution_cost integer;
    i integer;
    j integer;
BEGIN
    left_length := CHAR_LENGTH(left_key);
    right_length := CHAR_LENGTH(right_key);
    IF left_length = 0 THEN RETURN right_length; END IF;
    IF right_length = 0 THEN RETURN left_length; END IF;

    SELECT ARRAY_AGG(value ORDER BY value)
    INTO previous_row
    FROM GENERATE_SERIES(0, right_length) value;

    FOR i IN 1..left_length LOOP
        current_row := ARRAY[i];
        FOR j IN 1..right_length LOOP
            substitution_cost := CASE
                WHEN SUBSTRING(left_key FROM i FOR 1)
                   = SUBSTRING(right_key FROM j FOR 1) THEN 0
                ELSE 1
            END;
            current_row := current_row || LEAST(
                current_row[j] + 1,
                previous_row[j + 1] + 1,
                previous_row[j] + substitution_cost
            );
        END LOOP;
        previous_row := current_row;
    END LOOP;
    RETURN previous_row[right_length + 1];
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.fuzzy_similarity(left_value text, right_value text)
RETURNS numeric
LANGUAGE sql
STABLE
STRICT
PARALLEL SAFE
RETURN ROUND(
    1.0 - analytics.levenshtein_distance(left_value, right_value)::numeric
        / NULLIF(GREATEST(
            CHAR_LENGTH(analytics.fuzzy_match_key(left_value)),
            CHAR_LENGTH(analytics.fuzzy_match_key(right_value))
        ), 0),
    4
);
