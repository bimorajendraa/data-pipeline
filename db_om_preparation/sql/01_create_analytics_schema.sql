-- Hanya membuat objek baru di schema analytics. Tidak mengubah tabel sumber.
CREATE SCHEMA IF NOT EXISTS analytics;

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
