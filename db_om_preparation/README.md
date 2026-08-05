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

Tidak ada feature engineering prediktif, training model, n8n, Airflow, Kafka,
Spark, dbt, data warehouse, atau perhitungan ulang MTBF di tahap ini.

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
| `src/run_pipeline.py` | Menjalankan semua SQL secara urut dan transactional per file | Seluruh view analytics tersedia |
| `src/export_quality_report.py` | Mengekspor profiling dan quality summary | Dua CSV di folder `reports` |

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
3. Jalankan file di folder `sql` dari `01` sampai `08`, satu per satu.
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
```

`run_pipeline.py` memperbarui clean view sekaligus membangun cache untuk tiga
hasil agregasi yang berat. Karena dihitung sekali saat setup, step `02`, `03`,
dan `08` dapat memerlukan beberapa detik, tetapi pembukaan di DBeaver dan proses
`export_quality_report.py` menjadi cepat.

Setelah tabel sumber menerima data baru, perbarui seluruh cache dengan:

```sql
CALL analytics.refresh_cached_views();
```

Clean view tetap membaca data sumber terbaru secara langsung. Cache yang perlu
di-refresh adalah `data_profile`, `item_journey_transition_profile`, dan
`data_quality_summary`; rumus dan quality check-nya sama dengan versi live.

Runner hanya menerima `DB_NAME=OMEXP`. Runner juga menolak DDL database serta
SQL yang berisi `UPDATE`, `DELETE`, `INSERT`, `TRUNCATE`,
`ALTER TABLE`, atau `DROP TABLE` terhadap schema `journal`, `inventory`, dan
`master`. Transaksi satu file akan di-rollback jika file tersebut gagal.

Hasil ekspor:

- `reports/data_profile.csv`
- `reports/data_quality_summary.csv`

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
