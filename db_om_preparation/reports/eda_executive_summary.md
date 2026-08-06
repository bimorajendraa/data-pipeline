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

## Keputusan sebelum baseline

1. Gunakan split waktu train 2014-2024, validation 2025, dan test 2026 dengan
   embargo target 30 hari; jangan gunakan random split.
2. Gunakan feature whitelist dari `analytics.item_observation_30d_features` dan
   label dari `analytics.item_observation_30d_labels`.
3. Nilai utama model: PR-AUC, recall, precision, ROC-AUC, calibration, confusion
   matrix, dan jumlah alarm per 1.000 snapshot; accuracy tidak berdiri sendiri.
4. Audit missing struktural, redundansi, IV tinggi, dan drift sebelum memilih
   fitur baseline.

## Status

Data siap dilanjutkan ke **feature engineering dan baseline modeling**, tetapi
belum dinyatakan siap produksi. Detail tabel, grafik, IV, korelasi, lifecycle,
dan PSI tersedia di `reports/failure_eda.html`.
