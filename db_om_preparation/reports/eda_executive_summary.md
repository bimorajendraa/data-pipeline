# Ringkasan Eksekutif EDA OMEXP

Ringkasan ini dibuat otomatis dari view `analytics` ketika laporan EDA diekspor.
Cutoff data operasional: **03-08-2026**.

## Objective

Menilai apakah histori journey PART cukup konsisten untuk membentuk dataset
prediksi failure dalam 30 hari, menemukan pola menurut waktu/model/lokasi dan
riwayat operasional, serta menentukan data dan fitur yang layak diteruskan ke
baseline model.

## Angka utama

| Metrik | Nilai |
|---|---:|
| Seluruh journey | 189.865 |
| Event operasional | 159.321 |
| Installation cycle | 24.045 |
| Failure terkonfirmasi | 6.715 |
| Snapshot layak training | 1.324.145 |
| Positif failure <=30 hari | 5.876 |
| Negatif dengan follow-up layak | 1.318.269 |
| Positive rate | 0.4438% |

## Ground truth dan quality gate

- Corrective dismantle: **6.714** failure.
- Preventive yang kemudian dikonfirmasi rusak: **1** failure.
- `RETURNED`, relocation, RECON, dan `NEED REPAIR` tidak membuka label failure.
- **1.185 cycle** reinstall tanpa failure tercatat
  diberi status unknown dan tidak otomatis menjadi negatif.
- **16.754 cycle** right-censored mempunyai
  coverage aktivitas yang belum dapat dikonfirmasi; tersedia flag untuk analisis
  sensitivitas konservatif.

## Master data

- Lokasi unmatched: **174 snapshot (0.0131%)**.
- Client unmatched: **0 snapshot (0.0000%)**.
- Nilai mentah, canonical, metode mapping, dan approval alias tetap tersedia
  untuk audit.

## Hierarki PART-TERMINAL

- Snapshot dengan parent TERMINAL valid: **1.323.877
  (99.9798%)**.
- Tipe TERMINAL mempunyai asosiasi bivariat kecil terhadap target
  (Cramer's V **0.0683**).
- Model PART dan tipe TERMINAL berasosiasi kuat
  (Cramer's V **0.7055**), sehingga rate per terminal
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

- Cache baseline berisi **1.406.086 snapshot** dan
  **16 fitur**.
- **10 fitur
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
