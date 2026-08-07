"""Eksekusi notebook EDA dan ekspor hasilnya menjadi HTML."""

from __future__ import annotations

import subprocess
import sys

from database import PROJECT_DIR, connect


def _format_number(value: int | float) -> str:
    return f"{value:,.0f}".replace(",", ".")


def export_executive_summary(output_path) -> None:
    """Buat ringkasan langsung dari view terbaru agar tidak tertinggal dari SQL."""
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    (SELECT COUNT(*) FROM analytics.item_journey_clean),
                    (SELECT COUNT(*) FROM analytics.item_journey_operational_timeline),
                    (SELECT COUNT(*) FROM analytics.item_installation_cycle),
                    (SELECT COUNT(*) FROM analytics.failure_event_clean),
                    (SELECT COUNT(*) FROM analytics.item_observation_30d
                     WHERE is_training_eligible),
                    (SELECT COUNT(*) FROM analytics.item_observation_30d
                     WHERE is_training_eligible AND target_failure_30d),
                    (SELECT MAX(created_on)::date
                     FROM analytics.item_journey_operational_timeline),
                    (SELECT COUNT(*)
                     FROM analytics.eda_item_observation_30d_hierarchy
                     WHERE is_training_eligible AND is_parent_link_valid),
                    (SELECT cramers_v
                     FROM analytics.eda_bivariate_association_summary
                     WHERE association = 'TERMINAL_TYPE_VS_TARGET'),
                    (SELECT cramers_v
                     FROM analytics.eda_bivariate_association_summary
                     WHERE association = 'PART_MODEL_VS_TERMINAL_TYPE')
            """)
            (journey, operational, cycles, failures, eligible, positives, cutoff,
             terminal_linked, terminal_target_v,
             part_terminal_v) = cur.fetchone()

            cur.execute("""
                SELECT cycle_quality_status, COUNT(*)
                FROM analytics.item_installation_cycle
                GROUP BY cycle_quality_status
            """)
            cycle_quality = dict(cur.fetchall())

            cur.execute("""
                SELECT feature_name, unmatched_snapshot, unmatched_percentage
                FROM analytics.eda_snapshot_master_coverage
            """)
            coverage = {row[0]: row[1:] for row in cur.fetchall()}

            cur.execute("""
                SELECT event_label_basis, COUNT(*)
                FROM analytics.failure_event_clean
                GROUP BY event_label_basis
            """)
            failure_basis = dict(cur.fetchall())

            cur.execute("""
                SELECT decision, COUNT(*)
                FROM analytics.failure_30d_feature_catalog
                GROUP BY decision
            """)
            feature_decisions = dict(cur.fetchall())

            cur.execute("""
                SELECT COUNT(*)
                FROM analytics.failure_30d_baseline_features
            """)
            engineered_rows = cur.fetchone()[0]

    negatives = eligible - positives
    positive_rate = 100.0 * positives / eligible if eligible else 0
    terminal_coverage = 100.0 * terminal_linked / eligible if eligible else 0
    reinstall_unknown = cycle_quality.get(
        "UNKNOWN_REINSTALL_WITHOUT_RECORDED_FAILURE", 0
    )
    coverage_unconfirmed = cycle_quality.get(
        "RIGHT_CENSORED_ACTIVITY_COVERAGE_UNCONFIRMED", 0
    )
    location_unmatched, location_pct = coverage.get("LOCATION", (0, 0))
    client_unmatched, client_pct = coverage.get("CLIENT", (0, 0))

    content = f"""# Ringkasan Eksekutif EDA OMEXP

Ringkasan ini dibuat otomatis dari view `analytics` ketika laporan EDA diekspor.
Cutoff data operasional: **{cutoff:%d-%m-%Y}**.

## Objective

Menilai apakah histori journey PART cukup konsisten untuk membentuk dataset
prediksi failure dalam 30 hari, menemukan pola menurut waktu/model/lokasi dan
riwayat operasional, serta menentukan data dan fitur yang layak diteruskan ke
baseline model.

## Angka utama

| Metrik | Nilai |
|---|---:|
| Seluruh journey | {_format_number(journey)} |
| Event operasional | {_format_number(operational)} |
| Installation cycle | {_format_number(cycles)} |
| Failure terkonfirmasi | {_format_number(failures)} |
| Snapshot layak training | {_format_number(eligible)} |
| Positif failure <=30 hari | {_format_number(positives)} |
| Negatif dengan follow-up layak | {_format_number(negatives)} |
| Positive rate | {positive_rate:.4f}% |

## Ground truth dan quality gate

- Corrective dismantle: **{_format_number(failure_basis.get('CONFIRMED_CORRECTIVE_DISMANTLE', 0))}** failure.
- Preventive yang kemudian dikonfirmasi rusak: **{_format_number(failure_basis.get('CONFIRMED_FAILURE_OUTCOME_AFTER_PREVENTIVE', 0))}** failure.
- `RETURNED`, relocation, RECON, dan `NEED REPAIR` tidak membuka label failure.
- **{_format_number(reinstall_unknown)} cycle** reinstall tanpa failure tercatat
  diberi status unknown dan tidak otomatis menjadi negatif.
- **{_format_number(coverage_unconfirmed)} cycle** right-censored mempunyai
  coverage aktivitas yang belum dapat dikonfirmasi; tersedia flag untuk analisis
  sensitivitas konservatif.

## Master data

- Lokasi unmatched: **{_format_number(location_unmatched)} snapshot ({float(location_pct):.4f}%)**.
- Client unmatched: **{_format_number(client_unmatched)} snapshot ({float(client_pct):.4f}%)**.
- Nilai mentah, canonical, metode mapping, dan approval alias tetap tersedia
  untuk audit.

## Hierarki PART-TERMINAL

- Snapshot dengan parent TERMINAL valid: **{_format_number(terminal_linked)}
  ({terminal_coverage:.4f}%)**.
- Tipe TERMINAL mempunyai asosiasi bivariat kecil terhadap target
  (Cramer's V **{float(terminal_target_v):.4f}**).
- Model PART dan tipe TERMINAL berasosiasi kuat
  (Cramer's V **{float(part_terminal_v):.4f}**), sehingga rate per terminal
  tidak boleh diartikan sebagai efek independen tanpa adjustment multivariat.
- Notebook membandingkan Logistic Regression bertingkat: PART-only,
  PART+TERMINAL, dan adjusted operational history dengan split waktu.

## Keputusan sebelum baseline

1. Gunakan split waktu train 2014-2024, validation 2025, dan test 2026 dengan
   embargo target 30 hari; jangan gunakan random split.
2. Gunakan feature-only cache `analytics.failure_30d_baseline_features` dan
   label terpisah dari `analytics.failure_30d_model_labels`.
3. Nilai utama model: PR-AUC, recall, precision, ROC-AUC, calibration, confusion
   matrix, dan jumlah alarm per 1.000 snapshot; accuracy tidak berdiri sendiri.
4. Audit missing struktural, redundansi, IV tinggi, dan drift sebelum memilih
   fitur baseline.

## Feature engineering

- Cache baseline berisi **{_format_number(engineered_rows)} snapshot** dan
  **{_format_number(feature_decisions.get('KEEP_BASELINE', 0))} fitur**.
- **{_format_number(feature_decisions.get('KEEP_CHALLENGER', 0))} fitur
  challenger** disediakan untuk pengujian incremental, bukan dicampurkan
  langsung ke baseline.
- Transformasi utama: `log1p` untuk count/duration yang skewed, indikator
  histori untuk missing struktural, bin umur, serta sin-cos bulan.
- Identifier, timestamp absolut, fitur lemah/redundan, kualitas relasi, dan
  seluruh kolom future/observability tidak menjadi predictor baseline.
- Keputusan lengkap dan alasannya tersedia pada
  `analytics.failure_30d_feature_catalog`.

## Status

Feature engineering baseline selesai dan data siap dilanjutkan ke **baseline
modeling**, tetapi belum dinyatakan siap produksi. Detail tabel, grafik, IV,
korelasi, lifecycle, PSI, dan keputusan fitur tersedia di
`reports/failure_eda.html`.
"""
    output_path.write_text(content, encoding="utf-8")


def main() -> int:
    notebook = PROJECT_DIR / "notebooks" / "01_failure_eda.ipynb"
    output_dir = PROJECT_DIR / "reports"
    output_dir.mkdir(exist_ok=True)
    command = [
        sys.executable, "-m", "jupyter", "nbconvert", "--to", "html",
        "--execute", str(notebook), "--output", "failure_eda.html",
        "--output-dir", str(output_dir),
        "--ExecutePreprocessor.timeout=600",
    ]
    result = subprocess.run(command, cwd=PROJECT_DIR, check=False)
    if result.returncode:
        print("[ERROR] Notebook EDA gagal dieksekusi.", file=sys.stderr)
        return result.returncode
    summary_path = output_dir / "eda_executive_summary.md"
    export_executive_summary(summary_path)
    print(f"[OK] Laporan EDA: {output_dir / 'failure_eda.html'}")
    print(f"[OK] Ringkasan EDA: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
