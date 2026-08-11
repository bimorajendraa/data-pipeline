-- Siklus PART dimulai hanya oleh INSTALLED dengan waktu tepercaya.
-- RECON sudah dikeluarkan dari operational timeline dan tidak membuka siklus.
DROP VIEW IF EXISTS analytics.item_current_snapshot_features;
DROP MATERIALIZED VIEW IF EXISTS analytics.eda_feature_stability_monthly;
DROP MATERIALIZED VIEW IF EXISTS analytics.eda_snapshot_cadence_comparison;
DROP VIEW IF EXISTS analytics.eda_target_class_distribution;
DROP VIEW IF EXISTS analytics.eda_snapshot_master_coverage;
DROP VIEW IF EXISTS analytics.eda_outlier_summary;
DROP VIEW IF EXISTS analytics.eda_failure_unit_comparison;
DROP VIEW IF EXISTS analytics.failure_outcome_missing_onset_review;
DROP VIEW IF EXISTS analytics.eda_failure_readiness_summary;
DROP VIEW IF EXISTS analytics.eda_failure_rate_by_year;
DROP VIEW IF EXISTS analytics.eda_feature_missingness;
DROP VIEW IF EXISTS analytics.item_observation_30d_audit;
DROP VIEW IF EXISTS analytics.item_observation_30d_labels;
DROP VIEW IF EXISTS analytics.item_observation_30d_features;
DROP MATERIALIZED VIEW IF EXISTS analytics.item_observation_30d;
DROP MATERIALIZED VIEW IF EXISTS analytics.item_installation_cycle;

CREATE MATERIALIZED VIEW analytics.item_installation_cycle AS
WITH dataset_boundary AS (
    SELECT MAX(created_on) AS dataset_max_event_on
    FROM analytics.item_journey_operational_timeline
), item_activity_boundary AS (
    SELECT item_identifier_clean,
        MAX(created_on) AS item_last_seen_on,
        (ARRAY_AGG(status_clean ORDER BY created_on DESC, journey_id DESC))[1]
            AS item_last_status_clean
    FROM analytics.item_journey_operational_timeline
    WHERE item_identifier_clean IS NOT NULL
    GROUP BY item_identifier_clean
), item_recon_after_boundary AS (
    -- RECON yang muncul setelah waktu terakhir item terlihat aktif menandakan
    -- ada sesuatu yang perlu direkonsiliasi pada item tersebut - sinyal bahwa
    -- masa diam sebelumnya belum tentu benar-benar aman, terlepas seberapa
    -- baru aktivitas terakhirnya. Dipakai sebagai dasar
    -- is_recon_verified_negative_eligible di bawah (temuan sensitivity
    -- analysis 2026-08: aturan berbasis RECON lebih tepat sasaran daripada
    -- aturan berbasis jarak waktu semata).
    SELECT b.item_identifier_clean,
        BOOL_OR(s.created_on > b.item_last_seen_on) AS has_recon_after_last_seen
    FROM item_activity_boundary b
    JOIN analytics.item_journey_semantic s
      ON s.item_identifier_clean = b.item_identifier_clean
     AND s.is_admin_recon_context
    GROUP BY b.item_identifier_clean
), installed_events AS (
    SELECT o.*,
        ROW_NUMBER() OVER (PARTITION BY o.item_identifier_clean ORDER BY o.created_on, o.journey_id) AS installation_sequence,
        LEAD(o.created_on) OVER (PARTITION BY o.item_identifier_clean ORDER BY o.created_on, o.journey_id) AS next_installed_on,
        LEAD(o.journey_id) OVER (PARTITION BY o.item_identifier_clean ORDER BY o.created_on, o.journey_id) AS next_installed_journey_id
    FROM analytics.item_journey_operational_timeline o
    WHERE o.status_clean = 'INSTALLED'
      AND o.item_category_clean = 'PART'
      AND o.item_identifier_clean IS NOT NULL
), cycle_events AS (
    SELECT i.*, f.journey_id AS failure_journey_id, f.failure_onset_on,
        f.failure_confirmed_on, f.failure_confirmation_status,
        f.event_label_basis AS failure_label_basis,
        f.failure_place_clean, f.is_location_feature_eligible AS is_failure_location_valid,
        f.model_cohort_status AS failure_model_cohort_status,
        b.dataset_max_event_on, item_end.item_last_seen_on,
        item_end.item_last_status_clean,
        COALESCE(recon_after.has_recon_after_last_seen, FALSE)
            AS has_recon_after_last_seen
    FROM installed_events i
    CROSS JOIN dataset_boundary b
    JOIN item_activity_boundary item_end
      ON item_end.item_identifier_clean = i.item_identifier_clean
    LEFT JOIN item_recon_after_boundary recon_after
      ON recon_after.item_identifier_clean = i.item_identifier_clean
    LEFT JOIN LATERAL (
        SELECT f.journey_id, f.failure_onset_on, f.failure_confirmed_on,
            f.failure_confirmation_status, f.event_label_basis,
            f.failure_place_clean, f.is_location_feature_eligible,
            f.model_cohort_status
        FROM analytics.failure_event_clean f
        WHERE f.item_identifier_clean = i.item_identifier_clean
          AND (f.failure_onset_on, f.journey_id) > (i.created_on, i.journey_id)
          AND (
              i.next_installed_on IS NULL
              OR (f.failure_onset_on, f.journey_id)
                    < (i.next_installed_on, i.next_installed_journey_id)
          )
        ORDER BY f.failure_onset_on, f.journey_id LIMIT 1
    ) f ON TRUE
), validated AS (
    SELECT c.*,
        pi.identifier_clean IS NOT NULL OR hi.identifier_clean IS NOT NULL AS is_item_found,
        (pi.identifier_clean IS NOT NULL OR hi.identifier_clean IS NOT NULL)
        AND CASE WHEN pi.identifier_clean IS NULL THEN TRUE
                 WHEN c.item_model_code_clean IS NULL THEN pi.nonnull_model_count = 0
                 ELSE NOT pi.has_null_model AND pi.nonnull_model_count = 1
                      AND pi.only_model_code = c.item_model_code_clean END
        AND CASE WHEN hi.identifier_clean IS NULL THEN TRUE
                 WHEN c.item_model_code_clean IS NULL THEN hi.nonnull_model_count = 0
                 ELSE NOT hi.has_null_model AND hi.nonnull_model_count = 1
                      AND hi.only_model_code = c.item_model_code_clean END AS is_item_model_consistent
    FROM cycle_events c
    LEFT JOIN analytics.item_identifier_model_cache pi ON pi.lookup_type = 'PAIRING' AND pi.identifier_clean = c.item_pairing_code_clean
    LEFT JOIN analytics.item_identifier_model_cache hi ON hi.lookup_type = 'HOST' AND hi.identifier_clean = c.host_serial_code_clean
), cycle_base AS (
SELECT item_identifier_clean || ':' || installation_sequence::text AS installation_cycle_id,
    item_identifier_clean, installation_sequence, journey_id AS installed_journey_id,
    created_on AS installed_on, item_model_code_clean, item_type_clean,
    item_pairing_code_clean, host_serial_code_clean, client_clean AS installed_client_clean,
    place_clean AS installed_place_source_clean,
    place_canonical_clean AS installed_place_clean,
    place_canonical_clean IS NOT NULL AND NOT is_place_mapping_ambiguous
        AS is_installed_location_valid,
    next_installed_on, next_installed_journey_id, failure_journey_id,
    failure_onset_on, failure_confirmed_on, failure_confirmation_status,
    failure_label_basis, failure_place_clean, is_failure_location_valid,
    failure_model_cohort_status,
    COALESCE(failure_onset_on, next_installed_on, dataset_max_event_on) AS cycle_end_on,
    CASE WHEN failure_onset_on IS NOT NULL THEN 'FAILURE'
         WHEN next_installed_on IS NOT NULL THEN 'REINSTALL_WITHOUT_RECORDED_FAILURE'
         ELSE 'RIGHT_CENSORED_AT_DATA_END' END AS cycle_end_reason,
    item_last_seen_on,
    COALESCE(failure_onset_on, next_installed_on, item_last_seen_on)
        AS item_observation_end_on,
    CASE
        WHEN failure_onset_on IS NOT NULL THEN 'OBSERVED_FAILURE'
        WHEN next_installed_on IS NOT NULL THEN 'OBSERVED_REINSTALL'
        WHEN dataset_max_event_on - item_last_seen_on <= INTERVAL '30 days'
            THEN 'RECENT_ITEM_ACTIVITY_NEAR_DATA_END'
        ELSE 'ITEM_HISTORY_STOPS_BEFORE_DATA_END'
    END AS observation_end_reason,
    item_last_status_clean,
    failure_onset_on IS NOT NULL
      OR next_installed_on IS NOT NULL
      OR dataset_max_event_on - item_last_seen_on <= INTERVAL '30 days'
        AS is_activity_coverage_confirmed,
    failure_onset_on IS NOT NULL AS has_observed_failure,
    failure_onset_on IS NULL AND next_installed_on IS NULL AS is_right_censored,
    failure_onset_on IS NOT NULL OR next_installed_on IS NULL
        AS is_cycle_label_reliable,
    -- Snapshot sebelum sebuah failure tetap boleh menjadi negatif bila failure
    -- tersebut berada di luar horizon 30 hari. Yang tidak boleh otomatis
    -- negatif hanyalah cycle yang ditutup oleh reinstall tanpa failure tercatat.
    failure_onset_on IS NOT NULL OR next_installed_on IS NULL
        AS is_negative_cycle_eligible,
    failure_onset_on IS NOT NULL
      OR (
          next_installed_on IS NULL
          AND dataset_max_event_on - item_last_seen_on <= INTERVAL '30 days'
      ) AS is_strict_negative_cycle_eligible,
    has_recon_after_last_seen,
    -- Alternatif yang lebih tepat sasaran dibanding is_strict_negative_cycle_eligible:
    -- tidak mensyaratkan aktivitas baru-baru ini, tetapi menolak negatif kalau
    -- RECON terbukti muncul belakangan untuk item tersebut. Sensitivity
    -- analysis (2026-08) menemukan is_strict_negative_cycle_eligible melewatkan
    -- kasus yang baru aktif tetapi tetap kena RECON, dan sebaliknya membuang
    -- kasus lama-diam yang sebenarnya tidak pernah direkonsiliasi sama sekali.
    failure_onset_on IS NOT NULL
      OR (
          next_installed_on IS NULL
          AND NOT COALESCE(has_recon_after_last_seen, FALSE)
      ) AS is_recon_verified_negative_eligible,
    CASE
        WHEN failure_onset_on IS NOT NULL THEN 'RELIABLE_OBSERVED_FAILURE'
        WHEN next_installed_on IS NOT NULL
            THEN 'UNKNOWN_REINSTALL_WITHOUT_RECORDED_FAILURE'
        WHEN dataset_max_event_on - item_last_seen_on <= INTERVAL '30 days'
            THEN 'RIGHT_CENSORED_RECENT_ACTIVITY'
        ELSE 'RIGHT_CENSORED_ACTIVITY_COVERAGE_UNCONFIRMED'
    END AS cycle_quality_status,
    is_item_found, is_item_model_consistent,
    created_on < COALESCE(failure_onset_on, next_installed_on, dataset_max_event_on)
        AS is_cycle_time_valid,
    is_item_found AND is_item_model_consistent
        AND created_on < COALESCE(failure_onset_on, next_installed_on, dataset_max_event_on)
        AS is_initial_model_cohort,
    dataset_max_event_on,
    EXTRACT(EPOCH FROM (dataset_max_event_on - item_last_seen_on)) / 86400.0
        AS days_item_unseen_at_dataset_end,
    EXTRACT(EPOCH FROM (failure_onset_on - created_on)) / 86400.0 AS days_installed_to_failure
FROM validated
)
SELECT cycle_base.*,
    -- Rata-rata umur siklus-siklus SEBELUMNYA (bukan siklus ini sendiri) untuk
    -- item yang sama - hanya terisi untuk PART yang sudah pernah dipasang
    -- ulang. Diuji terkontrol lewat ablation (2026-08): terbukti membantu,
    -- terutama pada subset PART yang punya riwayat pemasangan ulang (ROC-AUC
    -- 0,7153->0,7272, PR-AUC 0,1811->0,1971 di TEST_2026), sementara jarak
    -- waktu antar-kegagalan (interval antar-failure) diuji juga tapi TIDAK
    -- dipakai karena datanya terlalu jarang (importance mendekati nol).
    AVG(EXTRACT(EPOCH FROM (cycle_end_on - installed_on)) / 86400.0) OVER (
        PARTITION BY item_identifier_clean ORDER BY installation_sequence
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS previous_cycle_lifetime_mean,
    COUNT(*) OVER (
        PARTITION BY item_identifier_clean ORDER BY installation_sequence
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) > 0 AS has_previous_cycle
FROM cycle_base;

CREATE UNIQUE INDEX item_installation_cycle_id_idx ON analytics.item_installation_cycle (installation_cycle_id);
CREATE INDEX item_installation_cycle_item_date_idx ON analytics.item_installation_cycle (item_identifier_clean, installed_on);
CREATE INDEX item_installation_cycle_failure_idx ON analytics.item_installation_cycle (has_observed_failure, failure_onset_on);
