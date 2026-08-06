# OMEXP Data Cleaning & Preparation

Paket ini menyiapkan data pada database `OMEXP` untuk EDA dan Grafana tanpa
membuat database baru dan tanpa mengubah data sumber. Walaupun arsip backup
berasal dari database bernama `OM`, target yang digunakan oleh pipeline ini
adalah database `OMEXP` yang sudah tersedia. Tabel pada schema `journal`,
`inventory`, dan `master` hanya dibaca. Semua fungsi, view, dan materialized
cache baru dibuat di schema `analytics`.

## Alur sederhana

```text
Data sumber -> profiling -> cleaning -> standardisasi -> transformasi
            -> validasi master -> view live -> cache laporan -> EDA/Grafana
```

Pipeline sudah menyiapkan fitur historis sederhana untuk EDA, tetapi belum
melatih model. Tidak ada n8n, Airflow, Kafka, Spark, dbt, data warehouse, atau
perhitungan ulang MTBF di tahap ini.

Sumber utama flow adalah `journal.t_item_journey`. Work order hanya menjadi
validasi/pelengkap bila `wo_code` tersedia. MTBF dipertahankan sebagai data
suplementer dan tidak menentukan flow. MTTR tidak masuk pipeline aktif karena
tabelnya kosong pada backup; tabel sumbernya tetap dibiarkan utuh.

## Isi proyek

| File | Tujuan | Hasil yang diharapkan |
|---|---|---|
| `sql/01_create_analytics_schema.sql` | Membuat schema dan fungsi normalisasi teks | Schema `analytics`; fungsi cleaning dan candidate key nama |
| `sql/02_data_profiling.sql` | Memeriksa jumlah baris, null/kosong, unik, duplikat, variasi case/spasi, top value, dan rentang tanggal | Cache `analytics.data_profile` dan kandidat standardisasi nama |
| `sql/03_item_journey_clean.sql` | Membersihkan journey, menyusun urutan event, dan memprofilkan transisi aktual | `analytics.item_journey_clean`, cache `analytics.item_journey_transition_profile` |
| `sql/04_item_clean.sql` | Membersihkan inventory dan memvalidasi master item/lokasi/status | `analytics.item_clean` |
| `sql/05_work_order_clean.sql` | Membersihkan WO dan membandingkan status dengan history terakhir | `analytics.work_order_clean` |
| `sql/06_work_order_history_clean.sql` | Membersihkan history, memeriksa orphan WO dan urutan tanggal | `analytics.work_order_history_clean` |
| `sql/07_mtbf_clean.sql` | Membersihkan MTBF sebagai sumber suplementer, mempertahankan menit, dan menambah konversi jam | `analytics.mtbf_clean` |
| `sql/08_data_quality_summary.sql` | Menyatukan quality check dan daftar validasi status | Cache `analytics.data_quality_summary`, `analytics.status_validation` |
| `sql/09_failure_event_label.sql` | Menambahkan label failure onset berdasarkan keputusan bisnis | `analytics.item_journey_failure_labeled`, cache `analytics.failure_event_clean` |
| `sql/10_operational_timeline.sql` | Memisahkan event operasional dari RECON administratif dan mengonfirmasi flow failure | `analytics.item_journey_semantic`, `analytics.item_journey_operational_timeline`, `analytics.failure_event_flow` |
| `sql/11_item_installation_cycle.sql` | Membentuk siklus dari INSTALLED tepercaya sampai failure/reinstall/censoring | `analytics.item_installation_cycle` |
| `sql/12_item_observation_dataset.sql` | Membentuk snapshot 30-harian, fitur historis, target 30 hari, dan flag observability | `analytics.item_observation_30d` |
| `sql/13_eda_summary.sql` | Membuat metrik readiness, tren target, missingness, dan refresh dependency | Tiga view ringkasan EDA |
| `sql/14_extended_eda.sql` | Membandingkan cadence dan unit analisis, mengelompokkan follow-up yang belum lengkap, serta merangkum outlier | View pemeriksaan EDA lanjutan dan cache perbandingan snapshot |
| `sql/15_comprehensive_eda.sql` | Melengkapi audit kualitas journal, univariat, hubungan item-lokasi/waktu, lifecycle satu lokasi, dan lonjakan aktivitas | View EDA komprehensif yang dapat dipakai ulang oleh notebook |
| `notebooks/01_failure_eda.ipynb` | EDA interaktif tanpa memuat seluruh dataset detail ke memori | Tabel, grafik, pemeriksaan leakage, dan usulan time split |
| `src/export_eda_report.py` | Menjalankan notebook dan mengekspor HTML | `reports/failure_eda.html` |
| `src/run_pipeline.py` | Menjalankan semua SQL secara urut dan transactional per file | Seluruh view analytics tersedia |
| `src/export_quality_report.py` | Mengekspor profiling dan quality summary | Dua CSV di folder `reports` |

Kesimpulan kesiapan, kejanggalan, risiko timeline, dan pekerjaan yang masih
diperlukan tersedia di `reports/data_readiness_conclusion.md`.

Nilai `*_original` dipertahankan pada clean views agar setiap normalisasi dapat
ditelusuri. Record yang gagal validasi tidak dihapus.
Underscore pada nama petugas/client hanya digunakan untuk menyusun kandidat
standardisasi di hasil profiling; clean view tidak menggabungkan nama tersebut
secara otomatis.

## Mapping yang diverifikasi dari backup

SQL telah disesuaikan dengan schema backup `backupcountrycustom-OM-202608042046.tar`:

- `master.t_mtr_item(item_model_code, item_model_name, item_type, item_category)`
- `master.t_mtr_location(location_code, location_name)`
- `master.t_mtr_client(client_code, client_name)`
- `master.t_mtr_status(status_code, status_name, status_type)`
- `master.t_mtr_work_type(work_type_code, work_type)`

`journal.t_item_journey.place` dan `journal.t_work_order_history.place`
dibandingkan dengan kode maupun nama lokasi. Status work order dan history
dipetakan dahulu ke canonical `status_code` bertipe `WORK`. `wo_type` journey
menjadi referensi utama; canonical work type pada work order hanya dipakai untuk
flag konsistensi. `item_model` pada MTBF dibandingkan dengan `item_model_name`
atau `item_model_code`, sedangkan client dibandingkan dengan master client resmi.
Identifier komposit inventory
dibentuk dari `item_model_code-item_pairing_code-repair_seq` untuk validasi
`host_serial_code` journey.

Tetap periksa hasil struktur kolom pada `02_data_profiling.sql` bila database yang
digunakan lebih baru daripada backup ini.

## Menjalankan melalui DBeaver

1. Hubungkan DBeaver ke database `OMEXP` yang sudah ada. Jangan membuat database
   baru.
2. Buka SQL Editor pada koneksi tersebut.
3. Jalankan file di folder `sql` dari `01` sampai `15`, satu per satu.
4. Aktifkan **Stop on error**. Jika satu file gagal, hentikan urutan dan periksa
   pesan nama tabel/kolom sebelum melanjutkan.
5. Setelah file `02`, query `analytics.data_profile` untuk melihat profil data.
6. Setelah file `08`, query `analytics.data_quality_summary` dan gunakan contoh
   drill-down di bagian akhir file untuk memeriksa record bermasalah.

File `01` harus dijalankan sebelum `02` karena fungsi profiling disimpan pada
schema `analytics`. Ini hanya DDL untuk schema baru; tidak ada DML terhadap tabel
sumber.

## Menjalankan melalui Python

Gunakan PowerShell dari folder proyek ini:

```powershell
cd db_om_preparation
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
Copy-Item .env.example .env
```

Isi `.env` dengan kredensial database `OMEXP` yang sudah ada, lalu jalankan:

```powershell
python src\run_pipeline.py
python src\export_quality_report.py
jupyter lab notebooks\01_failure_eda.ipynb
```

Untuk mengeksekusi notebook secara otomatis dan membuat HTML:

```powershell
python src\export_eda_report.py
```

`run_pipeline.py` memperbarui clean view sekaligus membangun cache untuk hasil
agregasi yang berat. Karena dihitung sekali saat setup, pembuatan dataset
snapshot dan perbandingan cadence dapat memerlukan beberapa menit, tetapi
pembukaan di DBeaver dan pembuatan laporan berikutnya menjadi cepat.

Setelah tabel sumber menerima data baru, perbarui seluruh cache dengan:

```sql
CALL analytics.refresh_cached_views();
```

Clean view tetap membaca data sumber terbaru secara langsung. Cache profiling,
quality, event, semantic, operational timeline, dan failure-flow diperbarui
sekaligus oleh procedure `analytics.refresh_cached_views()`.

Label failure onset yang sudah dikonfirmasi mencakup dua pola:

- `DISMANTLED + CORRECTIVE`; dan
- `DISMANTLED + PREVENTIVE` yang kemudian dikonfirmasi oleh `BROKEN`,
  `SENDLOG (BROKEN)`, atau `UNREPAIRABLE` sebelum installation berikutnya.

Untuk pola preventive, tanggal dismantle menjadi awal berhentinya waktu
operasional dan tanggal outcome disimpan sebagai `failure_confirmed_on`.
`RECON` tetap menjadi kegiatan administratif/non-failure. Cohort model pertama
dibatasi ke `PART` dengan tanggal valid dan model yang konsisten.

## Konteks bisnis journey dan perubahan pencatatan

Data journey tersedia sejak 2013. Penamaan status dan kelengkapan flow berbeda
antarperiode, sehingga analisis membedakan dua era:

- `LEGACY_2013_2024`: flow repair detail belum tersedia secara konsisten;
- `DETAILED_REPAIR_2025_PLUS`: status repair detail mulai dicatat.

| Status | Work type | Arti bisnis | Perlakuan analisis |
|---|---|---|---|
| `DISMANTLED` | `CORRECTIVE` | Part dilepas karena gangguan/perbaikan | Failure onset |
| `DISMANTLED` | `PREVENTIVE` | Part dilepas terencana, lalu diperiksa | Failure hanya jika sebelum installation berikutnya dikonfirmasi `BROKEN`/`UNREPAIRABLE`; selain itu tetap preventive |
| `DISMANTLED` | `DISMANTLE` | Part dipindah/relokasi | Non-failure; lokasi tetap informatif |
| `DISMANTLED` | `RECON` | Rekonsiliasi administratif data lama | Non-failure; waktu tidak dipercaya |
| `RETURNED` | umumnya kosong | Part dikembalikan setelah dilepas | Konfirmasi flow, bukan onset |
| `NEED REPAIR`, `REPAIRING` | kosong | Proses repair detail sejak 2025 | Konfirmasi outcome |
| `UNREPAIRABLE`, `BROKEN` | kosong | Tidak dapat diperbaiki/rusak | Failure outcome |

Status `SENDREP`, `RECEIVE`, `CHECKING`, `NEED REPAIR`, `REPAIRING`, `HOLD`,
`WAITING`, dan `UNREPAIRABLE` memang tidak memiliki `wo_type`. Hal ini merupakan
karakter flow item sejak 2025 dan bukan otomatis data error.

### Perlakuan khusus RECON

RECON pada data lama digunakan sebagai formalitas untuk mencatat bahwa part yang
sebelumnya tercatat di lokasi A ternyata sudah berada di lokasi B. Timestamp-nya
dapat berupa tanggal dummy atau waktu input rekonsiliasi, bukan waktu perpindahan
yang sebenarnya. Karena itu:

- event RECON tetap disimpan pada audit/clean layer;
- RECON tidak dianggap failure;
- timestamp RECON tidak dipakai menghitung umur, gap, MTBF, atau durasi event;
- RECON tidak menjadi previous/next event pada operational timeline;
- lokasi RECON boleh dipertahankan sebagai informasi posisi, tetapi waktu
  perpindahannya tidak dianggap terpercaya;
- installation yang terhubung ke work order RECON juga dikeluarkan dari waktu
  operasional walaupun `wo_type` journey tertulis `INSTALLATION`;
- installation lama dengan `done_by` atau `remark` berisi `RECON` juga dianggap
  administratif walaupun `wo_type` dan work order kosong.

Tersedia dua timeline:

```text
analytics.item_journey_clean
    Audit timeline: semua event termasuk RECON

analytics.item_journey_operational_timeline
    Operational timeline: RECON dan waktu invalid/future tidak memengaruhi
    urutan maupun durasi
```

`analytics.item_journey_semantic` mengelompokkan event menjadi:

```text
FAILURE_ONSET, RELOCATION, ADMIN_RECON, REPAIR_PROCESS,
FAILURE_OUTCOME, REPAIR_COMPLETED, RETURN_FLOW,
PREVENTIVE, NORMAL_OPERATION
```

`analytics.failure_event_flow` memeriksa flow setelah failure onset. RETURN
merupakan flow yang diharapkan, tetapi ketiadaan RETURN tidak mengubah event
menjadi non-failure. Flow tanpa konfirmasi diberi status
`OPEN_OR_INCOMPLETE_FLOW`, yang dapat berarti pencatatan belum lengkap atau
proses masih berjalan dan tidak boleh dianggap kelas negatif.

## Dataset EDA failure 30 hari

`analytics.item_installation_cycle` hanya dimulai oleh `INSTALLED` pada
operational timeline. Installation RECON tidak membuka cycle. Cycle berakhir
pada failure pertama, installation tepercaya berikutnya, atau batas data.
Cycle tanpa akhir yang teramati ditandai sebagai right-censored; cycle dengan
timestamp sama/berdurasi nol ditandai tidak valid dan tidak masuk cohort awal.

`analytics.item_observation_30d` memakai snapshot setiap 30 hari. Target bernilai
positif hanya jika failure terjadi setelah snapshot dan dalam 30 hari. Negatif
hanya layak training jika tersedia follow-up penuh 30 hari; snapshot dekat batas
data atau akhir cycle diberi `EXCLUDED_INCOMPLETE_30D_FOLLOWUP`. Seluruh fitur
dihitung hanya dari event pada atau sebelum waktu observasi untuk mencegah data
leakage. Dataset pertama dibatasi ke `PART` yang identifier/model-nya konsisten.
Fitur historis mencakup jumlah event, corrective, dan preventive dalam 30, 90,
serta 180 hari sebelumnya; failure dalam 365 hari; waktu sejak corrective
terakhir; lama berada di lokasi terakhir; serta tahun, kuartal, bulan, hari
dalam minggu, dan penanda akhir pekan pada tanggal snapshot.

Perbandingan cadence 7 dan 30 hari tersedia di
`analytics.eda_snapshot_cadence_comparison`. Snapshot 30 hari dipakai untuk
baseline training karena lebih ringkas dan tetap menangkap semua failure pada
cohort ini. Hal tersebut tidak membatasi jadwal scoring: model tetap dapat
dijalankan setiap hari atau setiap ada event baru.

Fitur lokasi menggunakan nama canonical dari `master.t_mtr_location`. Nilai
lokasi yang tidak cocok atau ambigu tetap dipertahankan untuk audit, tetapi
`is_location_feature_eligible = FALSE` dan tidak dipakai pada grafik lokasi.

Notebook membandingkan era lama dan era detail repair, target imbalance,
missingness, umur sampai failure, model dengan dukungan sampel minimum, fitur
failure/nonfailure, dan split waktu. Rekomendasi awal split adalah train sampai
2024, validation 2025, dan test 2026; keputusan final tetap mengikuti hasil EDA.

Runner hanya menerima `DB_NAME=OMEXP`. Runner juga menolak DDL database serta
SQL yang berisi `UPDATE`, `DELETE`, `INSERT`, `TRUNCATE`,
`ALTER TABLE`, atau `DROP TABLE` terhadap schema `journal`, `inventory`, dan
`master`. Transaksi satu file akan di-rollback jika file tersebut gagal.

Hasil ekspor:

- `reports/data_profile.csv`
- `reports/data_quality_summary.csv`
- `reports/failure_eda.html`

## Pemeriksaan hasil

```sql
SELECT table_name, quality_check, total_rows, failed_rows,
       failed_percentage, severity, description
FROM analytics.data_quality_summary
ORDER BY CASE severity
    WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
    failed_percentage DESC NULLS LAST;

SELECT data_quality_status, COUNT(*)
FROM analytics.item_journey_clean
GROUP BY data_quality_status;

SELECT from_status, to_status, SUM(transition_count) AS transition_count
FROM analytics.item_journey_transition_profile
GROUP BY from_status, to_status
ORDER BY transition_count DESC;

SELECT journey_work_type_name_clean, work_order_work_type_name_clean,
       COUNT(*) AS row_count
FROM analytics.item_journey_clean
WHERE is_work_type_consistent IS FALSE
GROUP BY journey_work_type_name_clean, work_order_work_type_name_clean
ORDER BY row_count DESC;

SELECT event_semantic, COUNT(*) AS event_count
FROM analytics.item_journey_semantic
GROUP BY event_semantic
ORDER BY event_count DESC;

SELECT data_era, flow_confirmation_status, COUNT(*) AS failure_count
FROM analytics.failure_event_flow
GROUP BY data_era, flow_confirmation_status
ORDER BY data_era, failure_count DESC;

SELECT *
FROM analytics.status_validation
WHERE match_type IN ('NORMALIZED_CASE_OR_SPACE', 'NOT_FOUND_REVIEW_CANDIDATE')
ORDER BY source_table, row_count DESC;

SELECT n.nspname AS schema_name, c.relname AS object_name,
       CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' END AS object_type
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'analytics'
  AND c.relkind IN ('v', 'm')
ORDER BY object_type, object_name;
```

`failed_rows = 0` berarti check tersebut lolos. Nilai nonzero tidak dihapus atau
dikoreksi otomatis; gunakan flag pada clean view untuk melakukan review.

## Memastikan tabel asli tidak berubah

Audit statis seluruh SQL:

```powershell
rg -n -i "\b(update|delete\s+from|insert\s+into|truncate|alter\s+table|drop\s+table)\s+(journal|inventory|master)\." sql
```

Perintah tersebut semestinya tidak menghasilkan kecocokan. Untuk verifikasi
tambahan, ambil snapshot jumlah baris sebelum dan sesudah pipeline:

```sql
SELECT 'journal.t_item_journey' AS table_name, COUNT(*) FROM journal.t_item_journey
UNION ALL SELECT 'inventory.t_item', COUNT(*) FROM inventory.t_item
UNION ALL SELECT 'journal.t_work_order', COUNT(*) FROM journal.t_work_order
UNION ALL SELECT 'journal.t_work_order_history', COUNT(*) FROM journal.t_work_order_history
UNION ALL SELECT 'journal.t_mtbf', COUNT(*) FROM journal.t_mtbf;
```

Untuk perlindungan paling kuat, jalankan pipeline dengan role PostgreSQL yang
memiliki `SELECT` pada schema sumber serta `USAGE/CREATE` hanya pada schema
`analytics`.
