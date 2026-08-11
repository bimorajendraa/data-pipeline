-- Relasi PART ke perangkat induk (TERMINAL) per installation cycle, dan
-- observation dataset yang diperkaya dengan relasi tersebut.
--
-- Dipindah keluar dari 13_eda_views.sql: eda_item_observation_30d_hierarchy
-- bukan sekadar tabel eksplorasi, melainkan sumber langsung fitur baseline dan
-- challenger pada 14_feature_engineering.sql. Menaruhnya di file "EDA" dengan
-- prefix eda_ menyesatkan dan sebelumnya memaksa 13 dan 14 saling drop-ulang
-- satu sama lain. Nama view (eda_part_terminal_cycle_link,
-- eda_item_observation_30d_hierarchy) sengaja tidak diganti supaya seluruh
-- referensi pada 13, 14, eda_manual_checks.sql, dan notebook tetap berlaku.
--
-- host_serial_code pada journey adalah serial versi PART itu sendiri. Parent
-- perangkat berada di t_item_request_out.parent_serial_code. Relasi memakai
-- serial PART + WO installation agar satu PART yang berpindah terminal tidak
-- ditempelkan permanen ke parent yang salah.

-- File 12 sudah menurunkan seluruh view feature engineering (14) karena view
-- tersebut bergantung pada item_observation_30d. Di sini cukup menurunkan view
-- EDA bivariat (13) yang membaca hierarchy ini, lalu hierarchy itu sendiri, agar
-- file ini aman dijalankan ulang secara mandiri.
DROP VIEW IF EXISTS analytics.eda_bivariate_association_summary;
DROP VIEW IF EXISTS analytics.eda_bivariate_terminal_model_target;
DROP VIEW IF EXISTS analytics.eda_bivariate_terminal_type_target;
DROP VIEW IF EXISTS analytics.eda_part_terminal_structure_summary;
DROP VIEW IF EXISTS analytics.eda_item_observation_30d_hierarchy;
DO $drop_cycle_parent$
DECLARE object_kind "char";
BEGIN
    SELECT c.relkind INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'eda_part_terminal_cycle_link';
    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.eda_part_terminal_cycle_link';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.eda_part_terminal_cycle_link';
    END IF;
END $drop_cycle_parent$;

CREATE MATERIALIZED VIEW analytics.eda_part_terminal_cycle_link AS
SELECT
    c.installation_cycle_id,
    c.item_identifier_clean,
    c.item_model_code_clean AS part_model_code,
    c.item_pairing_code_clean AS part_pairing_code,
    c.host_serial_code_clean AS part_serial_version,
    c.installed_on,
    j.wo_code_clean AS installation_wo_code,
    r.item_request_out_id,
    r.created_on AS parent_link_recorded_on,
    analytics.clean_code(r.parent_serial_code) AS terminal_serial_version,
    NULLIF(SPLIT_PART(analytics.clean_code(r.parent_serial_code), '-', 1), '')
        AS terminal_model_code,
    NULLIF(SPLIT_PART(analytics.clean_code(r.parent_serial_code), '-', 2), '')
        AS terminal_pairing_code,
    NULLIF(SPLIT_PART(analytics.clean_code(r.parent_serial_code), '-', 3), '')
        AS terminal_repair_seq,
    analytics.clean_code(pm.item_category) AS parent_item_category,
    analytics.clean_text(pm.item_type) AS terminal_type,
    analytics.clean_text(pm.item_model_name) AS terminal_model_name,
    ti.item_id AS terminal_inventory_item_id,
    r.item_request_out_id IS NOT NULL AS is_parent_request_link_found,
    NULLIF(BTRIM(r.parent_serial_code), '') IS NOT NULL
        AS is_parent_serial_present,
    analytics.clean_code(pm.item_category) = 'TERMINAL'
        AS is_parent_master_terminal,
    ti.item_id IS NOT NULL AS is_parent_inventory_terminal,
    analytics.clean_code(pm.item_category) = 'TERMINAL'
      AND ti.item_id IS NOT NULL AS is_parent_link_valid,
    r.created_on > c.installed_on AS is_parent_link_recorded_after_installation,
    EXTRACT(EPOCH FROM (r.created_on - c.installed_on)) / 86400.0
        AS parent_link_recording_delay_days,
    CASE
        WHEN r.item_request_out_id IS NULL THEN 'UNMATCHED_INSTALLATION_REQUEST'
        WHEN NULLIF(BTRIM(r.parent_serial_code), '') IS NULL
            THEN 'MISSING_PARENT_SERIAL'
        WHEN analytics.clean_code(pm.item_category) IS DISTINCT FROM 'TERMINAL'
            THEN 'PARENT_NOT_TERMINAL'
        WHEN ti.item_id IS NULL THEN 'PARENT_TERMINAL_NOT_IN_INVENTORY'
        WHEN r.created_on > c.installed_on
            THEN 'VALID_RELATION_RECORDED_AFTER_INSTALLATION'
        ELSE 'VALID_POINT_IN_TIME_RELATION'
    END AS parent_link_quality_status
FROM analytics.item_installation_cycle c
JOIN analytics.item_journey_clean j
  ON j.journey_id = c.installed_journey_id
LEFT JOIN journal.t_item_request_out r
  ON r.item_serial_code_out = j.host_serial_code_clean
 AND r.wo_code = j.wo_code_clean
LEFT JOIN master.t_mtr_item pm
  ON pm.item_model_code = NULLIF(
      SPLIT_PART(analytics.clean_code(r.parent_serial_code), '-', 1), ''
  )
LEFT JOIN inventory.t_item ti
  ON ti.item_pairing_code = NULLIF(
      SPLIT_PART(analytics.clean_code(r.parent_serial_code), '-', 2), ''
  );

CREATE UNIQUE INDEX eda_part_terminal_cycle_link_key_idx
    ON analytics.eda_part_terminal_cycle_link (installation_cycle_id);
CREATE INDEX eda_part_terminal_cycle_link_terminal_idx
    ON analytics.eda_part_terminal_cycle_link (
        terminal_pairing_code, installed_on
    );
CREATE INDEX eda_part_terminal_cycle_link_part_idx
    ON analytics.eda_part_terminal_cycle_link (
        item_identifier_clean, installed_on
    );

-- Dukungan historis kumulatif (point-in-time) per jenis/model TERMINAL.
-- Dipakai file 14 untuk mengelompokkan jenis/model TERMINAL yang riwayatnya
-- masih sangat sedikit pada tanggal observasi (misalnya peralatan baru yang
-- baru mulai dipasang) menjadi kategori "dukungan historis rendah", supaya
-- model tidak menghafal pola dari sampel yang terlalu kecil. Dihitung hanya
-- dari event pada atau sebelum observation_on masing-masing baris (via ORDER
-- BY di window function) sehingga tidak memakai informasi masa depan.
CREATE VIEW analytics.eda_item_observation_30d_hierarchy AS
SELECT o.*,
    p.terminal_serial_version,
    p.terminal_model_code,
    p.terminal_pairing_code,
    p.terminal_repair_seq,
    p.terminal_type,
    p.terminal_model_name,
    p.parent_link_recorded_on,
    p.is_parent_link_valid,
    p.is_parent_link_recorded_after_installation,
    p.parent_link_recording_delay_days,
    p.parent_link_quality_status,
    COUNT(*) OVER (
        PARTITION BY (CASE WHEN p.is_parent_link_valid THEN p.terminal_type END)
        ORDER BY o.observation_on
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS terminal_type_cumulative_support,
    COUNT(*) OVER (
        PARTITION BY (CASE WHEN p.is_parent_link_valid THEN p.terminal_model_code END)
        ORDER BY o.observation_on
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS terminal_model_cumulative_support,
    -- Dukungan historis kumulatif (point-in-time) per tipe/model PART itu
    -- sendiri. Rare-category ablation (2026-08, lihat catatan pada 14) menguji
    -- ini secara terkontrol pada TEST_2026: mengelompokkan tipe PART dengan
    -- dukungan historis rendah terbukti menaikkan ROC-AUC/PR-AUC keseluruhan
    -- DAN performa di tiap bucket dukungan (termasuk yang dukungannya tinggi),
    -- bukan sekadar trade-off - baru diimplementasikan setelah bukti ini,
    -- bukan diasumsikan seperti klaim dokumentasi sebelumnya.
    COUNT(*) OVER (
        PARTITION BY o.item_model_code_clean
        ORDER BY o.observation_on
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS part_model_cumulative_support
FROM analytics.item_observation_30d o
LEFT JOIN analytics.eda_part_terminal_cycle_link p
  USING (installation_cycle_id);
