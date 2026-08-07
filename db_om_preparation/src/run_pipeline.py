"""Jalankan file SQL secara berurutan dengan transaksi per file."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from database import PROJECT_DIR, connect


SQL_FILES = [
    "01_create_analytics_schema.sql",
    "02_data_profiling.sql",
    "03_item_journey_clean.sql",
    "04_item_clean.sql",
    "05_work_order_clean.sql",
    "06_work_order_history_clean.sql",
    "07_mtbf_clean.sql",
    "08_data_quality_summary.sql",
    "09_failure_event_label.sql",
    "10_operational_timeline.sql",
    "11_item_installation_cycle.sql",
    "12_item_observation_dataset.sql",
    "13_eda_views.sql",
    "14_feature_engineering.sql",
]

# Guard tambahan: file pipeline tidak boleh menulis ke tiga schema sumber.
FORBIDDEN_SOURCE_WRITE = re.compile(
    r"\b(?:update|delete\s+from|insert\s+into|truncate(?:\s+table)?|"
    r"alter\s+table|drop\s+table)\s+(?:journal|inventory|master)\s*\.",
    re.IGNORECASE,
)
FORBIDDEN_DATABASE_DDL = re.compile(
    r"\b(?:create|alter|drop)\s+database\b",
    re.IGNORECASE,
)


def validate_sql(sql_text: str, filename: str) -> None:
    if FORBIDDEN_SOURCE_WRITE.search(sql_text):
        raise RuntimeError(
            f"{filename} ditolak: ditemukan perintah tulis terhadap schema sumber."
        )
    if FORBIDDEN_DATABASE_DDL.search(sql_text):
        raise RuntimeError(
            f"{filename} ditolak: pipeline tidak boleh membuat atau mengubah database."
        )


def main() -> int:
    sql_dir = PROJECT_DIR / "sql"
    try:
        with connect() as conn:
            for filename in SQL_FILES:
                path = sql_dir / filename
                sql_text = path.read_text(encoding="utf-8")
                validate_sql(sql_text, filename)
                print(f"[RUN] {filename}")
                try:
                    with conn.cursor() as cursor:
                        cursor.execute(sql_text, prepare=False)
                    conn.commit()
                except Exception:
                    conn.rollback()
                    raise
                print(f"[OK ] {filename}")

            print(
                "\nPipeline selesai. Clean view, cache analytics, dan dataset EDA "
                "sudah siap. Buka notebooks/01_failure_eda.ipynb untuk EDA."
            )
        return 0
    except Exception as exc:
        print(f"[ERROR] Pipeline gagal: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
