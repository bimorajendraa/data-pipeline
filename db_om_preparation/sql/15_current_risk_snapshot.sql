-- Fitur "kondisi PART aktif saat ini" untuk scoring operasional, terpisah
-- dari dataset training 30-harian (analytics.item_observation_30d, file 12).
--
-- Kenapa perlu terpisah: item_observation_30d sengaja hanya membuat snapshot
-- pada grid tetap 30 hari (installed_on, +30 hari, +60 hari, dst) supaya
-- cadence data training konsisten - itu benar untuk tujuan training. Tapi
-- konsekuensinya, snapshot TERAKHIR sebuah cycle yang masih aktif bisa
-- tertinggal sampai ~29 hari dari kejadian terbaru yang sebenarnya sudah
-- tercatat di database (dikonfirmasi 2026-08 lewat reports/current_risk_ranking.csv
-- sebelum perbaikan ini: median 18,6 hari basi, 60% PART aktif >=14 hari basi).
--
-- View ini menghitung ulang fitur historis yang SAMA PERSIS (LATERAL
-- aggregate sama dengan file 12, transformasi sama dengan
-- analytics.failure_30d_baseline_features di file 14), tetapi hanya PADA
-- SATU TITIK WAKTU per cycle aktif: observation_on = dataset_max_event_on
-- (kejadian terbaru yang tercatat), bukan grid 30 hari. Hasilnya selalu
-- "0 hari basi" relatif terhadap data yang tersedia.
--
-- PENTING: bukan VIEW materialized (supaya selalu fresh tanpa perlu REFRESH
-- terpisah) dan TIDAK dipakai untuk training (tidak masuk item_observation_30d
-- maupun failure_30d_baseline_features) - hanya dikonsumsi
-- src/score_current_risk.py. Rumus transformasi di bawah SENGAJA disalin
-- identik dari failure_30d_baseline_features (file 14), termasuk
-- pengelompokan part_model_category dukungan-rendah (rare-category ablation
-- 2026-08) - kalau definisi fitur di sana berubah, view ini WAJIB
-- diperbarui juga.
DROP VIEW IF EXISTS analytics.item_current_snapshot_features;

CREATE VIEW analytics.item_current_snapshot_features AS
WITH part_model_support AS (
    -- Dukungan historis total per tipe PART hingga saat ini. Karena
    -- observation_on di bawah selalu dataset_max_event_on (kejadian terbaru),
    -- dan seluruh baris item_observation_30d sudah <= dataset_max_event_on
    -- dengan sendirinya, total ini SAMA DENGAN nilai
    -- part_model_cumulative_support (file 12b) pada titik waktu tersebut -
    -- tidak perlu window function per baris seperti di file 12b/14.
    SELECT item_model_code_clean, COUNT(*) AS total_support
    FROM analytics.item_observation_30d
    GROUP BY item_model_code_clean
), active_cycle AS (
    SELECT
        c.installation_cycle_id, c.item_identifier_clean, c.item_model_code_clean,
        c.installed_client_clean, c.installed_on,
        c.dataset_max_event_on AS observation_on,
        COALESCE(sup.total_support, 0) AS part_model_cumulative_support,
        c.previous_cycle_lifetime_mean, c.has_previous_cycle,
        EXTRACT(EPOCH FROM (c.dataset_max_event_on - c.installed_on)) / 86400.0
            AS days_since_installation
    FROM analytics.item_installation_cycle c
    LEFT JOIN part_model_support sup
      ON sup.item_model_code_clean = c.item_model_code_clean
    WHERE c.is_initial_model_cohort
      AND c.cycle_end_reason = 'RIGHT_CENSORED_AT_DATA_END'
), features AS (
    SELECT s.*, h.*
    FROM active_cycle s
    LEFT JOIN LATERAL (
        SELECT
            COUNT(*) AS total_prior_events,
            COUNT(*) FILTER (WHERE o.event_semantic = 'FAILURE_ONSET')
                AS prior_failure_count,
            COUNT(*) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE')
                AS prior_corrective_count,
            COUNT(*) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE'
                AND o.created_on > s.observation_on - INTERVAL '30 days')
                AS prior_corrective_30d,
            COUNT(*) FILTER (WHERE o.event_semantic = 'FAILURE_ONSET'
                AND o.created_on > s.observation_on - INTERVAL '365 days')
                AS prior_failure_365d,
            COUNT(*) FILTER (WHERE o.created_on > s.observation_on - INTERVAL '180 days')
                AS prior_events_180d,
            COUNT(DISTINCT o.place_canonical_clean) AS prior_distinct_places,
            MAX(o.created_on) FILTER (WHERE o.wo_type_clean = 'CORRECTIVE')
                AS last_corrective_on
        FROM analytics.item_journey_operational_timeline o
        WHERE o.item_identifier_clean = s.item_identifier_clean
          AND o.created_on <= s.observation_on
    ) h ON TRUE
)
SELECT
    installation_cycle_id,
    item_identifier_clean,
    observation_on,
    item_model_code_clean AS part_model_code_raw,
    part_model_cumulative_support,
    days_since_installation AS raw_days_since_installation,
    CASE
        WHEN item_model_code_clean IS NULL THEN 'UNKNOWN'
        WHEN part_model_cumulative_support < 300 THEN 'LOW_HISTORICAL_SUPPORT'
        ELSE item_model_code_clean
    END AS part_model_category,
    COALESCE(installed_client_clean, 'UNKNOWN') AS client_category,
    LN(1.0 + GREATEST(days_since_installation, 0)) AS log_days_since_installation,
    CASE
        WHEN days_since_installation < 91 THEN '000_090_DAYS'
        WHEN days_since_installation < 181 THEN '091_180_DAYS'
        WHEN days_since_installation < 366 THEN '181_365_DAYS'
        WHEN days_since_installation < 731 THEN '366_730_DAYS'
        WHEN days_since_installation < 1461 THEN '731_1460_DAYS'
        ELSE '1461_PLUS_DAYS'
    END AS installation_age_band,
    LN(1.0 + GREATEST(COALESCE(total_prior_events, 0), 0)) AS log_total_prior_events,
    LN(1.0 + GREATEST(COALESCE(prior_failure_count, 0), 0)) AS log_prior_failure_count,
    COALESCE(prior_failure_count, 0) > 0 AS has_prior_failure,
    LN(1.0 + GREATEST(COALESCE(prior_corrective_count, 0), 0))
        AS log_prior_corrective_count,
    COALESCE(prior_corrective_count, 0) > 0 AS has_prior_corrective,
    LN(1.0 + GREATEST(
        COALESCE(EXTRACT(EPOCH FROM (observation_on - last_corrective_on)) / 86400.0, 0), 0
    )) AS log_days_since_last_corrective,
    LN(1.0 + GREATEST(COALESCE(prior_distinct_places, 0), 0))
        AS log_prior_distinct_places,
    LN(1.0 + GREATEST(COALESCE(prior_corrective_30d, 0), 0)) AS log_prior_corrective_30d,
    LN(1.0 + GREATEST(COALESCE(prior_failure_365d, 0), 0)) AS log_prior_failure_365d,
    LN(1.0 + GREATEST(COALESCE(prior_events_180d, 0), 0)) AS log_prior_events_180d,
    LN(1.0 + GREATEST(COALESCE(previous_cycle_lifetime_mean, 0), 0))
        AS log_previous_cycle_lifetime_mean,
    COALESCE(has_previous_cycle, FALSE) AS has_previous_cycle,
    SIN(2.0 * PI() * (EXTRACT(MONTH FROM observation_on) - 1) / 12.0) AS month_sin,
    COS(2.0 * PI() * (EXTRACT(MONTH FROM observation_on) - 1) / 12.0) AS month_cos
FROM features;
