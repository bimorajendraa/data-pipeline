# Model risiko SCRAP: kapan sebuah PART benar-benar mati

Fase lanjutan dari model klasifikasi 30 hari. Model lama menjawab **kapan PART
akan rusak**; dokumen ini membahas pertanyaan berikutnya: **kalau sudah rusak,
apakah PART itu benar-benar mati (UNREPAIRABLE) atau masih bisa diperbaiki.**

Implementasi: `src/train_unrepairable_model.py`
Artefak: `models/unrepairable_scrap_model.joblib`, `models/unrepairable_scrap_metadata.json`

Tidak ada file, view, notebook, atau model yang sudah ada yang diubah.

---

## 1. Temuan yang mengubah bentuk pertanyaan

Rencana awal adalah memodelkan **waktu menuju UNREPAIRABLE**. Data menunjukkan
itu bukan pertanyaan yang tepat:

| Hasil episode | Jumlah | Median onset -> vonis |
|---|---|---|
| Diperbaiki | 707 | 2,3 hari |
| Dibuang (scrap) | 56 | **2,9 hari** |

Begitu PART dibongkar karena rusak, vonis bengkel keluar dalam hitungan hari -
bukan bulan. Artinya "kapan" praktis **sudah dijawab model 30 hari yang ada**:
tanggal kerusakan menentukan tanggal vonis. Melatih model survival "waktu
menuju unrepairable" di atas 55 kejadian hanya akan memodelkan antrean bengkel,
bukan kondisi PART.

Karena itu targetnya digeser ke pertanyaan yang belum terjawab dan bisa
ditindaklanjuti: **saat PART rusak, apakah kerusakan ini berakhir dibuang?**
Jawabannya berguna langsung - kalau ya, pengadaan pengganti bisa dimulai hari
itu juga, tidak menunggu vonis bengkel.

## 2. Populasi dan target

- **Target**: hasil episode berstatus `UNREPAIRABLE` atau `BROKEN` (dibuang),
  lawan `REPAIRED` (kembali dipakai).
- **Populasi**: episode kerusakan sejak **2025-04-01** yang vonisnya sudah
  tercatat. Batas tanggal ini bukan pilihan bebas - status `UNREPAIRABLE` baru
  muncul pertama kali 2025-04-23 bersama proses repair detail. Sebelum itu PART
  yang dibuang tidak bisa dibedakan dari PART yang sekadar hilang dari catatan,
  jadi memasukkannya akan menciptakan label negatif palsu.
- **Ukuran**: 708 episode, **55 dibuang (7,8%)**.
- **Split waktu**: latih 2025-04..2026-03 (568 baris, 25 scrap), uji
  2026-04..2026-08 (140 baris, 30 scrap).

## 3. Perbandingan model

Lima kandidat, dinilai dengan tiga cara. Pemilihan memakai **PR-AUC
rolling-origin** (rata-rata pada tiga titik potong waktu berturut-turut) -
bukan angka uji akhir, dan bukan CV acak.

| Model | CV acak | Validasi waktu | Rolling ROC | **Rolling PR** | Uji ROC | Uji PR |
|---|---|---|---|---|---|---|
| Selalu "bisa diperbaiki" | 0,500 | 0,500 | 0,500 | 0,168 | 0,500 | 0,214 |
| Regresi Logistik | 0,662 | 0,589 | 0,630 | 0,269 | 0,685 | 0,388 |
| **Random Forest** | 0,726 | 0,623 | 0,761 | **0,383** | **0,836** | **0,511** |
| Extra Trees | 0,676 | 0,623 | 0,663 | 0,316 | 0,687 | 0,395 |
| Gradient Boosting | 0,748 | 0,677 | 0,765 | 0,372 | 0,784 | 0,503 |

**Random Forest terpilih.** Gradient Boosting sebenarnya seri secara praktis
(ROC 0,765 vs 0,761; PR 0,372 vs 0,383) - pada 55 kejadian selisih sekecil itu
belum bisa disebut beda nyata, dan keduanya sama-sama masuk akal dipakai.

### Kenapa PR-AUC, bukan ROC-AUC, yang dijadikan penentu

Kejadian scrap jarang (7,8%). Yang dibutuhkan operasional adalah menaruh
episode yang benar-benar berakhir dibuang di peringkat atas daftar, dan itulah
yang diukur PR-AUC. ROC-AUC tetap dilaporkan, tetapi pada data sekecil ini
selisihnya antar-kandidat teratas lebih kecil daripada ketidakpastiannya
sendiri.

## 4. Pelajaran metodologis: fitur banyak justru merugikan

Percobaan tiga set fitur memberi hasil yang berlawanan arah antara validasi dan
pengujian:

| Set fitur | CV acak | Validasi waktu | **Uji ROC-AUC** |
|---|---|---|---|
| A - 7 fitur inti | 0,726 | 0,623 | **0,836** |
| B - 12 fitur | 0,740 | 0,695 | 0,818 |
| C - 23 fitur | 0,816 | 0,804 | 0,773 |

Set 23 fitur terlihat **paling meyakinkan saat divalidasi** dan justru
**paling buruk saat diuji**. Dengan Gradient Boosting efeknya lebih ekstrem
lagi: validasi 0,826, uji 0,583.

Sebabnya sampel: 25 kejadian scrap di data latih. Aturan lazim "minimal 10
kejadian per variabel" hanya membenarkan segelintir fitur. Model dengan 23
fitur punya cukup kebebasan untuk menghafal ciri periode latih, dan ciri itu
tidak bertahan ke periode berikutnya.

**Set A dipilih atas dasar ukuran sampel, bukan karena menang di data uji** -
kalau tidak, pemilihannya akan mengintip jawaban.

## 5. Fitur final (7)

| Fitur | Arti |
|---|---|
| `log_age_total` | Umur PART sejak pertama kali tercatat (bukan umur siklus ini saja) |
| `log_cycle_age` | Lama PART terpasang pada siklus berjalan sampai rusak |
| `log_prior_repaired_count` | Berapa kali PART ini pernah berhasil diperbaiki |
| `has_prior_repair` | Pernah diperbaiki atau belum sama sekali |
| `log_prior_failure_count` | Jumlah kerusakan sebelumnya |
| `is_first_failure_ever` | Apakah ini kerusakan pertamanya |
| `item_type_category` | Jenis PART (yang episodenya < 20 digabung) |

Semuanya dihitung **hanya dari event pada atau sebelum kejadian kerusakan itu
sendiri**, dengan pembanding `(waktu, journey_id)` supaya event berdetik sama
tetap terurut benar.

### Profil PART yang berakhir dibuang

| | Diperbaiki | Dibuang |
|---|---|---|
| Umur total | 1.646 hari | **2.526 hari** |
| Umur siklus berjalan | 750 hari | **1.701 hari** |
| Jumlah perbaikan sebelumnya | 1,12 | **0,49** |
| Jumlah kerusakan sebelumnya | 2,44 | **1,75** |

Polanya konsisten dan masuk akal secara teknis: **PART tua yang baru pertama
kali rusak cenderung langsung dibuang**, sedangkan PART yang sudah pernah
berhasil diperbaiki terbukti masih bisa diperbaiki lagi.

Kontribusi fitur pada model terpilih: `log_age_total` 0,26; jenis PART UPS
0,19; jenis dukungan-rendah 0,17; `log_cycle_age` 0,14.

Ablation memastikan tidak ada satu fitur yang mendominasi - jadi hasilnya bukan
artefak satu kolom yang bocor:

| Fitur yang dipakai | Uji ROC-AUC |
|---|---|
| Umur total saja | 0,595 |
| Jenis PART saja | 0,663 |
| Umur total + umur siklus | 0,777 |
| Umur + riwayat (tanpa jenis PART) | 0,772 |
| **Ketujuhnya** | **0,836** |

## 6. Hasil akhir pada data uji

Ambang ditetapkan dari **data latih** (prediksi out-of-fold, memaksimalkan
balanced accuracy), lalu dipakai apa adanya di data uji.

| Metrik | Nilai |
|---|---|
| ROC-AUC | **0,836** |
| PR-AUC | **0,511** (tebakan acak 0,214 - naik 2,4x) |
| Akurasi | 70,7% |
| Balanced accuracy | **76,5%** |
| Presisi | 41,3% |
| Recall | **86,7%** |

Dari 140 episode kerusakan, model menandai 63 sebagai berisiko dibuang dan
berhasil menangkap **26 dari 30** yang benar-benar dibuang.

### Peringatan penting soal angka "akurasi"

**Menebak "semua bisa diperbaiki" menghasilkan akurasi 78,6%** - lebih tinggi
daripada model, tapi menangkap nol PART mati dan sama sekali tidak berguna.
Ini jebakan akurasi pada data tidak seimbang.

Ukuran yang benar-benar berarti di sini adalah **balanced accuracy 76,5%**
(tebakan buta = 50%) dan **ROC-AUC 0,836**. Keduanya melewati target 70% dengan
jelas; akurasi mentah 70,7% juga melewatinya, tetapi bukan angka yang layak
dijadikan patokan utama.

### Titik kerja alternatif

Ambang bisa digeser sesuai kebutuhan. Tabel ini disertakan sebagai bahan
pertimbangan operasional, bukan dasar pemilihan model:

| Ambang | Akurasi | Balanced acc | Presisi | Recall | Ditandai |
|---|---|---|---|---|---|
| 0,45 | 66,4% | 77,4% | 38,7% | 96,7% | 75 |
| **0,51** | **70,7%** | **76,5%** | **41,3%** | **86,7%** | **63** |
| 0,55 | 77,9% | 81,1% | 49,1% | 86,7% | 53 |
| 0,60 | 78,6% | 76,7% | 50,0% | 73,3% | 44 |

Ambang 0,55 terlihat paling seimbang, tetapi angkanya dihitung **setelah**
melihat data uji, jadi tidak dipakai sebagai default. Kalau nanti data
bertambah, ambang sebaiknya ditetapkan ulang dari data latih.

## 7. Keterbatasan

Empat hal wajib dibaca sebelum hasil ini dipakai mengambil keputusan.

1. **Sampel sangat kecil.** 55 kejadian scrap, 30 di antaranya di data uji.
   Semua metrik punya rentang ketidakpastian lebar. Model ini layak dipakai
   sebagai alat bantu prioritas, belum layak jadi keputusan otomatis.

2. **Base rate bergeser tajam.** Persentase scrap per kuartal: 2,8% -> 6,3% ->
   4,1% -> 4,3% -> **23,5%** -> 18,6%. Lonjakan 2026-Q2 bersamaan dengan
   melonjaknya status `BROKEN` (37 kejadian dalam satu kuartal, dari sebelumnya
   3-4). Ini kemungkinan besar perubahan cara pencatatan, bukan PART yang
   mendadak delapan kali lebih rapuh. Akibatnya **peringkat risiko jauh lebih
   bisa dipercaya daripada angka probabilitas absolutnya** - probabilitas
   perlu dikalibrasi ulang sebelum dibaca sebagai persentase.

3. **Separuh episode tidak punya vonis tercatat, dan porsinya membesar.**

   | Kuartal | Tanpa vonis | Ada vonis |
   |---|---|---|
   | 2025-Q2 | 213 | 211 |
   | 2025-Q4 | 227 | 123 |
   | 2026-Q2 | 464 | 81 |

   Model hanya belajar dari episode yang bengkelnya benar-benar mencatat hasil.
   Memakainya untuk seluruh kerusakan berarti mengandaikan episode yang
   tercatat mewakili yang tidak tercatat - dan itu **tidak bisa diverifikasi
   dari data yang ada**. Ini keterbatasan terbesar, dan perbaikannya ada di
   sisi disiplin pencatatan, bukan di sisi model.

4. **Jenis PART bisa berubah perilaku.** MOTOR punya rate scrap 1,5% di periode
   latih dan 21,7% di periode uji. Model tidak bisa mengantisipasi pergeseran
   semacam ini; kekuatannya datang dari fitur umur yang lebih stabil.

## 8. Saran langkah berikutnya

- **Kumpulkan data lebih dulu.** Dengan ~15 kejadian scrap per kuartal, setahun
  lagi jumlahnya kira-kira dua kali lipat. Itu jauh lebih berharga daripada
  mengutak-atik model pada sampel sekarang.
- **Perbaiki kelengkapan vonis bengkel.** Menaikkan porsi episode yang
  vonisnya tercatat akan memperbaiki model ini lebih besar daripada algoritma
  apa pun.
- **Kalibrasi ulang sebelum menampilkan persentase.** Selama base rate masih
  bergeser, tampilkan peringkat atau kelompok risiko, bukan angka probabilitas.
- **Jangan tambah fitur dulu.** Bagian 4 sudah menunjukkan menambah fitur pada
  sampel sekecil ini menurunkan performa sesungguhnya.
