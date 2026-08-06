# Kesimpulan Data Readiness OMEXP

Tanggal analisis: 2026-08-05  
Database: `OMEXP`  
Fokus: kesiapan data journey untuk prediksi kerusakan PART

## Kesimpulan eksekutif

Data sudah **siap untuk EDA dan pembuatan dataset model awal khusus PART**, tetapi
belum langsung siap untuk model produksi yang memprediksi jumlah hari menuju
kerusakan. Cleaning, label failure, pemisahan RECON, dan operational timeline
sudah tersedia. Risiko terbesar yang tersisa adalah histori yang tidak lengkap,
perubahan struktur pencatatan sejak 2013, flow failure yang belum memiliki
kelanjutan, serta belum terbentuknya siklus installation-to-failure per item.

Tabel sumber tetap utuh. Semua koreksi dilakukan sebagai clean, semantic, dan
operational layer di schema `analytics`.

## Ringkasan angka

| Indikator | Jumlah | Kesimpulan |
|---|---:|---|
| Seluruh journey | 189.865 | Audit population |
| ADMIN_RECON | 30.542 | Tidak dipakai untuk urutan/durasi operasional |
| Operational timeline | 159.321 | Sumber waktu untuk EDA/model |
| Tanggal invalid/future | 75 | Dikeluarkan dari waktu operasional |
| Relocation | 707 | Non-failure; perubahan lokasi/siklus |
| Failure onset | 6.715 | `DISMANTLED + CORRECTIVE`, ditambah preventive yang kemudian dikonfirmasi rusak |
| Failure eligible cohort PART | 6.668 | Siap untuk EDA PART |
| Item dengan failure eligible | 4.116 | Positive population awal |
| Failure flow terkonfirmasi | 5.938 | RETURN/repair process tercatat |
| Failure open/incomplete | 777 | Tetap failure, bukan negative |

Sekitar 16,09% journey merupakan konteks ADMIN_RECON. Setelah RECON dan waktu
yang tidak layak dikeluarkan, sekitar 83,91% journey tetap tersedia sebagai
operational timeline.

## Hal yang sudah baik

1. Tidak ditemukan duplicate journey ID atau identifier journey yang gagal
   ditemukan pada inventory.
2. Tidak ada gap waktu negatif pada operational timeline.
3. Failure onset memiliki histori panjang sejak 2013, sehingga tidak bergantung
   pada status repair detail yang baru tersedia sejak 2025.
4. Sebanyak 5.452 dari 6.715 failure onset (81,19%) langsung didahului status
   operasional `INSTALLED`.
5. Median waktu `INSTALLED -> FAILURE_ONSET` pada kelompok tersebut sekitar
   506,76 hari.
6. RECON audit tetap tersedia, tetapi tidak lagi merusak LAG/LEAD dan durasi
   operasional.
7. Seluruh 15.526 installation yang memiliki penanda RECON pada work order,
   `done_by`, atau `remark` sudah diklasifikasikan sebagai ADMIN_RECON.
8. Relokasi telah dipisahkan dari failure.
9. Perbedaan era legacy dan detailed repair sudah ditandai eksplisit.

## Kejanggalan dan tingkat risikonya

### 1. Timestamp RECON tidak mewakili waktu kejadian sebenarnya

**Severity jika tidak ditangani: KRITIKAL untuk timeline.**  
**Status: sudah dimitigasi.**

RECON dapat memakai tanggal dummy atau waktu input rekonsiliasi. Memasukkan
timestamp tersebut akan menghasilkan umur/gap yang salah dan dapat mengubah
previous/next event. Sebanyak 30.542 event sudah dikeluarkan dari operational
timeline, tetapi tetap disimpan pada audit layer.

### 2. Failure flow belum lengkap

**Severity: TINGGI.**  
**Status: ditandai, belum seluruhnya dapat diperbaiki.**

Sebanyak 777 dari 6.715 failure onset (11,57%) belum memiliki RETURN, repair
process, atau outcome yang dapat dikaitkan sebelum batas siklus berikutnya.

- Legacy 2013–2024: 120 open/incomplete dari 4.150 failure.
- Periode 2025+: 657 open/incomplete dari 2.565 failure.

Angka 2025+ yang lebih tinggi dapat mencakup proses yang masih berjalan atau
right-censoring. Record ini tetap diberi label failure berdasarkan corrective
dismantle dan tidak boleh dijadikan negative.

### 3. Failure tidak selalu didahului INSTALLED

**Severity: TINGGI untuk time-to-failure; MENENGAH untuk klasifikasi 30 hari.**

Sebanyak 1.263 failure onset tidak langsung didahului `INSTALLED` pada
operational timeline:

| Previous operational status | Failure event |
|---|---:|
| `OK` | 443 |
| `REPAIRED` | 224 |
| `RETURNED` | 220 |
| Tidak memiliki previous event | 153 |
| `REQUESTED` | 138 |
| `ISSUED` | 64 |
| `DISMANTLED` | 19 |
| Status lain | 2 |

Hal ini dapat disebabkan histori awal yang terpotong, perbedaan pencatatan lama,
atau satu item identifier dipakai lintas siklus. Failure tetap valid, tetapi
umur sejak installation tidak boleh dipaksakan jika installation awal tidak
tersedia.

### 4. Perubahan struktur pencatatan sejak 2013

**Severity: TINGGI jika seluruh tahun diperlakukan identik.**  
**Status: sebagian dimitigasi dengan data era.**

Status repair detail tanpa work type baru tersedia sejak 2025. Karena itu:

- failure onset tetap memakai corrective dismantle untuk seluruh era;
- status `NEED REPAIR`, `REPAIRING`, `UNREPAIRABLE`, dan sejenisnya hanya menjadi
  konfirmasi outcome;
- tidak adanya status repair detail sebelum 2025 bukan negative evidence;
- evaluasi model harus diperiksa per era.

### 5. Model item tidak konsisten

**Severity: MENENGAH-TINGGI.**

Terdapat 732 journey dengan model item yang tidak konsisten terhadap inventory.
Pada failure onset, 14 event terdampak dan sudah dikeluarkan dari cohort awal.
Mapping model perlu diselesaikan sebelum record tersebut digunakan.

### 6. Pencocokan client dan lokasi

**Severity: MENENGAH untuk fitur; RENDAH untuk label failure.**

- Client tidak cocok master setelah mapping: 0 journey. Sebanyak 58.645 journey
  dengan typo `KERETE COMMUTER INDONESIA (KCI)` sudah dipetakan ke
  `KERETA COMMUTER INDONESIA (KCI)` melalui fuzzy matching yang melewati batas
  skor dan margin aman.
- Lokasi journey tidak cocok master setelah mapping: 15 journey, semuanya
  `NOC JUANDA` dan tetap masuk review karena skor fuzzy hanya 61,54%.
- Sebanyak 8.567 journey `GUDANG NUTECH` sudah dipetakan ke `GUDANG NI`
  berdasarkan tumpang-tindih item dan kesamaan alur gudang, bukan fuzzy semata.
- Lokasi work-order history tidak cocok master: 28.107 history.

Nilai mentah tetap berguna untuk audit. Fitur lokasi sekarang hanya memakai nama
canonical yang cocok dengan master; 174 snapshot training yang tidak memiliki
lokasi master ditandai tidak layak untuk fitur lokasi. Lokasi RECON boleh
menunjukkan posisi, tetapi waktu mulai lokasi tersebut tidak dapat dipercaya.

### 6a. Lonjakan 4.011 event bukan pemasangan atau kerusakan

Pada 3 Juli 2024 terdapat 4.011 event dengan kombinasi `OK + RECEPTION` di
`GUDANG NUTECH`. Seluruhnya diklasifikasikan sebagai
`BULK_WAREHOUSE_RECEPTION`: pencatatan penerimaan barang secara massal di
gudang. Pada kelompok ini tidak ada status `INSTALLED`, `DISMANTLED`, ataupun
failure. Event tetap dipertahankan sebagai histori operasional, tetapi tidak
boleh dihitung sebagai pemasangan, pembongkaran, atau kerusakan.

### 7. Relokasi harus memutus/memperbarui konteks lokasi

**Severity: MENENGAH.**

Terdapat 707 event relokasi (`DISMANTLED + DISMANTLE`). Event ini bukan failure,
tetapi dapat menandai akhir pemasangan di lokasi lama dan awal siklus di lokasi
baru. Feature engineering harus memperbarui lokasi dan tidak menghitung relokasi
sebagai kerusakan.

### 8. Gap panjang dan event timestamp sama

**Severity: PERLU REVIEW, bukan otomatis error.**

- Tidak ada gap negatif.
- 1.554 event memiliki gap nol hari; hal ini dapat berasal dari rangkaian status
  pada timestamp yang sama dan masih dapat diurutkan dengan `journey_id`.
- 322 event memiliki gap lebih dari 10 tahun. Sebagian dapat merupakan part
  berumur panjang atau histori yang terpotong; jangan otomatis dibuang tanpa
  sampling.
- 25.956 event tidak memiliki previous operational event. Mayoritas merupakan
  event pertama setiap item, sehingga bukan otomatis kejanggalan.

### 9. Work order dan MTBF belum layak menjadi sumber label utama

**Severity: MENENGAH.**

- Invalid due date work order: 5.698.
- Current status WO berbeda dengan history terakhir: 170.
- Invalid sequence pada WO history: 2.930.
- Lokasi MTBF tidak cocok master: 3.418.
- Model MTBF ambigu: 500.
- MTTR kosong.

Work order tetap menjadi konteks pendukung. MTBF sebaiknya belum digunakan pada
baseline model dan MTTR tidak digunakan.

### 10. Data TERMINAL belum cukup untuk model failure yang sama

**Severity: TINGGI jika digabung tanpa pemisahan.**

Hanya 29 terminal yang memiliki corrective dismantle, dibanding 4.123 PART pada
analisis awal. Model pertama harus khusus PART; TERMINAL memerlukan definisi dan
dataset terpisah.

### 11. Target 30 hari sangat tidak seimbang

**Severity: TINGGI untuk evaluasi model; bukan kesalahan data.**

Dari 1.388.036 snapshot training, hanya 5.876 snapshot positif (0,4233%) dan
1.382.160 negatif (99,5767%). Artinya terdapat sekitar 235,22 snapshot negatif
untuk setiap satu positif. Accuracy tidak boleh menjadi metrik utama. Baseline
harus dinilai dengan precision, recall, PR-AUC, ROC-AUC, confusion matrix, dan
kalibrasi probabilitas. Class weight atau resampling hanya boleh dipasang pada
data train setelah split waktu, bukan sebelum split.

### 12. Sebagian fitur numerik sangat redundan

Matriks Pearson dan Spearman sudah ditambahkan. Ditemukan 10 pasangan fitur
dengan |Spearman| minimal 0,80. Enam pasangan bahkan melampaui 0,95, terutama
antara `days_since_installation`, `days_since_last_event`,
`days_since_last_corrective`, dan `days_at_last_location`. Fitur-fitur tersebut
tidak perlu langsung dibuang, tetapi baseline harus membandingkan pemilihan satu
fitur representatif, regularisasi, dan hasil validasi temporal.

Screening Information Value menempatkan `days_since_last_corrective` paling
tinggi dengan IV 1,3209. Nilai sebesar ini belum berarti fitur pasti terbaik;
justru perlu audit leakage, perubahan proses, missing struktural, dan kestabilan
waktu. IV di laporan adalah screening univariat, bukan feature importance model
final.

### 13. Cakupan master cukup aman, tetapi fallback tetap diperlukan

Client canonical tersedia pada seluruh 1.388.036 snapshot. Lokasi canonical
tersedia pada 1.387.862 snapshot; hanya 174 snapshot (0,0125%) yang unmatched.
Dari 153 kategori lokasi, lima kategori memiliki kurang dari 100 snapshot, tetapi
seluruh kategori langka tersebut hanya mencakup 0,0249% snapshot. Fitur lokasi
aman diuji sebagai prediktor dengan kategori `UNKNOWN`, missing flag, minimum
support, penggabungan kategori langka bila perlu, dan pembanding model tanpa
lokasi.

### 14. Missing struktural dan drift sudah dipetakan

`days_since_last_failure` kosong pada 94,3577% snapshot karena mayoritas PART
belum pernah failure. `days_since_last_corrective` kosong pada 88,0050% snapshot
karena belum pernah corrective. Keduanya bukan otomatis kesalahan data dan tidak
boleh langsung diisi nol; gunakan indikator "belum pernah", sentinel/imputasi
yang konsisten, dan validasi temporal. Missing lokasi hanya 0,0125%; fitur inti
lain yang diaudit tidak memiliki missing.

Ringkasan mean, median, persentil 90, dan missing rate bulanan tersedia untuk
delapan fitur dari Januari 2013 sampai Juli 2026. PSI terhadap referensi 2024
menemukan lima kombinasi fitur-tahun dengan drift besar: dua pada 2025 dan tiga
pada 2026. `days_since_installation` dan `days_since_last_event` drift pada kedua
tahun; `days_at_last_location` juga drift pada 2026. Karena 2026 masih parsial,
hasilnya perlu dikonfirmasi melalui validation/test temporal dan monitoring
produksi.

## Apa yang masih kurang

1. Perlu sampling manual untuk 478 incomplete flow berumur lebih dari 180 hari,
   217 flow berumur 31-180 hari, dan 1.263 failure yang tidak langsung didahului
   status `INSTALLED`. Sebanyak 82 flow berumur 0-30 hari kemungkinan masih
   berjalan pada cutoff data 3 Agustus 2026.
2. Perlu review manual untuk 15 event `NOC JUANDA`, 174 snapshot tanpa lokasi
   master, dan 732 journey dengan model inconsistent.
3. Belum ada baseline model, threshold risiko, kalibrasi probabilitas, dan
   evaluasi per era/model/lokasi.
4. Belum ada perbandingan performa model dengan dan tanpa fitur lokasi.
5. Baseline drift EDA sudah ada, tetapi belum ada monitoring berulang dan quality
   gate untuk data baru di produksi.
6. Workflow n8n belum boleh menjadi tahap utama sebelum model lolos validasi
   temporal.

## Record yang merusak flow jika digunakan langsung

Jangan gunakan langsung untuk perhitungan waktu:

- `event_semantic = 'ADMIN_RECON'`;
- `is_trusted_event_time = FALSE`;
- tanggal sebelum 1971 atau masa depan;
- model item inconsistent untuk training cohort;
- gap/cycle yang installation awalnya tidak diketahui untuk target exact
  days-to-failure.

Jangan diperlakukan sebagai negative:

- `OPEN_OR_INCOMPLETE_FLOW`;
- journey sebelum 2025 yang tidak memiliki repair detail;
- event yang belum mencapai akhir observation window;
- relokasi tanpa failure.

## Verdict kesiapan

| Kebutuhan | Status |
|---|---|
| Audit dan data-quality review | Siap |
| EDA flow PART | Siap |
| Label failure onset PART | Siap |
| Model klasifikasi failure 30 hari | Dataset dan EDA siap; baseline model belum dilatih |
| Model exact days-to-failure | Belum siap; perlu cycle dan censoring |
| Model TERMINAL | Belum siap |
| Otomatisasi scoring n8n | Belum; dilakukan setelah validasi model |

## Prioritas berikutnya

1. Audit sampel incomplete flow lama dan 1.263 failure non-installed.
2. Gunakan snapshot 30 hari untuk baseline training; tetap izinkan scoring harian
   atau event-triggered saat model digunakan.
3. Latih baseline dengan train 2013-2024, validation 2025, dan test 2026.
4. Bandingkan performa dengan dan tanpa fitur lokasi untuk memastikan kontribusi
   lokasi tetap stabil; 174 snapshot belum memiliki lokasi canonical dari master.
5. Evaluasi ketidakseimbangan kelas dengan precision, recall, PR-AUC, ROC-AUC,
   confusion matrix, dan kalibrasi; jangan hanya memakai accuracy. Terapkan class
   weight/resampling hanya pada train.
6. Audit IV tinggi dan 10 pasangan fitur redundan melalui ablation/regularisasi
   pada validation 2025 dan test 2026.
7. Jadikan PSI 2024 sebagai baseline awal, lalu buat monitoring drift berkala dan
   quality gate sebelum otomatisasi scoring.
