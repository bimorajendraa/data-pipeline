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
| Failure onset | 6.714 | `DISMANTLED + CORRECTIVE` |
| Failure eligible cohort PART | 6.667 | Siap untuk EDA PART |
| Item dengan failure eligible | 4.115 | Positive population awal |
| Failure flow terkonfirmasi | 5.937 | RETURN/repair process tercatat |
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
4. Sebanyak 5.452 dari 6.714 failure onset (81,20%) langsung didahului status
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

Sebanyak 777 dari 6.714 failure onset (11,57%) belum memiliki RETURN, repair
process, atau outcome yang dapat dikaitkan sebelum batas siklus berikutnya.

- Legacy 2013–2024: 120 open/incomplete dari 4.150 failure.
- Periode 2025+: 657 open/incomplete dari 2.564 failure.

Angka 2025+ yang lebih tinggi dapat mencakup proses yang masih berjalan atau
right-censoring. Record ini tetap diberi label failure berdasarkan corrective
dismantle dan tidak boleh dijadikan negative.

### 3. Failure tidak selalu didahului INSTALLED

**Severity: TINGGI untuk time-to-failure; MENENGAH untuk klasifikasi 30 hari.**

Sebanyak 1.262 failure onset tidak langsung didahului `INSTALLED` pada
operational timeline:

| Previous operational status | Failure event |
|---|---:|
| `OK` | 442 |
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

### 6. Client dan lokasi belum sepenuhnya cocok master

**Severity: MENENGAH untuk fitur; RENDAH untuk label failure.**

- Client tidak cocok master: 58.645 journey.
- Lokasi journey tidak cocok master: 8.582 journey.
- Lokasi work-order history tidak cocok master: 28.107 history.

Nilai mentah tetap berguna untuk audit, tetapi client/lokasi belum aman menjadi
fitur kategorikal tanpa mapping. Lokasi RECON boleh menunjukkan posisi, namun
waktu mulai lokasi tersebut tidak dapat dipercaya.

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

## Apa yang masih kurang

1. Belum ada `installation_cycle_id` yang menghubungkan installation, failure,
   return, repaired, dan installation berikutnya sebagai satu siklus.
2. Belum ada observation dataset per item-per-tanggal untuk target 30 hari.
3. Belum ada definisi right-censoring dan tanggal cutoff training.
4. Belum ada sampling manual untuk 777 incomplete flow dan 1.262 failure yang
   tidak didahului installed.
5. Belum ada mapping final client, lokasi, dan 732 model inconsistent.
6. Belum ada feature set yang dijamin hanya menggunakan data sebelum observation
   date.
7. Belum ada time-based train/validation/test split.
8. Belum ada baseline model, threshold risiko, dan evaluasi per era/model item.
9. Belum ada monitoring data drift dan quality gate untuk data baru.
10. Workflow n8n belum boleh menjadi tahap utama sebelum dataset dan model lolos
    validasi temporal.

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
| Model klasifikasi failure 30 hari | Siap setelah observation dataset dibuat |
| Model exact days-to-failure | Belum siap; perlu cycle dan censoring |
| Model TERMINAL | Belum siap |
| Otomatisasi scoring n8n | Belum; dilakukan setelah validasi model |

## Prioritas berikutnya

1. Audit sampel 777 incomplete flow dan 1.262 failure non-installed.
2. Bentuk installation/operation cycle per PART dengan relocation sebagai
   perubahan lokasi dan RECON dikeluarkan dari waktu.
3. Tentukan observation date dan cutoff historis.
4. Buat target failure dalam 30 hari tanpa data leakage.
5. Jalankan EDA per item model dan data era.
6. Buat baseline time-split sebelum mengembangkan prediksi exact days.

