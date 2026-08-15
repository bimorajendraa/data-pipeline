# production_ml

Versi minimal dan siap pakai dari pipeline prediksi kerusakan PART: **training,
retraining, dan prediction**. Tidak ada notebook, EDA, profiling, visualisasi,
ablation study, atau eksperimen di sini - semua itu tetap di
`db_om_preparation/` sebagai referensi research.

Database **hanya dibaca**. Folder ini tidak pernah membuat, mengubah, atau
menghapus object apa pun di database, dan tidak bergantung pada schema
`analytics` hasil research.

---

## Cara pakai

### 1. Persiapan (sekali saja)

```bash
pip install -r requirements.txt
cp .env.example .env      # lalu isi kredensial database
```

### 2. Training / retraining

```bash
python train.py
```

Jalankan lagi kapan pun data di database sudah bertambah. Hasilnya tersimpan
sebagai versi baru (`models/v2/`, `models/v3/`, ...). Model production hanya
diganti kalau versi baru **tidak lebih buruk** pada data uji.

### 3. Prediction

```python
from predict import predict

predict("011201100101164")
```

```python
{
    "item_id": "011201100101164",
    "failure_probability_30d": 0.045,
    "failure_probability_60d": 0.088,
    "failure_probability_90d": 0.129,
    "failure_probability_120d": 0.1682,
    "risk_level": "MEDIUM",
    "model_version": "v1",
    "as_of": "2026-08-03 11:07:22",
}
```

Bisa juga dari terminal: `python predict.py 011201100101164`

Pemanggil **cukup memberi ID PART**. Umur, jumlah kerusakan, jumlah corrective,
client, lifecycle, dan seluruh fitur lain dihitung sendiri dari database.

Kalau PART tidak dikenal atau sedang tidak terpasang, `predict()` melempar
`ItemNotScorable` dengan penjelasan alasannya.

---

## Struktur

```
production_ml/
├── config.py           # semua konstanta: fitur, hyperparameter, ambang batas
├── data_reader.py      # SELECT read-only: event bersih + siklus pemasangan
├── feature_builder.py  # observasi, riwayat point-in-time, 18 fitur model
├── train.py            # training + retraining + versioning
├── predict.py          # predict(item_id)
├── models/
│   ├── CURRENT         # berisi nama versi yang dipakai production
│   └── v1/
│       ├── model.cbm
│       ├── calibrator.joblib
│       └── metadata.json
├── requirements.txt
└── README.md
```

Alur data, sama persis untuk training dan prediction:

```
database (tabel mentah)
      |
      v
data_reader      event operasional + siklus pemasangan
      |
      v
feature_builder  observasi -> riwayat point-in-time -> 18 fitur
      |
      +--------------------+
      v                    v
   train.py            predict.py
```

Fitur dihitung oleh **satu fungsi yang sama** (`feature_builder.build_features`)
untuk training maupun prediction, jadi tidak mungkin ada perbedaan antara fitur
yang dipelajari model dan fitur yang dipakai di production.

---

## Model

| | |
|---|---|
| Algoritma | CatBoost (200 iterasi, depth 4, lr 0.03, l2 10, kelas diseimbangkan) |
| Kalibrasi | Isotonic regression, dilatih pada data validasi |
| Target | PART mengalami kerusakan dalam 30 hari setelah tanggal observasi |
| Fitur | 18 (3 kategorikal + 15 numerik) |
| Split | Berbasis waktu dengan jeda (embargo): tahun terakhir = uji, setahun sebelumnya = validasi |

Hasil training terakhir (data s/d 2026-08-03):

| Bagian | Baris | Kerusakan | ROC-AUC | PR-AUC |
|---|---|---|---|---|
| Latih | 251.568 | 3.852 | 0,8454 | 0,1196 |
| Validasi | 49.660 | 947 | 0,7399 | 0,1087 |
| Uji | 38.451 | 902 | **0,7947** | 0,1420 |

Brier terkalibrasi pada data uji: 0,0216.

### 18 fitur final

Identitas & konteks: `part_model_category`, `client_category`
Umur: `installation_age_band`, `log_days_since_installation`
Riwayat: `log_total_prior_events`, `log_prior_failure_count`, `has_prior_failure`,
`log_prior_corrective_count`, `has_prior_corrective`,
`log_days_since_last_corrective`, `log_prior_distinct_places`
Jendela waktu: `log_prior_corrective_30d`, `log_prior_failure_365d`,
`log_prior_events_180d`
Lifecycle: `log_previous_cycle_lifetime_mean`, `has_previous_cycle`
Musiman: `month_sin`, `month_cos`

### Risiko beberapa horizon

30/60/90/120 hari dihitung lewat **hazard chaining**: model 30 hari yang sama
dipakai berulang dengan fitur waktu dimajukan 30 hari tiap langkah, lalu peluang
bertahan dikalikan berantai. Keempat titik adalah kelipatan 30 hari, jadi
semuanya hasil chaining langsung tanpa interpolasi.

Cara ini menjamin `30d <= 60d <= 90d <= 120d` secara matematis. Pada pengujian
research, chaining mengalahkan classifier terpisah per horizon di ROC-AUC,
PR-AUC, maupun Brier.

Keterbatasan yang harus diingat: chaining mengasumsikan **tidak ada kejadian
baru** di antara langkah. Kalau PART benar-benar kena corrective bulan depan,
taksiran ini tidak "tahu" itu. Semakin jauh horizonnya, semakin besar pengaruh
asumsi tersebut.

### Kelompok risiko

Dibandingkan terhadap base rate validasi (frekuensi kerusakan historis
sungguhan), bukan ambang karangan:

| Kelompok | Arti |
|---|---|
| `HIGH` | >= 3x base rate |
| `MEDIUM` | >= 1x base rate |
| `LOW` | di bawah base rate |

---

## Bukti kesetaraan dengan research

Rantai pembersihan data dibangun ulang dari tabel mentah, lalu **dibandingkan
baris-per-baris** dengan view `analytics` hasil research:

| Yang dibandingkan | Hasil |
|---|---|
| Observasi training + 18 fitur + target | 356.100 baris, cocok semua, **0 selisih** |
| Snapshot PART aktif + 18 fitur | 16.877 baris, cocok semua, **0 selisih** |
| Jumlah siklus pemasangan | 24.045 (sama) |
| Ukuran split latih/validasi/uji | 251.568 / 49.660 / 38.451 (sama) |
| Jumlah kerusakan per split | 3.852 / 947 / 902 (sama) |

Selisih kecil pada metrik (uji 0,7947 di sini vs 0,7883 di research) berasal
dari **urutan baris** yang berbeda saat masuk ke CatBoost, bukan dari perbedaan
data - datanya sudah dibuktikan identik di atas.

Perbandingan ini hanya alat verifikasi sekali jalan; production tidak
membutuhkan schema `analytics` untuk beroperasi.

---

## Yang diambil dari research, dan yang tidak

**Diambil** (yang benar-benar dibutuhkan model final):

- Normalisasi kode + kanonikalisasi client/lokasi ke data master, termasuk
  pencocokan fuzzy. Bukan kosmetik: 31% baris menulis nama client dengan typo
  (`KERETE` vs `KERETA`), dan tanpa tahap ini fitur `client_category` baris-baris
  itu jatuh ke `UNKNOWN`.
- Pembuangan event RECON administratif dan tanggal tidak valid.
- Dua dasar penentuan kerusakan: pembongkaran korektif, dan pembongkaran
  preventif yang ternyata berakhir rusak sebelum dipasang lagi.
- Siklus pemasangan per PART, beserta cara siklus itu berakhir.
- Aturan kelayakan label: sebuah observasi hanya dipakai kalau hasilnya
  benar-benar bisa dipastikan.
- Pengelompokan tipe PART yang riwayatnya sedikit (< 300 observasi).

**Tidak diambil** (terbukti tidak dipakai model final):

- Fitur lokasi/TERMINAL dan seluruh hierarchy PART-TERMINAL - belum terbukti
  cukup bernilai pada ablation study.
- Hitungan relocation, preventive, repair-process, dan window 30/90 hari yang
  tidak masuk 18 fitur.
- Model 90/180 hari terpisah - kalah dari hazard chaining.
- Cox PH, Random Survival Forest, XGBoost AFT - semua kalah dari model resmi.
- Seluruh view EDA, profiling, data quality report, dan kolom audit.

---

## Dua penyimpangan yang disengaja

Keduanya membuat production lebih konsisten, dan dicatat di sini supaya tidak
terlihat seperti kelalaian.

**1. Dukungan historis tipe PART dibekukan saat training.**
Research menghitung ulang angka ini dari data terbaru setiap kali scoring.
Production memakai angka yang tersimpan di `metadata.json`. Alasannya:
kategori yang dikenal model adalah kategori pada saat model dilatih. Kalau
sebuah tipe PART melewati ambang 300 di antara dua kali training, menghitung
ulang akan memunculkan kategori yang belum pernah dilihat model. Angka ini ikut
diperbarui otomatis setiap `train.py` dijalankan. Saat ini nilainya identik
dengan hasil hitung ulang research.

**2. Batas kelompok umur memakai definisi SQL yang membuat data training.**
Umur pemasangan bersifat pecahan (mis. 90,4 hari). Definisi SQL research
memakai `< 91`, sementara kode Python research memakai batas `<= 90` - keduanya
berbeda untuk umur di antara 90 dan 91 hari. Production mengikuti definisi SQL,
karena itulah yang dipakai saat model belajar.

---

## Asal-usul setiap konstanta

Tidak ada angka yang dikarang. Semuanya dari hasil research yang sudah diuji:

| Konstanta | Nilai | Asal |
|---|---|---|
| Hyperparameter CatBoost | depth 4, lr 0,03, l2 10 | pencarian hyperparameter, notebook 05 |
| Jumlah iterasi | 200 (tetap, bukan early stopping) | early stopping berbasis AUC bisa berhenti sangat prematur pada validasi yang positifnya sedikit |
| Horizon target | 30 hari | model resmi research |
| Ambang dukungan tipe PART | 300 observasi | rare-category ablation |
| Batas kelompok umur | 91/181/366/731/1461 hari | definisi fitur SQL research |
| Ambang risiko | 3x dan 1x base rate validasi | diuji pada data uji 2026 |
| Ambang fuzzy | skor >= 0,90 dan selisih >= 0,08 | aturan pencocokan research |
| Alias lokasi disetujui | GUDANG NUTECH -> GUDANG NI | sudah diverifikasi reviewer research |
| Singkatan | JKT -> JAKARTA | sudah diverifikasi reviewer research |

---

## Catatan operasional

- **Waktu jalan**: `train.py` sekitar 1-2 menit. `predict()` sekitar 2 detik
  untuk satu PART (pemanggilan berikutnya dalam proses yang sama lebih cepat
  karena model dan mapping teks sudah dimuat).
- **`as_of`** menunjukkan tanggal kejadian terbaru di database, bukan waktu
  sekarang. Kalau database berhenti terisi, nilai ini berhenti bergerak - itu
  sinyal yang berguna, bukan bug.
- **Data uji kecil**: kalau data uji punya kurang dari 30 kerusakan, `train.py`
  mencetak peringatan. Metrik pada sampel sekecil itu sangat berisik.
- **Membaca saja**: koneksi dibuka dengan `default_transaction_read_only=on`,
  jadi query yang mencoba menulis akan ditolak PostgreSQL - bukan sekadar janji
  di dokumentasi.
