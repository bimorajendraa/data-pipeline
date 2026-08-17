# Eksperimen: fitur kondisi armada (lintas-PART)

Implementasi: `src/experiment_fleet_features.py`

**Tidak ada model, view, notebook, atau script lama yang diubah.** Eksperimen
ini hanya membaca schema `analytics` dan melaporkan hasil.

## Gagasannya

Ke-18 fitur model resmi semuanya bicara tentang **PART itu sendiri**: umurnya,
berapa kali rusak, kapan terakhir diperbaiki. Tidak satu pun melihat keadaan di
sekelilingnya.

Yang diuji: apakah **"seberapa sering model PART ini rusak belakangan"**
menambah daya tebak.

Bedanya dengan `part_model_category` yang sudah ada itu penting. Kategori hanya
tahu **identitas** model dan sifatnya statis. Laju armada tahu **kondisi
terkini**, sehingga bisa menangkap cacat satu batch produksi, kohort yang menua
bersama, atau masalah musiman — informasi yang tidak mungkin diwakili kategori.

## Sinyal awal, diperiksa sebelum eksperimen ditulis

Laju kerusakan armada 90 hari, **dinormalkan per jumlah unit aktif**, dan
dipisah per tahun supaya bukan sekadar tren waktu:

| Laju armada | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|
| Rendah (<0,5%) | 0,37% | 0,13% | 0,49% | 0,66% |
| Sedang (0,5–2%) | 1,82% | 1,76% | 1,51% | 1,71% |
| **Tinggi (>2%)** | **6,17%** | **5,84%** | **4,56%** | **4,61%** |

Gradiennya bertahan di **setiap** tahun dengan sampel memadai di semua sel.
Jadi bukan artefak waktu, dan bukan efek ukuran armada.

## Fitur yang dibuat

| Fitur | Arti |
|---|---|
| `model_failure_rate_90d` | Kerusakan model ini dalam 90 hari terakhir, dibagi jumlah unit aktif |
| `log_model_failures_90d` | Jumlah mentahnya |
| `log_model_fleet_size` | Berapa unit model ini sedang terpasang |

Ditambah tiga fitur setara pada tingkat **lokasi**.

Ukuran armada dihitung sebagai jumlah siklus yang sedang berjalan pada tanggal
itu: yang sudah terpasang dikurangi yang sudah berakhir. Normalisasi ini perlu
supaya model dengan banyak unit tidak otomatis terlihat bermasalah hanya karena
jumlahnya banyak.

**Tidak ada kebocoran**: semua hitungan hanya memakai kerusakan yang terjadi
sebelum tanggal observasi, dan jumlah unit aktif pada tanggal itu — semuanya
sudah diketahui saat prediksi dilakukan.

## Hasil

Split waktu, embargo, hyperparameter, dan definisi target sama persis dengan
model resmi. Data uji: 38.451 observasi tahun 2026, 902 kerusakan.

| Set fitur | Jumlah | ROC-AUC | PR-AUC | Lift | Brier |
|---|---|---|---|---|---|
| 18 fitur resmi | 18 | 0,7947 | 0,1420 | 6,05 | 0,0216 |
| **+ armada model** | 21 | **0,8211** | **0,1610** | **6,86** | 0,0215 |
| + armada model & lokasi | 24 | **0,8301** | **0,1714** | **7,30** | 0,0213 |

Baseline mereproduksi angka resmi `train_final_model.py` **persis** (0,7947 /
0,1420), jadi harness eksperimen ini setara dengan pipeline resmi.

### Kontribusi fitur

`model_failure_rate_90d` menempati **peringkat 2 dari 24** dengan kontribusi
20,03 — fitur terpenting kedua di seluruh model, hanya kalah dari umur
pemasangan. Fitur tingkat lokasi jauh lebih lemah (peringkat 14–15).

### Apakah nyata?

Bootstrap 1.000x pada data uji:

- Selisih PR-AUC (armada model vs tanpa): **+0,0189**
- 95% CI: **[+0,0129, +0,0255]** — seluruhnya di atas nol
- Peluang benar-benar membantu: **100%**

Ini satu-satunya perbaikan sepanjang eksperimen yang rentang keyakinannya
**tidak menyentuh nol**.

### Dampak operasional

| Menandai K PART teratas | Tanpa armada | Dengan armada | Selisih |
|---|---|---|---|
| 200 | 66 | **79** | +13 |
| 500 | 147 | **163** | +16 |
| 1.000 | 237 | **258** | +21 |
| 2.000 | 330 | 336 | +6 |

Pada kapasitas yang dipakai production (200 PART/bulan), ini berarti
**13 kerusakan lebih banyak tertangkap dengan beban kerja yang sama** —
naik sekitar 20%.

## Catatan teknis penting

Saat eksperimen berjalan, angka baseline sempat bergeser antar-run (ROC 0,7922
lalu 0,7863) padahal seed sudah ditetapkan. Penyebabnya: query tanpa `ORDER BY`
— Postgres boleh mengembalikan baris dalam urutan berbeda tiap kali, dan urutan
baris memengaruhi hasil CatBoost.

Setelah urutan dikunci, hasilnya stabil dan baseline mereproduksi angka resmi
persis. **Selisih antar-run tanpa `ORDER BY` sekitar 0,006 ROC-AUC** — itu
lantai deraunya, dan perbaikan +0,026 dari fitur armada jauh di atasnya.

Pelajaran umum: setiap eksperimen yang membandingkan model harus mengunci
urutan baris, kalau tidak sebagian selisih yang terlihat sebenarnya cuma derau.

## Rekomendasi

**Layak dinaikkan ke production**, dengan catatan:

1. **Pakai varian 21 fitur (armada model saja)** sebagai pilihan utama.
   Varian 24 fitur sedikit lebih baik (lift 7,30 vs 6,86), tetapi fitur lokasi
   kontribusinya kecil (peringkat 14–15) sementara menambah tiga fitur dan satu
   sumber data lagi. Kalau ternyata perbedaannya bertahan pada training ulang
   berikutnya, varian lokasi bisa dipertimbangkan lagi.
2. **Perlu perubahan di `production_ml`**: `data_reader` sudah membaca seluruh
   event dan siklus, jadi fitur ini bisa dihitung tanpa sumber data baru —
   tetapi `feature_builder` perlu menghitungnya untuk training maupun
   prediction dengan cara yang sama persis.
3. **Perhatikan saat prediksi satu PART**: laju armada butuh riwayat kerusakan
   SELURUH model, bukan hanya PART yang diminta. Jadi jalur prediksi tidak bisa
   lagi menyaring database ke satu item saja.

Butir 3 adalah pekerjaan nyata, bukan sekadar menambah kolom — dan itu yang
membuat perubahan ini harus direncanakan, bukan ditempel begitu saja.
