-- Kandidat fuzzy dihitung satu kali per nilai unik, lalu disimpan di cache
-- analytics. Ini mencegah Levenshtein dihitung ulang untuk setiap event saat
-- view clean atau laporan dibaca. Tabel sumber tetap tidak disentuh.
CREATE TABLE IF NOT EXISTS analytics.location_fuzzy_match_cache (
    source_location_clean text PRIMARY KEY,
    location_code_clean text,
    location_name_clean text,
    similarity_score numeric,
    second_best_score numeric,
    score_margin numeric,
    is_auto_accepted boolean NOT NULL
);

TRUNCATE TABLE analytics.location_fuzzy_match_cache;

INSERT INTO analytics.location_fuzzy_match_cache (
    source_location_clean, location_code_clean, location_name_clean,
    similarity_score, second_best_score, score_margin, is_auto_accepted
)
WITH source_value AS (
    SELECT DISTINCT analytics.clean_code(j.place) AS source_location_clean
    FROM journal.t_item_journey j
    WHERE analytics.clean_code(j.place) IS NOT NULL
),
master_reference AS (
    SELECT DISTINCT analytics.clean_code(l.location_code) AS location_code_clean,
        analytics.clean_code(l.location_name) AS location_name_clean
    FROM master.t_mtr_location l
    WHERE analytics.clean_code(l.location_name) IS NOT NULL
),
scored AS (
    SELECT s.source_location_clean, r.location_code_clean, r.location_name_clean,
        analytics.fuzzy_similarity(
            s.source_location_clean, r.location_name_clean
        ) AS similarity_score
    FROM source_value s
    CROSS JOIN master_reference r
    WHERE NOT EXISTS (
          SELECT 1 FROM analytics.verified_location_alias alias_match
          WHERE alias_match.is_active
            AND analytics.clean_code(alias_match.source_value)
                = s.source_location_clean
      )
      AND NOT EXISTS (
          SELECT 1 FROM master_reference exact_match
          WHERE s.source_location_clean IN (
              exact_match.location_code_clean,
              exact_match.location_name_clean
          )
      )
),
ranked AS (
    SELECT scored.*,
        ROW_NUMBER() OVER (
            PARTITION BY source_location_clean
            ORDER BY similarity_score DESC, location_name_clean
        ) AS candidate_rank,
        LEAD(similarity_score) OVER (
            PARTITION BY source_location_clean
            ORDER BY similarity_score DESC, location_name_clean
        ) AS second_best_score
    FROM scored
)
SELECT source_location_clean, location_code_clean, location_name_clean,
    similarity_score, second_best_score,
    similarity_score - COALESCE(second_best_score, 0) AS score_margin,
    similarity_score >= 0.90
      AND similarity_score - COALESCE(second_best_score, 0) >= 0.08
FROM ranked
WHERE candidate_rank = 1;

CREATE TABLE IF NOT EXISTS analytics.client_fuzzy_match_cache (
    source_client_clean text PRIMARY KEY,
    client_code_clean text,
    client_name_clean text,
    similarity_score numeric,
    second_best_score numeric,
    score_margin numeric,
    is_auto_accepted boolean NOT NULL
);

TRUNCATE TABLE analytics.client_fuzzy_match_cache;

INSERT INTO analytics.client_fuzzy_match_cache (
    source_client_clean, client_code_clean, client_name_clean,
    similarity_score, second_best_score, score_margin, is_auto_accepted
)
WITH source_value AS (
    SELECT DISTINCT analytics.clean_name(j.client) AS source_client_clean
    FROM journal.t_item_journey j
    WHERE analytics.clean_name(j.client) IS NOT NULL
),
master_reference AS (
    SELECT DISTINCT analytics.clean_name(c.client_code) AS client_code_clean,
        analytics.clean_name(c.client_name) AS client_name_clean
    FROM master.t_mtr_client c
    WHERE analytics.clean_name(c.client_name) IS NOT NULL
),
scored AS (
    SELECT s.source_client_clean, r.client_code_clean, r.client_name_clean,
        analytics.fuzzy_similarity(
            s.source_client_clean, r.client_name_clean
        ) AS similarity_score
    FROM source_value s
    CROSS JOIN master_reference r
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.verified_client_alias alias_match
        WHERE alias_match.is_active
          AND analytics.clean_name(alias_match.source_value)
              = s.source_client_clean
    )
      AND NOT EXISTS (
        SELECT 1 FROM master_reference exact_match
        WHERE s.source_client_clean IN (
            exact_match.client_code_clean,
            exact_match.client_name_clean
        )
    )
),
ranked AS (
    SELECT scored.*,
        ROW_NUMBER() OVER (
            PARTITION BY source_client_clean
            ORDER BY similarity_score DESC, client_name_clean
        ) AS candidate_rank,
        LEAD(similarity_score) OVER (
            PARTITION BY source_client_clean
            ORDER BY similarity_score DESC, client_name_clean
        ) AS second_best_score
    FROM scored
)
SELECT source_client_clean, client_code_clean, client_name_clean,
    similarity_score, second_best_score,
    similarity_score - COALESCE(second_best_score, 0) AS score_margin,
    similarity_score >= 0.90
      AND similarity_score - COALESCE(second_best_score, 0) >= 0.08
FROM ranked
WHERE candidate_rank = 1;

-- Clean view utama. Setiap baris sumber tetap dipertahankan.
CREATE OR REPLACE VIEW analytics.item_journey_clean AS
WITH normalized AS (
    SELECT
        j.*,
        analytics.clean_code(j.item_category) AS item_category_clean,
        analytics.clean_code(j.item_type) AS item_type_clean,
        analytics.clean_code(j.item_model_code) AS item_model_code_clean,
        analytics.clean_code(j.item_pairing_code) AS item_pairing_code_clean,
        analytics.clean_code(j.host_serial_code) AS host_serial_code_clean,
        analytics.clean_name(j.client) AS client_clean,
        analytics.clean_code(j.ref_doc_code) AS ref_doc_code_clean,
        analytics.clean_code(j.wo_type) AS wo_type_clean,
        analytics.clean_code(j.wo_code) AS wo_code_clean,
        analytics.clean_code(j.place) AS place_clean,
        analytics.clean_code(j.activity) AS activity_clean,
        analytics.clean_code(j.status) AS status_clean,
        analytics.clean_name(j.done_by) AS done_by_clean,
        COUNT(*) OVER (PARTITION BY j.journey_id) > 1 AS is_duplicate_journey_id
    FROM journal.t_item_journey j
),
cleaned AS (
    SELECT
        n.*,
        COALESCE(
            n.item_pairing_code_clean,
            n.host_serial_code_clean,
            'JOURNEY#' || n.journey_id::text
        ) AS item_identifier_clean,
        ROW_NUMBER() OVER journey_order AS event_sequence_number,
        LAG(n.status_clean) OVER journey_order AS previous_status_clean,
        LEAD(n.status_clean) OVER journey_order AS next_status_clean,
        LAG(n.activity_clean) OVER journey_order AS previous_activity_clean,
        LEAD(n.activity_clean) OVER journey_order AS next_activity_clean,
        LAG(n.created_on) OVER journey_order AS previous_created_on
    FROM normalized n
    WINDOW journey_order AS (
        PARTITION BY COALESCE(
            n.item_pairing_code_clean,
            n.host_serial_code_clean,
            'JOURNEY#' || n.journey_id::text
        )
        ORDER BY n.created_on NULLS LAST, n.journey_id
    )
),
master_item AS (
    SELECT
        analytics.clean_code(m.item_model_code) AS item_model_code_clean,
        MAX(analytics.clean_code(m.item_type)) AS item_type_from_master,
        MAX(analytics.clean_code(m.item_category)) AS item_category_from_master
    FROM master.t_mtr_item m
    WHERE analytics.clean_code(m.item_model_code) IS NOT NULL
    GROUP BY analytics.clean_code(m.item_model_code)
),
inventory_identifier AS (
    SELECT DISTINCT
        analytics.clean_code(i.item_pairing_code) AS item_pairing_code_clean,
        analytics.clean_code(i.sn_ref) AS sn_ref_clean,
        CASE
            WHEN analytics.clean_code(i.item_model_code) IS NOT NULL
             AND analytics.clean_code(i.item_pairing_code) IS NOT NULL
             AND analytics.clean_code(i.repair_seq) IS NOT NULL
            THEN analytics.clean_code(
                i.item_model_code || '-' || i.item_pairing_code || '-' || i.repair_seq
            )
        END AS host_serial_code_clean,
        analytics.clean_code(i.item_model_code) AS item_model_code_clean
    FROM inventory.t_item i
),
inventory_pairing_lookup AS (
    -- Inventory diringkas satu kali agar setiap journey tidak melakukan
    -- correlated scan ke seluruh inventory.
    SELECT
        item_pairing_code_clean AS identifier_clean,
        COUNT(DISTINCT item_model_code_clean) AS nonnull_model_count,
        BOOL_OR(item_model_code_clean IS NULL) AS has_null_model,
        MIN(item_model_code_clean) AS only_model_code
    FROM inventory_identifier
    WHERE item_pairing_code_clean IS NOT NULL
    GROUP BY item_pairing_code_clean
),
inventory_host_lookup AS (
    SELECT
        value.identifier_clean,
        COUNT(DISTINCT i.item_model_code_clean) AS nonnull_model_count,
        BOOL_OR(i.item_model_code_clean IS NULL) AS has_null_model,
        MIN(i.item_model_code_clean) AS only_model_code
    FROM inventory_identifier i
    CROSS JOIN LATERAL (VALUES
        (i.host_serial_code_clean),
        (i.sn_ref_clean)
    ) value(identifier_clean)
    WHERE value.identifier_clean IS NOT NULL
    GROUP BY value.identifier_clean
),
inventory_model AS (
    SELECT DISTINCT item_model_code_clean
    FROM inventory_identifier
    WHERE item_model_code_clean IS NOT NULL
),
master_work_type AS (
    -- wo_type pada journey adalah sumber utama. Code dan nama master hanya
    -- membentuk representasi canonical, bukan mengganti nilai journey.
    SELECT
        work_type_value_clean,
        MIN(work_type_code_clean) AS work_type_code_clean,
        MIN(work_type_name_clean) AS work_type_name_clean
    FROM (
        SELECT
            analytics.clean_code(w.work_type_code) AS work_type_code_clean,
            analytics.clean_code(w.work_type) AS work_type_name_clean,
            value.work_type_value_clean
        FROM master.t_mtr_work_type w
        CROSS JOIN LATERAL (VALUES
            (analytics.clean_code(w.work_type_code)),
            (analytics.clean_code(w.work_type))
        ) value(work_type_value_clean)
        WHERE value.work_type_value_clean IS NOT NULL
    ) work_type_value
    GROUP BY work_type_value_clean
),
work_orders AS (
    -- Work order hanya dipakai sebagai validasi tambahan jika wo_code tersedia.
    SELECT DISTINCT ON (analytics.clean_code(wo.wo_code))
        analytics.clean_code(wo.wo_code) AS wo_code_clean,
        mwt.work_type_code_clean,
        mwt.work_type_name_clean
    FROM journal.t_work_order wo
    LEFT JOIN master_work_type mwt
        ON mwt.work_type_value_clean = analytics.clean_code(wo.work_type_code)
    WHERE analytics.clean_code(wo.wo_code) IS NOT NULL
    ORDER BY analytics.clean_code(wo.wo_code), wo.wo_id DESC
),
master_status AS (
    SELECT analytics.clean_code(s.status_code) AS status_clean
    FROM master.t_mtr_status s
    WHERE analytics.clean_code(s.status_code) IS NOT NULL
    UNION
    SELECT analytics.clean_code(s.status_name)
    FROM master.t_mtr_status s
    WHERE analytics.clean_code(s.status_name) IS NOT NULL
),
master_location_reference AS (
    SELECT DISTINCT
        analytics.clean_code(l.location_code) AS location_code_clean,
        analytics.clean_code(l.location_name) AS location_name_clean
    FROM master.t_mtr_location l
    WHERE analytics.clean_code(l.location_name) IS NOT NULL
),
master_location AS (
    -- Kode maupun nama sumber dipetakan ke satu nama master. Nilai sumber tetap
    -- disimpan di place_clean untuk audit; place_canonical_clean hanya terisi
    -- bila mapping master tidak ambigu.
    SELECT
        location_value_clean,
        MIN(location_code_clean) AS location_code_clean,
        MIN(location_name_clean) AS location_name_clean,
        COUNT(DISTINCT location_name_clean) AS location_name_count
    FROM (
        SELECT
            l.location_code_clean,
            l.location_name_clean,
            value.location_value_clean
        FROM master_location_reference l
        CROSS JOIN LATERAL (VALUES
            (l.location_code_clean),
            (l.location_name_clean)
        ) value(location_value_clean)
        WHERE value.location_value_clean IS NOT NULL
    ) location_value
    GROUP BY location_value_clean
),
verified_location_alias AS (
    -- Alias ini diterima berdasarkan konteks: 5.096 dari 5.611 item pada
    -- GUDANG NUTECH juga memiliki histori GUDANG NI dan alur gudangnya sama.
    SELECT analytics.clean_code(v.source_value) AS source_location_clean,
        r.location_code_clean, r.location_name_clean, v.mapping_basis,
        v.approved_by, v.approved_at
    FROM analytics.verified_location_alias v
    JOIN master_location_reference r
      ON r.location_name_clean = analytics.clean_code(v.canonical_value)
    WHERE v.is_active
),
location_fuzzy_best AS (
    SELECT * FROM analytics.location_fuzzy_match_cache
),
master_client_reference AS (
    SELECT DISTINCT analytics.clean_name(c.client_code) AS client_code_clean,
        analytics.clean_name(c.client_name) AS client_name_clean
    FROM master.t_mtr_client c
    WHERE analytics.clean_name(c.client_name) IS NOT NULL
),
master_client AS (
    SELECT client_value_clean,
        MIN(client_code_clean) AS client_code_clean,
        MIN(client_name_clean) AS client_name_clean,
        COUNT(DISTINCT client_name_clean) AS client_name_count
    FROM master_client_reference c
    CROSS JOIN LATERAL (VALUES
        (c.client_code_clean),
        (c.client_name_clean)
    ) value(client_value_clean)
    WHERE client_value_clean IS NOT NULL
    GROUP BY client_value_clean
),
verified_client_alias AS (
    SELECT analytics.clean_name(v.source_value) AS source_client_clean,
        r.client_code_clean, r.client_name_clean, v.mapping_basis,
        v.approved_by, v.approved_at
    FROM analytics.verified_client_alias v
    JOIN master_client_reference r
      ON r.client_name_clean = analytics.clean_name(v.canonical_value)
    WHERE v.is_active
),
client_fuzzy_best AS (
    SELECT * FROM analytics.client_fuzzy_match_cache
)
SELECT
    c.journey_id,
    c.item_category AS item_category_original,
    c.item_category_clean,
    c.item_type AS item_type_original,
    c.item_type_clean,
    c.item_model_code AS item_model_code_original,
    c.item_model_code_clean,
    c.item_pairing_code AS item_pairing_code_original,
    c.item_pairing_code_clean,
    c.host_serial_code AS host_serial_code_original,
    c.host_serial_code_clean,
    c.client AS client_original,
    c.client_clean,
    c.ref_doc_code AS ref_doc_code_original,
    c.ref_doc_code_clean,
    c.wo_type AS wo_type_original,
    c.wo_type_clean,
    c.wo_code AS wo_code_original,
    c.wo_code_clean,
    c.place AS place_original,
    c.place_clean,
    c.activity AS activity_original,
    c.activity_clean,
    c.status AS status_original,
    c.status_clean,
    c.done_by AS done_by_original,
    c.done_by_clean,
    analytics.clean_text(c.remark) AS remark,
    c.created_on,
    c.created_on::date AS created_date,
    EXTRACT(YEAR FROM c.created_on)::integer AS created_year,
    EXTRACT(MONTH FROM c.created_on)::integer AS created_month,
    DATE_TRUNC('month', c.created_on) AS created_year_month,
    c.created_by,
    c.created_on IS NOT NULL
        AND c.created_on::date >= DATE '1971-01-01' AS is_valid_date,
    c.created_on > CURRENT_TIMESTAMP AS is_future_date,
    c.created_on IS NULL
        OR c.created_on::date < DATE '1971-01-01'
        OR c.created_on > CURRENT_TIMESTAMP AS is_suspicious_date,
    c.item_pairing_code_clean IS NULL
        AND c.host_serial_code_clean IS NULL AS is_missing_item_identifier,
    pairing_inventory.identifier_clean IS NOT NULL
        OR host_inventory.identifier_clean IS NOT NULL AS is_item_found,
    inventory_model.item_model_code_clean IS NOT NULL
        AS is_item_model_in_inventory,
    mi.item_model_code_clean IS NOT NULL AS is_item_model_found,
    mi.item_type_from_master,
    mi.item_category_from_master,
    mi.item_model_code_clean IS NOT NULL
        AND c.item_type_clean IS NOT DISTINCT FROM mi.item_type_from_master
        AS is_item_type_consistent,
    mi.item_model_code_clean IS NOT NULL
        AND c.item_category_clean IS NOT DISTINCT FROM mi.item_category_from_master
        AS is_item_category_consistent,
    (pairing_inventory.identifier_clean IS NOT NULL
        OR host_inventory.identifier_clean IS NOT NULL)
    AND CASE
        WHEN pairing_inventory.identifier_clean IS NULL THEN TRUE
        WHEN c.item_model_code_clean IS NULL
            THEN pairing_inventory.nonnull_model_count = 0
        ELSE NOT pairing_inventory.has_null_model
         AND pairing_inventory.nonnull_model_count = 1
         AND pairing_inventory.only_model_code = c.item_model_code_clean
    END
    AND CASE
        WHEN host_inventory.identifier_clean IS NULL THEN TRUE
        WHEN c.item_model_code_clean IS NULL
            THEN host_inventory.nonnull_model_count = 0
        ELSE NOT host_inventory.has_null_model
         AND host_inventory.nonnull_model_count = 1
         AND host_inventory.only_model_code = c.item_model_code_clean
    END AS is_item_model_consistent,
    wo.wo_code_clean IS NOT NULL AS is_work_order_found,
    c.status_clean IS NULL
        OR ms.status_clean IS NOT NULL AS is_status_found,
    c.place_clean IS NULL
        OR CASE
            WHEN ml.location_name_count = 1 THEN ml.location_name_clean
            WHEN vla.source_location_clean IS NOT NULL THEN vla.location_name_clean
            WHEN lfb.is_auto_accepted THEN lfb.location_name_clean
        END IS NOT NULL AS is_place_found,
    c.is_duplicate_journey_id,
    CASE
        WHEN c.journey_id IS NULL OR c.is_duplicate_journey_id THEN 'CRITICAL'
        WHEN (c.item_pairing_code_clean IS NULL AND c.host_serial_code_clean IS NULL)
          OR mi.item_model_code_clean IS NULL
          OR (c.wo_code_clean IS NOT NULL AND wo.wo_code_clean IS NULL)
          OR c.created_on IS NULL
          OR c.created_on::date < DATE '1971-01-01'
          OR c.created_on > CURRENT_TIMESTAMP
          OR (c.status_clean IS NOT NULL AND ms.status_clean IS NULL)
          OR (
              c.place_clean IS NOT NULL
              AND CASE
                  WHEN ml.location_name_count = 1 THEN ml.location_name_clean
                  WHEN vla.source_location_clean IS NOT NULL
                      THEN vla.location_name_clean
                  WHEN lfb.is_auto_accepted THEN lfb.location_name_clean
              END IS NULL
          )
          OR (
              c.client_clean IS NOT NULL
              AND CASE
                  WHEN mc.client_name_count = 1 THEN mc.client_name_clean
                  WHEN vca.source_client_clean IS NOT NULL
                      THEN vca.client_name_clean
                  WHEN cfb.is_auto_accepted THEN cfb.client_name_clean
              END IS NULL
          )
          OR (c.wo_type_clean IS NOT NULL AND journey_wt.work_type_value_clean IS NULL)
          OR (
              c.wo_type_clean IS NOT NULL
              AND c.wo_code_clean IS NOT NULL
              AND wo.wo_code_clean IS NOT NULL
              AND journey_wt.work_type_code_clean IS NOT NULL
              AND wo.work_type_code_clean IS NOT NULL
              AND journey_wt.work_type_code_clean <> wo.work_type_code_clean
          )
        THEN 'WARNING'
        ELSE 'OK'
    END AS data_quality_status,
    c.client_clean IS NULL
        OR CASE
            WHEN mc.client_name_count = 1 THEN mc.client_name_clean
            WHEN vca.source_client_clean IS NOT NULL THEN vca.client_name_clean
            WHEN cfb.is_auto_accepted THEN cfb.client_name_clean
        END IS NOT NULL AS is_client_found,
    c.wo_type_clean IS NULL
        OR journey_wt.work_type_value_clean IS NOT NULL AS is_work_type_found,
    c.item_identifier_clean,
    c.event_sequence_number,
    c.previous_status_clean,
    c.next_status_clean,
    c.previous_activity_clean,
    c.next_activity_clean,
    c.previous_created_on,
    EXTRACT(EPOCH FROM (c.created_on - c.previous_created_on)) / 86400.0
        AS days_since_previous_event,
    journey_wt.work_type_code_clean AS journey_work_type_code_clean,
    journey_wt.work_type_name_clean AS journey_work_type_name_clean,
    wo.work_type_code_clean AS work_order_work_type_code_clean,
    wo.work_type_name_clean AS work_order_work_type_name_clean,
    CASE
        WHEN c.wo_type_clean IS NULL
          OR c.wo_code_clean IS NULL
          OR wo.wo_code_clean IS NULL
        THEN NULL
        WHEN journey_wt.work_type_code_clean IS NULL
          OR wo.work_type_code_clean IS NULL
        THEN FALSE
        ELSE journey_wt.work_type_code_clean = wo.work_type_code_clean
    END AS is_work_type_consistent,
    CASE
        WHEN ml.location_name_count = 1 THEN ml.location_code_clean
        WHEN vla.source_location_clean IS NOT NULL THEN vla.location_code_clean
        WHEN lfb.is_auto_accepted THEN lfb.location_code_clean
    END AS place_master_code_clean,
    CASE
        WHEN ml.location_name_count = 1 THEN ml.location_name_clean
        WHEN vla.source_location_clean IS NOT NULL THEN vla.location_name_clean
        WHEN lfb.is_auto_accepted THEN lfb.location_name_clean
    END AS place_master_name_clean,
    CASE
        WHEN ml.location_name_count = 1 THEN ml.location_name_clean
        WHEN vla.source_location_clean IS NOT NULL THEN vla.location_name_clean
        WHEN lfb.is_auto_accepted THEN lfb.location_name_clean
    END AS place_canonical_clean,
    COALESCE(ml.location_name_count > 1, FALSE)
      OR COALESCE(
          NOT lfb.is_auto_accepted AND lfb.score_margin < 0.08,
          FALSE
      ) AS is_place_mapping_ambiguous,
    CASE
        WHEN c.place_clean IS NULL THEN 'MISSING'
        WHEN ml.location_name_count = 1 THEN 'EXACT'
        WHEN ml.location_name_count > 1 THEN 'AMBIGUOUS_EXACT'
        WHEN vla.source_location_clean IS NOT NULL THEN 'VERIFIED_CONTEXT_ALIAS'
        WHEN lfb.is_auto_accepted THEN 'FUZZY_AUTO_ACCEPTED'
        WHEN lfb.source_location_clean IS NOT NULL THEN 'FUZZY_REVIEW'
        ELSE 'UNMATCHED'
    END AS place_mapping_method,
    COALESCE(
        CASE WHEN ml.location_name_count = 1 THEN 1.0::numeric END,
        CASE WHEN vla.source_location_clean IS NOT NULL
            THEN analytics.fuzzy_similarity(c.place_clean, vla.location_name_clean) END,
        lfb.similarity_score
    ) AS place_fuzzy_score,
    lfb.score_margin AS place_fuzzy_margin,
    COALESCE(lfb.is_auto_accepted, FALSE) AS is_place_fuzzy_accepted,
    CASE
        WHEN mc.client_name_count = 1 THEN mc.client_code_clean
        WHEN vca.source_client_clean IS NOT NULL THEN vca.client_code_clean
        WHEN cfb.is_auto_accepted THEN cfb.client_code_clean
    END AS client_master_code_clean,
    CASE
        WHEN mc.client_name_count = 1 THEN mc.client_name_clean
        WHEN vca.source_client_clean IS NOT NULL THEN vca.client_name_clean
        WHEN cfb.is_auto_accepted THEN cfb.client_name_clean
    END AS client_master_name_clean,
    CASE
        WHEN mc.client_name_count = 1 THEN mc.client_name_clean
        WHEN vca.source_client_clean IS NOT NULL THEN vca.client_name_clean
        WHEN cfb.is_auto_accepted THEN cfb.client_name_clean
    END AS client_canonical_clean,
    CASE
        WHEN c.client_clean IS NULL THEN 'MISSING'
        WHEN mc.client_name_count = 1 THEN 'EXACT'
        WHEN mc.client_name_count > 1 THEN 'AMBIGUOUS_EXACT'
        WHEN vca.source_client_clean IS NOT NULL THEN 'VERIFIED_CONTEXT_ALIAS'
        WHEN cfb.is_auto_accepted THEN 'FUZZY_AUTO_ACCEPTED'
        WHEN cfb.source_client_clean IS NOT NULL THEN 'FUZZY_REVIEW'
        ELSE 'UNMATCHED'
    END AS client_mapping_method,
    COALESCE(
        CASE WHEN mc.client_name_count = 1 THEN 1.0::numeric END,
        CASE WHEN vca.source_client_clean IS NOT NULL
            THEN analytics.fuzzy_similarity(c.client_clean, vca.client_name_clean) END,
        cfb.similarity_score
    ) AS client_fuzzy_score,
    cfb.score_margin AS client_fuzzy_margin,
    COALESCE(cfb.is_auto_accepted, FALSE) AS is_client_fuzzy_accepted,
    COALESCE(mc.client_name_count > 1, FALSE)
      OR COALESCE(
          NOT cfb.is_auto_accepted AND cfb.score_margin < 0.08,
          FALSE
      ) AS is_client_mapping_ambiguous,
    lfb.location_code_clean AS place_fuzzy_candidate_code_clean,
    lfb.location_name_clean AS place_fuzzy_candidate_name_clean,
    cfb.client_code_clean AS client_fuzzy_candidate_code_clean,
    cfb.client_name_clean AS client_fuzzy_candidate_name_clean,
    vla.mapping_basis AS place_verified_mapping_basis,
    vla.approved_by AS place_mapping_approved_by,
    vla.approved_at AS place_mapping_approved_at,
    vca.mapping_basis AS client_verified_mapping_basis,
    vca.approved_by AS client_mapping_approved_by,
    vca.approved_at AS client_mapping_approved_at
FROM cleaned c
LEFT JOIN master_item mi
    ON mi.item_model_code_clean = c.item_model_code_clean
LEFT JOIN inventory_pairing_lookup pairing_inventory
    ON pairing_inventory.identifier_clean = c.item_pairing_code_clean
LEFT JOIN inventory_host_lookup host_inventory
    ON host_inventory.identifier_clean = c.host_serial_code_clean
LEFT JOIN inventory_model
    ON inventory_model.item_model_code_clean = c.item_model_code_clean
LEFT JOIN work_orders wo
    ON wo.wo_code_clean = c.wo_code_clean
LEFT JOIN master_status ms
    ON ms.status_clean = c.status_clean
LEFT JOIN master_location ml
    ON ml.location_value_clean = c.place_clean
LEFT JOIN verified_location_alias vla
    ON vla.source_location_clean = c.place_clean
LEFT JOIN location_fuzzy_best lfb
    ON lfb.source_location_clean = c.place_clean
LEFT JOIN master_client mc
    ON mc.client_value_clean = c.client_clean
LEFT JOIN verified_client_alias vca
    ON vca.source_client_clean = c.client_clean
LEFT JOIN client_fuzzy_best cfb
    ON cfb.source_client_clean = c.client_clean
LEFT JOIN master_work_type journey_wt
    ON journey_wt.work_type_value_clean = c.wo_type_clean;

-- Profil transisi berdasarkan urutan aktual item. Ini tidak memberi label bisnis
-- seperti failure/normal; hanya merangkum status yang benar-benar muncul berurutan.
CREATE OR REPLACE VIEW analytics.item_journey_transition_profile_live AS
WITH ordered AS (
    SELECT
        j.*,
        LAG(j.status_clean) OVER (
            PARTITION BY j.item_identifier_clean
            ORDER BY j.created_on NULLS LAST, j.journey_id
        ) AS status_before_current
    FROM analytics.item_journey_clean j
    WHERE j.is_valid_date
      AND NOT j.is_future_date
),
status_changes AS (
    SELECT *
    FROM ordered
    WHERE status_clean IS NOT NULL
      AND status_clean IS DISTINCT FROM status_before_current
),
transitions AS (
    SELECT
        item_category_clean,
        item_type_clean,
        wo_type_clean,
        status_clean AS from_status,
        LEAD(status_clean) OVER transition_order AS to_status,
        created_on AS from_created_on,
        LEAD(created_on) OVER transition_order AS to_created_on
    FROM status_changes
    WINDOW transition_order AS (
        PARTITION BY item_identifier_clean
        ORDER BY created_on NULLS LAST, journey_id
    )
)
SELECT
    item_category_clean,
    item_type_clean,
    wo_type_clean,
    from_status,
    to_status,
    COUNT(*) AS transition_count,
    ROUND((
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (to_created_on - from_created_on)) / 86400.0
        )
    )::numeric, 2) AS median_days_to_next_status,
    MIN(from_created_on) AS first_seen_on,
    MAX(from_created_on) AS last_seen_on
FROM transitions
WHERE to_status IS NOT NULL
GROUP BY
    item_category_clean,
    item_type_clean,
    wo_type_clean,
    from_status,
    to_status;

DO $migration$
DECLARE
    object_kind "char";
BEGIN
    SELECT c.relkind
    INTO object_kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics'
      AND c.relname = 'item_journey_transition_profile';

    IF object_kind = 'v' THEN
        EXECUTE 'DROP VIEW analytics.item_journey_transition_profile';
    ELSIF object_kind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW analytics.item_journey_transition_profile';
    END IF;
END;
$migration$;

CREATE MATERIALIZED VIEW analytics.item_journey_transition_profile AS
SELECT * FROM analytics.item_journey_transition_profile_live;

CREATE INDEX item_journey_transition_lookup_idx
    ON analytics.item_journey_transition_profile (
        item_category_clean,
        item_type_clean,
        wo_type_clean,
        from_status,
        to_status
    );
