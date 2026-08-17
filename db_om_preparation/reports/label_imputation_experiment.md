# Eksperimen: menyelamatkan data yang dibuang lewat imputasi label

Dua gagasan diuji untuk menambah data latih tanpa menunggu data baru.
Implementasi: `src/experiment_label_imputation.py`

**Tidak ada model, view, notebook, atau script lama yang diubah.** Eksperimen
ini hanya membaca schema `analytics` dan melaporkan hasil.

## Aturan yang dipegang agar tetap jujur

| Aturan | Alasan |
|---|---|
| Label tebakan **hanya untuk melatih** | Pengujian tetap memakai label terverifikasi. Kalau tidak, kita cuma menguji model terhadap tebakan sendiri. |
| Median umur dihitung **hanya dari periode latih** | Supaya tidak mengintip masa depan. |
| Split waktu, embargo, definisi target **tidak diubah** | Perbandingan terhadap model resmi harus adil. |

---

## Ide 1 — RECON sebagai penanda akhir hidup PART: **DITOLAK**

Aturan resmi menolak sebuah siklus menjadi contoh "tidak rusak" kalau ada
RECON muncul setelah PART terakhir terlihat aktif. Konsekuensinya besar:
**952.217 observasi dibuang** (data layak turun dari 1,32 juta ke 356 ribu).

Yang diuji: tanggal RECON dipakai sebagai perkiraan kapan PART berhenti
dipakai, dan waktu menuju kerusakan diisi dari median umur-sampai-rusak tipe
PART tersebut (716 hari keseluruhan, dihitung per tipe untuk 45 tipe PART).

| Konfigurasi | Baris latih | Rusak | ROC uji | PR uji | Lift |
|---|---|---|---|---|---|
| Resmi (terverifikasi saja) | 251.568 | 3.852 | **0,769** | **0,135** | **5,74** |
| + RECON diimputasi | 1.009.744 | 5.003 | 0,695 | 0,117 | 4,99 |

**Menambah data 4x lipat justru menurunkan performa.** Sebabnya terlihat dari
angkanya sendiri: dari 952.217 observasi yang diselamatkan, hanya **1.151**
yang menjadi contoh "rusak" hasil imputasi. Artinya kita menambahkan sekitar
951 ribu contoh "tidak rusak" yang statusnya sebenarnya tidak diketahui —
persis kontaminasi yang ingin dibuang oleh aturan RECON sejak awal.

**Kesimpulan: aturan research yang lama sudah benar. Jangan diubah.**

---

## Ide 2 — kerusakan tanpa kelanjutan dianggap dibuang: **BERHASIL, dengan catatan penting**

743 kerusakan tidak punya vonis bengkel **dan** PART-nya tidak pernah dipasang
lagi. Sekarang dibuang dari pemodelan. Yang diuji: anggap saja PART itu memang
tidak pernah kembali.

| Konfigurasi | Baris latih | Dibuang | ROC uji | PR uji | Lift |
|---|---|---|---|---|---|
| Resmi (buang yang tanpa kelanjutan) | 1.084 | 25 | 0,720 | 0,200 | 3,07 |
| Menggantung >0 hari -> dibuang | 1.480 | 421 | 0,828 | 0,322 | 4,96 |
| Menggantung >180 hari -> dibuang | 1.420 | 361 | 0,829 | 0,331 | 5,10 |
| **Menggantung >270 hari -> dibuang** | 1.274 | 215 | **0,835** | **0,393** | **6,04** |

Lift naik dari 3,07 ke **6,04**, dan makin ketat syaratnya makin baik — pola
dosis-respons yang diharapkan kalau asumsinya memang mengandung kebenaran.

### Uji kontrol

Apakah perbaikan itu karena tebakannya tepat, atau sekadar karena contoh
positif bertambah? Empat varian dengan jumlah baris sama:

| Varian | Dibuang | ROC uji | Lift |
|---|---|---|---|
| **Asli** — menggantung >270 hari -> dibuang | 215 | **0,835** | **6,04** |
| **Kebalikan** — menggantung >270 hari -> diperbaiki | 25 | 0,629 | 2,45 |
| **Acak** — dipilih acak, jumlah sama | 215 | 0,828 | 5,75 |

Dua hal terbaca:

1. **Arah asumsinya penting.** Melabeli kerusakan tanpa kelanjutan sebagai
   "diperbaiki" justru merusak (2,45, di bawah baseline 3,07). Jadi baris-baris
   itu memang berperilaku seperti contoh "dibuang", bukan sekadar tambahan data.
2. **Ambang 270 hari bukan penyebabnya.** Memilih acak memberi hasil hampir
   sama (5,75 vs 6,04). Wajar: di periode latih semua kerusakan tanpa
   kelanjutan sudah menggantung minimal 126 hari (median 263), jadi "acak" dan
   ">270 hari" beririsan besar.

### Bukti tak langsung dari data terverifikasi

Pada kerusakan yang vonisnya **sudah diketahui**, lama tidak dipasang ulang
memang pertanda kuat:

| Jeda tanpa dipasang ulang | Jumlah | Berakhir dibuang |
|---|---|---|
| 0-30 hari | 678 | 0,1% |
| 30-90 hari | 178 | 0,6% |
| 90-180 hari | 98 | 2,0% |
| 180-270 hari | 48 | 8,3% |
| >270 hari | 82 | **20,7%** |

Gradiennya 200 kali lipat. Heuristiknya sahih.

### Ketidakpastian

Bootstrap 2.000x pada data uji (21 kejadian terverifikasi):

- Selisih PR-AUC: **+0,1815**, 95% CI **[-0,010, +0,365]**
- Peluang imputasi benar-benar lebih baik: **97%**

Rentangnya masih menyentuh nol. Perbaikannya kemungkinan besar nyata, tetapi
belum bisa disebut pasti.

Secara operasional, pada K = 9 (kapasitas 3/bulan): baseline menangkap **2 dari
21**, versi imputasi **3 dari 21**. Tambahan satu tangkapan.

---

## Catatan yang paling penting: ini trik pelatihan, bukan penemuan

Tabel bukti tak langsung di atas menunjukkan bahwa di antara kerusakan yang
vonisnya diketahui dan menggantung >270 hari, **hanya 20,7% yang benar-benar
dibuang**. Artinya melabeli 100% kerusakan tanpa kelanjutan sebagai "dibuang"
hampir pasti **salah untuk sebagian besar baris satu per satu**.

Tetapi peringkat model tetap membaik. Penjelasan yang paling masuk akal:
label-label itu, walaupun banyak yang keliru secara individual, mendorong model
ke arah profil yang benar — "tua, tidak pernah kembali". Yang bekerja adalah
kecenderungannya, bukan kebenaran tiap barisnya.

Karena itu hasil ini **tidak boleh dilaporkan sebagai "ditemukan 190 kerusakan
fatal tersembunyi"**. Yang benar: sebuah prior yang berguna untuk melatih.

## Rekomendasi

| Gagasan | Rekomendasi |
|---|---|
| Ide 1 (RECON) | **Tolak.** Aturan research yang ada sudah benar dan terbukti lebih baik. |
| Ide 2 (tanpa kelanjutan) | **Simpan sebagai temuan research; belum untuk production.** |

Alasan Ide 2 belum dinaikkan ke production:

1. Rentang keyakinannya masih menyentuh nol (CI [-0,010, +0,365]).
2. Labelnya sebagian besar salah secara individual — model jadi bergantung pada
   asumsi yang tidak bisa diverifikasi dan bisa bergeser kalau kebiasaan
   pencatatan berubah.
3. Keuntungan operasionalnya masih kecil: 2 -> 3 tangkapan dari 21.

Kalau nanti kelengkapan pencatatan vonis membaik, eksperimen ini sebaiknya
diulang: bandingkan label imputasi dengan vonis sungguhan pada episode yang
kemudian terselesaikan. Itu akan langsung mengukur seberapa sering asumsinya
benar — sesuatu yang sekarang belum bisa dilakukan.
