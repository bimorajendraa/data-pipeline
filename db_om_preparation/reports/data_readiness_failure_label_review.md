# Data Readiness & Failure Label Review

Tanggal analisis: 2026-08-05  
Database: `OMEXP`

## Status

Lapisan data cleaning dan preparation sudah tersedia. Review ini menilai apakah
hasilnya sudah layak diteruskan menjadi label kerusakan untuk model prediktif.
Keputusan bisnis sudah dikonfirmasi dan label event disediakan melalui
`analytics.item_journey_failure_labeled` serta cache
`analytics.failure_event_clean`.

## Temuan data quality utama

- Tidak ada quality check berstatus `CRITICAL` yang gagal.
- Seluruh 189.865 journey memiliki identifier; tidak ada identifier yang gagal
  ditemukan pada inventory.
- 73 journey memiliki tanggal sebelum 1971 dan 2 journey bertanggal masa depan.
  Record ini harus dikeluarkan dari perhitungan temporal model.
- 732 journey memiliki model item yang tidak konsisten dengan inventory. Record
  tersebut perlu mapping/review atau dikeluarkan dari dataset model.
- 13.195 work type yang ditandai tidak konsisten seluruhnya memiliki pola
  `journey=INSTALLATION` dan `work_order=RECON`. Pola ini kemungkinan merupakan
  tahap pemasangan dalam pekerjaan recon, bukan kesalahan data. Jangan keluarkan
  record ini sebelum ada konfirmasi proses bisnis.
- Seluruh 58.645 journey dengan typo client `KERETE COMMUTER INDONESIA (KCI)`
  sudah dipetakan ke nama master melalui fuzzy matching dengan skor dan margin
  aman. Sebanyak 8.567 event `GUDANG NUTECH` juga sudah dipetakan secara
  kontekstual ke `GUDANG NI`. Hanya 15 event `NOC JUANDA` yang tetap ditahan
  untuk review dan tidak digunakan sebagai fitur lokasi.

## Kandidat titik awal kerusakan

Kandidat paling konsisten secara historis:

```text
status_clean = DISMANTLED
AND wo_type_clean = CORRECTIVE
AND is_valid_date = TRUE
AND is_future_date = FALSE
```

Dasar pemilihan:

- Tersedia sejak 2013 sampai 2026, sehingga cakupannya lebih panjang daripada
  status repair detail.
- Terdapat 6.715 kejadian pada 4.153 item setelah satu preventive dismantle
  dikonfirmasi `UNREPAIRABLE` sebelum installation berikutnya.
- Sebanyak 5.986 kejadian langsung didahului status `INSTALLED`.
- Median waktu dari event sebelumnya untuk jalur `INSTALLED -> DISMANTLED
  (CORRECTIVE)` sekitar 344,82 hari.
- Pada kategori PART, 4.124 dari 23.564 item (17,50%) pernah mengalami kandidat
  kejadian ini.
- Pada kategori TERMINAL, hanya 29 dari 2.833 item (1,02%) yang mengalaminya.

## Kejadian berulang

Untuk PART yang pernah mengalami corrective dismantle:

- 2.872 item memiliki 1 kejadian;
- 685 item memiliki 2 kejadian;
- 566 item memiliki 3 kejadian atau lebih;
- maksimum yang ditemukan adalah 16 kejadian pada satu item.

Data kejadian berulang ini cukup berguna untuk fitur histori kerusakan dan
analisis time-to-event.

## Mengapa status repair detail belum menjadi label utama

`NEED REPAIR`, `REPAIRING`, dan `UNREPAIRABLE` baru tercatat secara rinci sejak
2025. Menggunakannya sebagai satu-satunya label akan membuat periode sebelum
2025 terlihat seolah-olah tidak memiliki kerusakan. Status tersebut lebih cocok
dipakai sebagai sinyal konfirmasi pada data terbaru.

`DISMANTLED` tanpa konteks juga tidak boleh dianggap kerusakan karena ditemukan
pada pekerjaan `RECON`, `PREVENTIVE`, `DISMANTLE`, dan flow pemasangan kembali.

## Rekomendasi cohort model pertama

Mulai dari kategori `PART`. Jumlah kejadian pada TERMINAL terlalu kecil dan pola
operasionalnya berbeda, sehingga sebaiknya dibuat analisis/model terpisah.

Record yang sementara dikeluarkan dari dataset temporal:

- tanggal sebelum 1971;
- tanggal masa depan;
- model item tidak konsisten, sampai mapping selesai.

Nilai client/lokasi mentah tetap dipertahankan untuk audit. Nama canonical yang
sudah lolos exact match, fuzzy aman, atau alias kontekstual boleh diuji sebagai
fitur; 15 event `NOC JUANDA` tetap tidak digunakan sebagai fitur lokasi sampai
review manual selesai.

## Keputusan bisnis terkonfirmasi

1. `DISMANTLED + CORRECTIVE` berarti item dilepas karena gangguan/kerusakan dan
   menjadi failure onset.
2. Work order corrective dapat memiliki aktivitas lain, tetapi kombinasi dengan
   dismantle tetap menjadi onset yang terkonfirmasi.
3. `RECON` merupakan kegiatan terencana dan menjadi konteks non-failure.
4. `DISMANTLED + PREVENTIVE` tetap non-failure kecuali sebelum installation
   berikutnya terdapat `BROKEN`, `SENDLOG (BROKEN)`, atau `UNREPAIRABLE`. Pada
   kondisi tersebut tanggal dismantle menjadi failure onset dan tanggal outcome
   disimpan sebagai konfirmasi.

Status repair setelah failure onset dipakai sebagai konfirmasi outcome, bukan
titik awal kerusakan.

## Klarifikasi relokasi, RECON, dan perubahan struktur historis

- `DISMANTLED + DISMANTLE` berarti relokasi part, bukan kerusakan.
- `DISMANTLED + CORRECTIVE` berarti part dilepas untuk perbaikan. Flow yang
  diharapkan berikutnya adalah RETURN.
- `DISMANTLED + RECON` merupakan rekonsiliasi administratif historis. Tanggalnya
  dapat berupa dummy atau waktu input, bukan waktu kejadian sebenarnya.
- Data dimulai sejak 2013 dan memiliki perubahan penamaan/struktur. Repair detail
  tanpa work type baru tersedia secara konsisten sejak 2025.

Semua RECON tetap disimpan untuk audit dan informasi lokasi, tetapi dikeluarkan
dari perhitungan waktu pada `analytics.item_journey_operational_timeline`.
Failure flow tersedia melalui `analytics.failure_event_flow`; missing RETURN
ditandai `OPEN_OR_INCOMPLETE_FLOW`, bukan dianggap non-failure.

## Implementasi setelah konfirmasi

Seluruh tindak lanjut review ini sudah diterapkan:

1. Spesifikasi label final dan cache failure sudah tersedia.
2. EDA PART mencakup model, lokasi, waktu, umur, lifecycle, dan failure berulang.
3. Snapshot 30 hari menghitung fitur hanya dari informasi pada atau sebelum
   tanggal observasi; fitur dan label masa depan juga tersedia sebagai view
   terpisah.
4. Reinstall tanpa failure tercatat tidak otomatis dijadikan negatif. Snapshot
   right-censored menyediakan mode utama dan mode strict untuk sensitivity test.
5. Split yang dipakai adalah train 2014-2024, validation 2025, dan test 2026
   dengan embargo target 30 hari, bukan random split.

Angka dan keputusan terbaru dibuat otomatis di
`reports/eda_executive_summary.md`; grafik dan analisis lengkap tersedia di
`reports/failure_eda.html`.
