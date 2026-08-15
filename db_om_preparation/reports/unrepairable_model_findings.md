# Model risiko SCRAP: apakah sebuah kerusakan berakhir dengan PART dibuang

Fase lanjutan dari model klasifikasi 30 hari. Model lama menjawab **kapan PART
akan rusak**; dokumen ini membahas pertanyaan berikutnya: **kalau sudah rusak,
apakah PART itu benar-benar mati (UNREPAIRABLE) atau masih bisa diperbaiki.**

Implementasi: `src/train_unrepairable_model.py`
Artefak: `models/unrepairable_scrap_model.joblib`, `models/unrepairable_scrap_metadata.json`

Tidak ada file, view, notebook, atau model yang sudah ada yang diubah.

> **Catatan revisi.** Versi pertama dokumen ini melaporkan ROC-AUC 0,836.
> Angka itu **terlalu optimis** dan sudah diperbaiki. Penyebabnya dibahas di
> Bagian 3: model hanya dilatih dan diuji pada episode yang kebetulan dicatat
> vonisnya oleh bengkel, dan populasi itu jauh lebih banyak berisi PART mati
> daripada kenyataan di lapangan. Angka yang jujur ada di Bagian 6.

---

## 1. Temuan yang mengubah bentuk pertanyaan

Rencana awal adalah memodelkan **waktu menuju UNREPAIRABLE**. Data menunjukkan
itu bukan pertanyaan yang tepat:

| Hasil episode | Median onset -> vonis |
|---|---|
| Diperbaiki | 2,3 hari |
| Dibuang (scrap) | **2,9 hari** |

Begitu PART dibongkar karena rusak, vonis bengkel keluar dalam hitungan hari -
bukan bulan. Artinya "kapan" praktis **sudah dijawab model 30 hari yang ada**:
tanggal kerusakan menentukan tanggal vonis. Melatih model survival "waktu
menuju unrepairable" di atas 46 kejadian hanya akan memodelkan antrean bengkel,
bukan kondisi PART.

Targetnya karena itu digeser ke pertanyaan yang belum terjawab dan langsung
bisa ditindaklanjuti: **saat PART rusak, apakah kerusakan ini berakhir
dibuang?** Kalau ya, pengadaan pengganti bisa dimulai hari itu juga.

## 2. Populasi dan target

- **Dibuang**: vonis bengkel `UNREPAIRABLE` atau `BROKEN`.
- **Diperbaiki**: vonis bengkel `REPAIRED`, **atau** PART yang sama terbukti
  **dipasang kembali** setelah kerusakan itu.
- **Dikecualikan**: episode tanpa vonis yang PART-nya juga tidak pernah
  dipasang lagi - bisa jadi dibuang tanpa dicatat, bisa jadi masih di bengkel,
  dan tidak ada cara membedakannya.
- **Periode**: mulai **2025-04-01**. Status `UNREPAIRABLE` baru dipakai pertama
  kali 2025-04-23 bersama proses repair detail; sebelum itu PART yang dibuang
  tidak bisa dibedakan dari yang hilang dari catatan.
- **Embargo 30 hari** di ujung data (lihat Bagian 3).
- **Hasil**: 1.407 episode, **46 dibuang (3,3%)**.
- **Split waktu**: latih 2025-04..2026-03 (1.084 baris, 25 scrap), uji
  2026-04..2026-07 (323 baris, 21 scrap).

## 3. Koreksi terpenting: bias vonis bengkel

Versi pertama hanya memakai episode yang **vonisnya dicatat bengkel**. Itu
membuang 861 episode yang sebenarnya sudah terbukti selamat lewat pemasangan
ulang - dan lebih berbahaya, membuat model hanya belajar dari potongan data
yang tidak mewakili lapangan.

Akibatnya terlihat jelas pada base rate per kuartal:

| Kuartal | Hanya vonis bengkel | Ditambah bukti pasang ulang |
|---|---|---|
| 2025-Q2 | 2,9% | 1,7% |
| 2025-Q3 | 6,3% | 3,9% |
| 2025-Q4 | 4,1% | 2,1% |
| 2026-Q1 | 4,3% | 1,0% |
| 2026-Q2 | **23,5%** | 6,2% |
| 2026-Q3 | 18,6% | 10,5% |

"Ledakan" ke 23,5% yang di versi pertama saya laporkan sebagai perubahan cara
pencatatan ternyata **sebagian besar artefak seleksi**: di kuartal itu bengkel
mencatat vonis untuk makin sedikit episode (464 tanpa vonis vs 81 ada vonis),
dan yang tercatat condong ke kasus fatal. Setelah pemasangan ulang ikut
dihitung, tren yang tersisa naik perlahan dan jauh lebih masuk akal.

**Embargo 30 hari** ditambahkan karena bukti dua arah datang dengan kecepatan
berbeda: vonis "dibuang" muncul median 2,9 hari, sedangkan bukti "diperbaiki"
lewat pemasangan ulang butuh lebih lama (median 5,9 hari, p80 30 hari). Tanpa
embargo, periode terbaru akan tampak penuh kerusakan fatal semata-mata karena
bukti selamatnya belum sempat muncul.

## 4. Perbandingan model

Enam kandidat. Pemilihan memakai **PR-AUC rolling-origin** (rata-rata pada tiga
titik potong waktu berturut-turut) - bukan angka uji akhir, dan bukan CV acak.
PR-AUC dipilih karena kejadian scrap jarang: yang dibutuhkan operasional adalah
menaruh episode yang benar-benar berakhir dibuang di peringkat atas.

| Model | CV acak | Validasi waktu | Rolling ROC | **Rolling PR** | Uji ROC | Uji PR |
|---|---|---|---|---|---|---|
| Selalu "bisa diperbaiki" | 0,500 | 0,500 | 0,500 | 0,049 | 0,500 | 0,065 |
| Regresi Logistik | 0,690 | 0,616 | 0,650 | 0,152 | 0,725 | 0,232 |
| Random Forest | 0,628 | 0,571 | 0,674 | 0,128 | **0,793** | 0,208 |
| Extra Trees | 0,648 | 0,657 | 0,599 | 0,140 | 0,662 | 0,224 |
| Gradient Boosting | 0,667 | 0,688 | 0,703 | 0,115 | 0,729 | 0,133 |
| **Gabungan LogReg + RF** | 0,682 | 0,617 | 0,678 | **0,172** | 0,763 | **0,255** |

**Model gabungan terpilih**: rata-rata probabilitas regresi logistik dan random
forest. Keduanya salah dengan cara berbeda - regresi logistik menangkap
kecenderungan lurus (makin tua makin sering dibuang), random forest menangkap
ambang dan kombinasi - sehingga merata-ratakan meredam kesalahan masing-masing.
Gabungan ini menang di rolling-origin **maupun** di data uji, jadi pemilihannya
tidak bergantung pada mengintip hasil akhir.

## 5. Fitur (7)

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

Kontribusi: `log_age_total` 0,23; jenis PART UPS 0,20; jenis dukungan-rendah
0,16; `log_cycle_age` 0,15; `log_prior_repaired_count` 0,09.

**Profil PART yang berakhir dibuang: tua, baru pertama kali rusak, belum pernah
diperbaiki.** PART yang sudah pernah berhasil diperbaiki terbukti masih bisa
diperbaiki lagi.

### Kenapa fitur tidak ditambah

Tiga set fitur diuji, dan hasilnya berlawanan arah antara validasi dan
pengujian:

| Set fitur | CV acak | Validasi waktu | **Uji ROC-AUC** |
|---|---|---|---|
| 7 fitur inti | 0,726 | 0,623 | **0,836** |
| 12 fitur | 0,740 | 0,695 | 0,818 |
| 23 fitur | 0,816 | 0,804 | 0,773 |

*(angka dari eksperimen pada populasi versi pertama; polanya yang penting)*

Set 23 fitur terlihat **paling meyakinkan saat divalidasi** dan **paling buruk
saat diuji**. Sebabnya sampel: hanya 25 kejadian scrap di data latih. Aturan
lazim "minimal 10 kejadian per variabel" hanya membenarkan segelintir fitur.

Atribut garansi dari inventory juga diuji dan **ditolak**: 100% PART yang
dibuang sudah lewat garansi, tetapi begitu juga 99,1% yang diperbaiki - tidak
ada daya pisah sama sekali.

## 6. Hasil akhir pada data uji

Ambang ditetapkan dari **data latih** (prediksi out-of-fold), lalu dipakai apa
adanya di data uji.

| Metrik | Nilai |
|---|---|
| ROC-AUC | **0,763** |
| PR-AUC | **0,255** (tebakan acak 0,065 - **naik 3,9x**) |
| Akurasi | 80,5% |
| Balanced accuracy | 65,2% |
| Presisi | 16,1% |
| Recall | 47,6% |

Dari 323 episode kerusakan, model menandai 62 dan menangkap 10 dari 21 yang
benar-benar dibuang.

### Ketidakpastian

Bootstrap 2.000x pada data uji (21 kejadian scrap):

| Model | ROC-AUC | 95% CI |
|---|---|---|
| Gabungan | 0,763 | [0,666 - 0,852] |
| Random Forest | 0,793 | [0,724 - 0,862] |
| Regresi Logistik | 0,725 | [0,602 - 0,833] |

Selisih Random Forest dan Regresi Logistik: +0,069 dengan CI [-0,039, +0,190].
**Model-model ini tidak bisa dibedakan secara statistik pada sampel sebesar
ini.** Angka mana pun di rentang ~0,72-0,79 sama-sama konsisten dengan data.

### Peringatan soal angka "akurasi"

**Menebak "semua bisa diperbaiki" menghasilkan akurasi 93,5%** - jauh di atas
model, tapi menangkap nol PART mati dan sama sekali tidak berguna. Ini jebakan
akurasi pada data tidak seimbang, dan makin parah setelah populasi diperbaiki
(base rate turun dari 21,4% ke 6,5%).

Ukuran yang berarti di sini adalah **ROC-AUC 0,763** dan **lift PR-AUC 3,9x**.
Akurasi 80,5% memang di atas 70%, tetapi bukan angka yang layak jadi patokan.

### Titik kerja alternatif

| Ambang | Akurasi | Balanced acc | Presisi | Recall | Ditandai |
|---|---|---|---|---|---|
| 0,40 | 49,5% | 68,6% | 10,6% | **90,5%** | 180 |
| **0,52** | **80,5%** | **65,2%** | **16,1%** | **47,6%** | **62** |
| 0,60 | 87,0% | 64,2% | 21,6% | 38,1% | 37 |
| 0,65 | 91,6% | 66,7% | **36,4%** | 38,1% | 22 |

Kalau tujuannya **tidak melewatkan PART mati**, ambang 0,40 menangkap 90,5%
tetapi menandai 180 dari 323 episode. Kalau tujuannya **daftar pendek yang
akurat**, ambang 0,65 memberi presisi 36,4% (5,6x base rate) dengan hanya 22
kandidat. Pilihan ini keputusan operasional, bukan keputusan model.

## 7. Keterbatasan

1. **Sampel sangat kecil.** 46 kejadian scrap, 21 di antaranya di data uji.
   Semua metrik punya rentang ketidakpastian lebar (lihat Bagian 6). Model ini
   layak sebagai alat bantu prioritas, **belum layak jadi keputusan otomatis**.

2. **Episode tanpa vonis dan tidak pernah dipasang lagi tetap tidak terpakai.**
   Perluasan label sudah menyelamatkan 861 episode, tetapi masih ada ~748 yang
   nasibnya benar-benar tidak diketahui. Kalau sebagian besar dari mereka
   ternyata dibuang tanpa dicatat, base rate sebenarnya lebih tinggi daripada
   3,3% dan model ini melihat gambaran yang terlalu optimis.

3. **Base rate masih naik perlahan** (1,0% -> 6,2% -> 10,5%). Selama tren ini
   berjalan, **tampilkan peringkat atau kelompok risiko, jangan angka
   persentase** - probabilitas absolutnya belum bisa dipercaya.

4. **Jenis PART bisa berubah perilaku.** MOTOR punya rate scrap 1,5% di periode
   latih dan 21,7% di periode uji. Kekuatan model datang dari fitur umur yang
   lebih stabil, bukan dari jenis PART.

## 8. Saran langkah berikutnya

Diurutkan dari yang dampaknya paling besar:

1. **Perbaiki kelengkapan vonis bengkel.** Ini pengungkit terbesar, dan bukan
   pekerjaan model. Kalau setiap kerusakan punya vonis tercatat, keterbatasan
   nomor 2 hilang dan jumlah kejadian yang bisa dipelajari naik drastis.
2. **Kumpulkan data lebih dulu.** Dengan ~15 kejadian scrap per kuartal,
   setahun lagi jumlahnya kira-kira dua kali lipat. Itu jauh lebih berharga
   daripada mengutak-atik algoritma pada sampel sekarang.
3. **Kalibrasi ulang sebelum menampilkan persentase.**
4. **Jangan tambah fitur dulu.** Bagian 5 sudah menunjukkan menambah fitur pada
   sampel sekecil ini menurunkan performa sesungguhnya.
