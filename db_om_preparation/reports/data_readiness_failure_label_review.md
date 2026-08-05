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
- Client yang tidak cocok master berjumlah 58.645 journey dan lokasi yang tidak
  cocok master berjumlah 8.582 journey. Keduanya tidak menghalangi label waktu
  kerusakan, tetapi belum aman dijadikan fitur kategorikal tanpa mapping.

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
- Terdapat 6.714 kejadian pada 4.152 item.
- Sebanyak 5.986 kejadian langsung didahului status `INSTALLED`.
- Median waktu dari event sebelumnya untuk jalur `INSTALLED -> DISMANTLED
  (CORRECTIVE)` sekitar 344,82 hari.
- Pada kategori PART, 4.123 dari 23.564 item (17,50%) pernah mengalami kandidat
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

Client dan lokasi tetap dipertahankan sebagai informasi audit, tetapi belum
digunakan sebagai fitur sampai nilai yang tidak cocok master ditangani.

## Keputusan bisnis terkonfirmasi

1. `DISMANTLED + CORRECTIVE` berarti item dilepas karena gangguan/kerusakan dan
   menjadi failure onset.
2. Work order corrective dapat memiliki aktivitas lain, tetapi kombinasi dengan
   dismantle tetap menjadi onset yang terkonfirmasi.
3. `RECON` merupakan kegiatan terencana dan menjadi konteks non-failure.

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

## Langkah setelah konfirmasi

1. Membuat spesifikasi label final dan view kandidat event.
2. Menjalankan EDA PART per model, lokasi, umur, dan kejadian berulang.
3. Membuat dataset observasi tanpa memakai informasi setelah tanggal observasi.
4. Memulai target klasifikasi kerusakan dalam 30 hari.
5. Melakukan split berdasarkan waktu, bukan random split.
