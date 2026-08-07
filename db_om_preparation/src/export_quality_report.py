"""Ekspor profiling dan ringkasan data quality ke CSV."""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

from database import PROJECT_DIR, connect


EXPORTS = {
    "data_profile.csv": """
        SELECT table_name, column_name, quality_check, metric_value, details
        FROM analytics.data_profile
        ORDER BY table_name, column_name NULLS FIRST, quality_check
    """,
    "data_quality_summary.csv": """
        SELECT table_name, quality_check, total_rows, failed_rows,
               failed_percentage, severity, description
        FROM analytics.data_quality_summary
        ORDER BY CASE severity
            WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
            failed_percentage DESC NULLS LAST, table_name, quality_check
    """,
}


def csv_value(value: object) -> object:
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, default=str)
    return value


def main() -> int:
    reports_dir = PROJECT_DIR / "reports"
    reports_dir.mkdir(exist_ok=True)
    try:
        with connect() as conn:
            with conn.cursor() as cursor:
                for filename, query in EXPORTS.items():
                    print(f"[RUN] Mengekspor cache {filename}...", flush=True)
                    cursor.execute(query)
                    output_path = reports_dir / filename
                    with output_path.open("w", newline="", encoding="utf-8-sig") as output:
                        writer = csv.writer(output)
                        writer.writerow(column.name for column in cursor.description)
                        writer.writerows(
                            [csv_value(value) for value in row]
                            for row in cursor.fetchall()
                        )
                    print(f"Sudah berhasil terdownload {output_path}")
        return 0
    except Exception as exc:
        print(f"[ERROR] Ekspor gagal: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
