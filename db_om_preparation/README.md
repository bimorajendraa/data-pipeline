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
            -> validasi master -> view live -> cache laporan -> EDA
            -> baseline model -> Grafana
```

Pipeline sudah menyiapkan fitur historis untuk EDA dan sudah melatih baseline
model (dummy, Logistic Regression, CatBoost) sebagai patokan awal - belum
model produksi. Tidak ada n8n, Airflow, Kafka, Spark, dbt, data warehouse, atau
perhitungan ulang MTBF di tahap ini.

Sumber utama flow adalah `journal.t_item_journey`. Work order hanya menjadi
validasi/pelengkap bila `wo_code` tersedia. MTBF dipertahankan sebagai data
suplementer dan tidak menentukan flow. MTTR tidak masuk pipeline aktif karena
tabelnya kosong pada backup; tabel sumbernya tetap dibiarkan utuh.

## Isi proyek

| File | Tujuan | Hasil yang diharapkan |
|---|---|---|
| `sql/01_create_analytics_schema.sql` | Membuat schema, fungsi normalisasi teks, dan tabel mapping terverifikasi | Schema `analytics`; fungsi cleaning, candidate key nama, serta mapping singkatan/alias yang dapat diaudit |
| `sql/02_data_profiling.sql` | Memeriksa jumlah baris, null/kosong, unik, duplikat, variasi case/spasi, top value, dan rentang tanggal | Cache `analytics.data_profile` dan kandidat standardisasi nama |
| `sql/03_item_journey_clean.sql` | Membersihkan journey, menyusun urutan event, dan memprofilkan transisi aktual | `analytics.item_journey_clean`, cache `analytics.item_journey_transition_profile` |
| `sql/04_item_clean.sql` | Membersihkan inventory dan memvalidasi master item/lokasi/status | `analytics.item_clean` |
| `sql/05_work_order_clean.sql` | Membersihkan WO dan membandingkan status dengan history terakhir | `analytics.work_order_clean` |
| `sql/06_work_order_history_clean.sql` | Membersihkan history, memeriksa orphan WO dan urutan tanggal | `analytics.work_order_history_clean` |
| `sql/07_mtbf_clean.sql` | Membersihkan MTBF sebagai sumber suplementer, mempertahankan menit, dan menambah konversi jam | `analytics.mtbf_clean` |
| `sql/08_data_quality_summary.sql` | Menyatukan quality check dan daftar validasi status | Cache `analytics.data_quality_summary`, `analytics.status_validation` |
| `sql/09_failure_event_label.sql` | Menambahkan label failure onset berdasarkan keputusan bisnis | `analytics.item_journey_failure_labeled`, cache `analytics.failure_event_clean` |
| `sql/10_operational_timeline.sql` | Memisahkan event operasional dari RECON administratif dan mengonfirmasi flow failure | `analytics.item_journey_semantic`, `analytics.item_journey_operational_timeline`, `analytics.failure_event_flow` |
| `sql/11_item_installation_cycle.sql` | Membentuk siklus dari INSTALLED tepercaya sampai failure/reinstall/censoring serta mengaudit kepastian akhir siklus | `analytics.item_installation_cycle` |
| `sql/12_item_observation_dataset.sql` | Membentuk snapshot 30-harian dan memisahkan fitur saat observasi, label masa depan, serta kolom audit | `analytics.item_observation_30d`, `item_observation_30d_features`, `item_observation_30d_labels`, dan `item_observation_30d_audit` |
| `sql/12b_item_terminal_hierarchy.sql` | Menghubungkan setiap installation cycle PART ke perangkat induk (TERMINAL) dan memperkaya observation dataset dengan relasi tersebut | `analytics.eda_part_terminal_cycle_link`, `analytics.eda_item_observation_30d_hierarchy` |
| `sql/13_eda_views.sql` | Menyatukan readiness, kualitas, distribusi, tren, lifecycle, target, ringkasan struktur dan analisis bivariat PART-TERMINAL, stability, dan refresh dependency | Seluruh view pendukung EDA serta materialized summary cadence/drift |
| `sql/14_feature_engineering.sql` | Membakukan keputusan keep/drop dan mentransformasi fitur point-in-time untuk modeling | Feature catalog, baseline feature cache, challenger features, label/split terpisah, audit, dan quality summary |
| `sql/15_current_risk_snapshot.sql` | Menghitung ulang fitur yang sama seperti baseline, tapi khusus untuk PART aktif pada observation_on = kejadian terbaru di database (bukan grid 30-harian) supaya skor operasional tidak basi | `analytics.item_current_snapshot_features`, dipakai `score_current_risk.py` |
| `queries/eda_manual_checks.sql` | Menyediakan query pemeriksaan manual tanpa tercampur dengan DDL pipeline | Preview dan drill-down audit yang aman dijalankan terpisah |
| `notebooks/01a_business_eda.ipynb` | EDA operasional/bisnis: tren, reliability per model/lokasi/klien, efektivitas perbaikan, repeat failure, relokasi, dan kualitas pencatatan antar-era | Tabel, grafik, dan kesimpulan/rekomendasi untuk tim maintenance |
| `notebooks/01b_feature_selection_eda.ipynb` | EDA kesiapan data dan pemilihan fitur: leakage check, imbalance, korelasi/IV, stability/PSI, dan keputusan fitur | Tabel, grafik, pemeriksaan leakage, dan usulan time split |
| `notebooks/02_baseline_model.ipynb` | Melatih dan membandingkan dummy, Logistic Regression, dan CatBoost pada fitur baseline dengan split waktu train/validasi/test yang sudah tersedia | Tabel perbandingan PR-AUC/ROC-AUC/precision-recall@K, kurva kalibrasi, dan rekomendasi model |
| `notebooks/03_ablation_study.ipynb` | Melatih CatBoost bertahap per kelompok fitur (model+umur -> +riwayat kerusakan -> +aktivitas/klien -> +lokasi -> +hierarki TERMINAL) untuk melihat fitur mana yang benar-benar menambah akurasi | Tabel kenaikan PR-AUC per kelompok, precision/recall@K, dan rekomendasi kombinasi fitur paling sederhana yang tetap kuat |
| `notebooks/04_sensitivity_analysis.ipynb` | Membandingkan tiga aturan kelayakan label negatif (Normal, Strict berbasis jarak waktu, dan RECON-verified berbasis ada/tidaknya RECON belakangan) untuk menguji ketahanan model terhadap ketidakpastian label negatif | Tabel perbandingan jumlah data, ROC-AUC/PR-AUC, precision/recall@K, dan rekomendasi aturan kelayakan terbaik |
| `notebooks/05_final_baseline_tuned.ipynb` | Model baseline resmi: fitur kelompok C + aturan RECON-verified, hyperparameter disetel terbatas, dicek konsistensi train/validasi/test (deteksi overfitting), dan probabilitas dikalibrasi | Tabel pencarian hyperparameter, tabel konsistensi ROC-AUC per split, kurva kalibrasi sebelum/sesudah, dan model baseline resmi |
| `notebooks/06_survival_analysis.ipynb` | **Eksperimen terpisah** (tidak menggantikan model resmi): Cox Proportional Hazards per siklus pasang (bukan snapshot 30-harian) untuk mengurutkan PART mana yang waktunya paling dekat ke kerusakan, plus uji formal asumsi proportional-hazards | Kurva Kaplan-Meier, koefisien Cox, tabel C-index, uji asumsi (dilanggar signifikan), dan kesimpulan jujur soal batasan/kegunaannya |
| `notebooks/07_evaluation_harness.ipynb` | Menyatukan seluruh model/eksperimen (klasifikasi 30 hari resmi, sanity check autokorelasi snapshot-vs-cycle, multi-horizon classifier-vs-hazard-chaining, ringkasan survival) dalam satu perbandingan - tidak melatih model baru | Tabel perbandingan konsolidasi dan rekomendasi mana yang dipakai operasional vs referensi |
| `src/export_eda_report.py` | Menjalankan kedua notebook, mengekspor HTML, dan membuat ringkasan eksekutif dari hasil database terkini | `reports/business_eda.html`, `reports/feature_selection_eda.html`, dan `reports/eda_executive_summary.md` |
| `src/run_pipeline.py` | Menjalankan semua SQL secara urut dan transactional per file | Seluruh view analytics tersedia |
| `src/export_quality_report.py` | Mengekspor profiling dan quality summary | Dua CSV di folder `reports` |
| `src/train_final_model.py` | Melatih model baseline resmi (fitur kelompok C, aturan RECON-verified, hyperparameter dari `05_final_baseline_tuned.ipynb`) dan menyimpan model + kalibrator | `models/failure_30d_baseline_catboost.cbm`, `models/failure_30d_baseline_calibrator.joblib`, `models/failure_30d_baseline_metadata.json` |
| `src/score_current_risk.py` | Memberi skor risiko 30 hari untuk PART yang saat ini masih aktif, memakai model tersimpan | `reports/current_risk_ranking.csv` |
| `src/train_multi_horizon_models.py` | **Challenger terpisah** (tidak menggantikan model 30 hari resmi): melatih model 90 dan 180 hari dengan fitur/hyperparameter identik, plus pengecekan monotonicity P(30d)<=P(90d)<=P(180d) | `models/failure_90d_*`, `models/failure_180d_*`, `models/failure_multi_horizon_metadata.json` |
| `src/score_multi_horizon_risk.py` | Skor 30/90/180 hari untuk PART aktif lewat "hazard chaining" - memakai model 30 hari resmi apa adanya (bukan model baru), fitur diputar maju per 30 hari. Menjamin monotonicity secara matematis DAN terbukti lebih akurat daripada classifier 90/180 hari terpisah pada backtest TEST_2026 (lihat `hazard_chaining_vs_direct_classifier` di metadata) | `reports/current_risk_ranking_multi_horizon.csv` |

Kesimpulan kesiapan, kejanggalan, risiko timeline, dan keputusan berikutnya
dibuat otomatis di `reports/eda_executive_summary.md` ketika laporan diekspor.

Nilai `*_original` dipertahankan pada clean views agar setiap normalisasi dapat
ditelusuri. Record yang gagal validasi tidak dihapus.
Underscore pada nama petugas/client hanya digunakan untuk menyusun kandidat
standardisasi di hasil profiling; clean view tidak menggabungkan nama tersebut
secara otomatis.

### Pencocokan lokasi dan client

Pencocokan selalu mendahulukan kode atau nama yang sama persis dengan master.
Fuzzy matching baru dijalankan untuk nilai yang belum cocok. Kandidat hanya
diterima otomatis apabila kemiripan minimal 90% dan unggul minimal 8 poin dari
kandidat kedua. Nama sumber, kandidat, skor, margin, dan metode mapping tetap
disimpan agar keputusan dapat diaudit.

Singkatan dan alias yang telah diverifikasi tidak ditanam langsung di fungsi.
Nilainya disimpan pada `analytics.text_abbreviation_mapping`,
`analytics.verified_location_alias`, dan `analytics.verified_client_alias`
bersama dasar mapping, penyetuju, waktu persetujuan, serta status aktif.

- `KERETE COMMUTER INDONESIA (KCI)` diterima sebagai typo dari
  `KERETA COMMUTER INDONESIA (KCI)` karena melewati kedua batas aman.
- `GUDANG NUTECH` dipetakan ke `GUDANG NI` sebagai alias kontekstual yang sudah
  diverifikasi dari tumpang-tindih item dan alur aktivitas gudang; keputusan ini
  bukan semata-mata berdasarkan kemiripan tulisan.
- `NOC JUANDA` tidak dipetakan otomatis karena kandidat lokasi Juanda terlalu
  berdekatan. Event tetap tersedia, tetapi fitur lokasinya ditahan untuk review.

Perhitungan Levenshtein dilakukan satu kali untuk setiap nilai unik dan disimpan
di cache schema `analytics`, sehingga pembacaan view dan laporan tidak perlu
menghitung ulang kemiripan untuk setiap event.

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
3. Jalankan 16 file di folder `sql` sesuai urutan nama file: `01` sampai `12`,
   lalu `12b`, lalu `13`, `14`, dan `15`.
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
jupyter lab notebooks\01a_business_eda.ipynb
jupyter lab notebooks\01b_feature_selection_eda.ipynb
```

Setelah pipeline SQL berjalan, model baseline resmi dapat dilatih dan dipakai
scoring dengan:

```powershell
python src\train_final_model.py
python src\score_current_risk.py
```

`train_final_model.py` menyimpan model, kalibrator, dan metadata performa ke
folder `models/`. `score_current_risk.py` memberi skor risiko 30 hari untuk
seluruh PART yang saat ini masih aktif (belum rusak, belum dipasang ulang),
memakai `analytics.item_current_snapshot_features` (`sql/15`) yang menghitung
ulang fitur historis pada observation_on = kejadian terbaru yang tercatat di
database - bukan snapshot grid 30-harian dari dataset training, yang bisa
tertinggal sampai ~29 hari. Kolom `hari_sejak_data_terakhir` di hasilnya
menunjukkan seberapa baru database itu sendiri (bukan lagi soal snapshot
yang basi). PART langsung mendapat skor sejak hari pertama dipasang, tidak
perlu menunggu snapshot 30 hari pertama.

`notebooks/06_survival_analysis.ipynb` adalah eksperimen **terpisah** dan
**opsional** (analisis waktu-ke-kerusakan/C-index) - tidak dipakai oleh
`train_final_model.py` maupun `score_current_risk.py`, dan tidak wajib
dijalankan untuk memakai model resmi. Butuh dependensi tambahan
`lifelines` (lihat `requirements.txt`).

`python src\train_multi_horizon_models.py` melatih challenger 90/180 hari
(fitur & hyperparameter identik dengan model 30 hari resmi) - juga **terpisah
dan opsional**, tidak menimpa model resmi. Evaluasi TEST_2026 untuk 180 hari
punya keterbatasan nyata: observation_on setelah (dataset_max_event_on - 180
hari) hanya bisa lolos syarat kelayakan lewat siklus yang SUDAH gagal (hasil
"tidak gagal" belum bisa dikonfirmasi penuh sampai windownya berakhir) -
angka yang bisa dipercaya ada di `test_2026_clean_subset` pada
`models/failure_multi_horizon_metadata.json`, bukan angka gabungan mentah.

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
PREVENTIVE, WAREHOUSE_RECEPTION, BULK_WAREHOUSE_RECEPTION,
NORMAL_OPERATION
```

`BULK_WAREHOUSE_RECEPTION` adalah penerimaan barang gudang dalam jumlah besar.
Semantic ini tetap disimpan sebagai event operasional, tetapi bukan installation,
dismantle, atau failure. Contoh utamanya adalah 4.011 event pada 3 Juli 2024.

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
hanya layak training jika tersedia follow-up penuh 30 hari dan cycle tidak
berakhir hanya karena reinstall tanpa failure yang tercatat. Snapshot reinstall
tersebut diberi `EXCLUDED_UNKNOWN_REINSTALL_WITHOUT_FAILURE`, bukan otomatis
negatif. Snapshot dekat batas data atau akhir cycle diberi
`EXCLUDED_INCOMPLETE_30D_FOLLOWUP`. Snapshot jauh sebelum failure nyata tetap
boleh menjadi negatif bila failure tersebut berada di luar horizon 30 hari.
Flag strict tambahan menerima negatif dari cycle failure terkonfirmasi atau
right-censored cycle yang aktivitas akhirnya masih terkonfirmasi. Seluruh fitur
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

EDA dipecah menjadi dua notebook agar tujuannya tidak tercampur. Notebook
`01a_business_eda.ipynb` menjawab pertanyaan operasional: sebaran item/model/
lokasi, tren kerusakan, reliability per model/lokasi/klien, efektivitas
perbaikan (rusak sampai kembali dipasang), repeat failure, kaitan relokasi
dengan kerusakan, dan kualitas pencatatan antar-era dalam bahasa yang mudah
dibaca tim operasional. Notebook `01b_feature_selection_eda.ipynb`
membandingkan era lama dan era detail repair, target imbalance, missingness
beserta strategi penanganan, umur sampai failure, model dengan dukungan sampel
minimum, fitur failure/nonfailure, serta split waktu. Notebook ini juga
menampilkan matriks Pearson dan Spearman, pasangan fitur redundan, screening
Information Value (IV), cakupan master lokasi/client pada level snapshot, tren
fitur bulanan, dan Population Stability Index (PSI) terhadap referensi 2024.
IV hanya screening univariat, sedangkan PSI hanya indikator drift; keduanya tidak
menggantikan validasi model secara temporal. Rekomendasi awal split adalah train
sampai 2024, validation 2025, dan test 2026; keputusan final tetap mengikuti
hasil EDA.

Relasi PART ke perangkat induk ditentukan per installation cycle melalui
`t_item_request_out`: serial PART dan work order installation menunjuk
`parent_serial_code` TERMINAL. View `analytics.eda_part_terminal_cycle_link`
mempertahankan status validasi master/inventory dan flag bila relasi historis
dicatat setelah installation. EDA menampilkan positive rate, risk ratio, Wilson
95%, minimum support, serta Cramer's V untuk tipe/model TERMINAL. Screening
multivariat membandingkan Logistic Regression L2 PART-only, PART+TERMINAL, dan
adjusted operational history pada split waktu. Relasi terminal yang backfilled
tetap harus diuji melalui sensitivity analysis sebelum fitur dipakai produksi.

## Feature engineering untuk modeling

Keputusan fitur disimpan pada `analytics.failure_30d_feature_catalog` dengan
status `KEEP_BASELINE`, `KEEP_CHALLENGER`, `AUDIT_ONLY`, atau kelompok `DROP_*`.
Layer modeling dipisahkan agar target masa depan tidak ikut terbaca:

```text
analytics.failure_30d_baseline_features
    Feature-only, cache berindeks, transformasi baseline yang parsimonious

analytics.failure_30d_challenger_features
    Baseline + lokasi + hierarchy terminal + interaksi terkontrol

analytics.failure_30d_model_labels
    Target, eligibility, dan temporal split; tidak berisi predictor

analytics.failure_30d_model_audit
    Gabungan untuk QA/penelusuran saja; dilarang sebagai input training langsung
```

Count dan duration yang skewed memakai `log1p`. Missing recency corrective
bersifat struktural sehingga direpresentasikan sebagai nilai log nol bersama
flag missing/`has_prior_corrective`. Bulan dibuat siklik menggunakan pasangan
sin-cos. Quarter, weekend, timestamp absolut, identifier sebagai predictor,
fitur lemah, fitur redundan, dan seluruh kolom future/observability tidak masuk
baseline. Join feature-label wajib memakai `installation_cycle_id`,
`item_identifier_clean`, dan `observation_on`.

Runner hanya menerima `DB_NAME=OMEXP`. Runner juga menolak DDL database serta
SQL yang berisi `UPDATE`, `DELETE`, `INSERT`, `TRUNCATE`,
`ALTER TABLE`, atau `DROP TABLE` terhadap schema `journal`, `inventory`, dan
`master`. Transaksi satu file akan di-rollback jika file tersebut gagal.

Hasil ekspor:

- `reports/data_profile.csv`
- `reports/data_quality_summary.csv`
- `reports/business_eda.html`
- `reports/feature_selection_eda.html`
- `reports/eda_executive_summary.md`

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
