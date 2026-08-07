"""Validasi kontrak feature-only, label, dan katalog modeling."""

from __future__ import annotations

from database import connect


def main() -> int:
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT metric, value, expectation
                FROM analytics.failure_30d_feature_quality_summary
                ORDER BY metric
            """)
            quality = cur.fetchall()

            cur.execute("""
                SELECT decision, COUNT(*)
                FROM analytics.failure_30d_feature_catalog
                GROUP BY decision
                ORDER BY decision
            """)
            catalog = cur.fetchall()

            cur.execute("""
                SELECT c.relname AS table_name,
                    COUNT(*) FILTER (WHERE a.attname NOT IN (
                        'installation_cycle_id', 'item_identifier_clean',
                        'observation_on'
                    )) AS predictor_count,
                    COUNT(*) FILTER (WHERE a.attname ~
                        '(target|future|next_failure|cycle_end|observable)'
                    ) AS leakage_name_count
                FROM pg_catalog.pg_attribute a
                JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'analytics'
                  AND c.relname IN (
                      'failure_30d_baseline_features',
                      'failure_30d_challenger_features'
                  )
                  AND c.relkind IN ('v', 'm')
                  AND a.attnum > 0
                  AND NOT a.attisdropped
                GROUP BY c.relname
                ORDER BY table_name
            """)
            columns = cur.fetchall()

    print("QUALITY")
    for row in quality:
        print(row)
    print("CATALOG")
    for row in catalog:
        print(row)
    print("COLUMNS")
    for row in columns:
        print(row)

    quality_by_metric = {metric: value for metric, value, _ in quality}
    column_by_view = {
        table: (predictor_count, leakage_count)
        for table, predictor_count, leakage_count in columns
    }
    checks = [
        quality_by_metric.get("baseline_feature_rows")
        == quality_by_metric.get("label_rows"),
        quality_by_metric.get("duplicate_feature_keys") == 0,
        quality_by_metric.get("null_core_categories") == 0,
        quality_by_metric.get("null_engineered_numeric") == 0,
        column_by_view.get("failure_30d_baseline_features") == (16, 0),
        column_by_view.get("failure_30d_challenger_features") == (26, 0),
    ]
    if not all(checks):
        raise RuntimeError("Kontrak feature engineering tidak terpenuhi")
    print("[OK] Seluruh kontrak feature engineering terpenuhi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
