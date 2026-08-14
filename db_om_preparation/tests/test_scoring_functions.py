"""Test untuk fungsi perhitungan murni di src/score_*.py.

Sengaja HANYA menguji fungsi yang tidak butuh koneksi database atau file
model (cumulative_failure_at, project_step, reliability_tier,
failure_window) - fungsi-fungsi inilah yang paling gampang diam-diam salah
kalau ada yang mengubahnya, karena tidak ada error yang muncul saat
dijalankan; hasilnya cuma jadi angka yang salah.

Tidak menguji main()/query()/load_active_snapshots() di modul manapun -
itu butuh database sungguhan, di luar cakupan test unit.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from score_final_risk_report import (  # noqa: E402
    cumulative_failure_at,
    failure_window,
    project_step as project_step_final,
    reliability_tier,
)
from score_multi_horizon_risk import project_step as project_step_multi  # noqa: E402


# ------------------------------------------------------------------
# cumulative_failure_at - kunci dari discrete-time hazard chaining
# ------------------------------------------------------------------

class TestCumulativeFailureAt:
    def test_hazard_nol_selalu_nol(self):
        hazard = np.zeros(6)
        for day in [0, 7, 14, 30, 90, 180]:
            assert cumulative_failure_at(hazard, day) == pytest.approx(0.0)

    def test_hari_nol_selalu_nol(self):
        # hazard tinggi tapi day=0 harus tetap 0 - belum ada waktu berjalan
        hazard = np.full(6, 0.9)
        assert cumulative_failure_at(hazard, 0) == pytest.approx(0.0)

    def test_kelipatan_30_cocok_dengan_cumprod_manual(self):
        hazard = np.array([0.1, 0.2, 0.05, 0.3, 0.15, 0.25])
        for k in range(1, 7):
            expected = 1 - np.prod(1 - hazard[:k])
            assert cumulative_failure_at(hazard, 30 * k) == pytest.approx(expected)

    def test_interpolasi_setengah_langkah(self):
        # hazard konstan 0.5 di langkah pertama: separuh jalan (15 hari)
        # harus interpolasi sebagai (1-0.5)**0.5, bukan diprorata linear.
        hazard = np.array([0.5, 0.0, 0.0, 0.0, 0.0, 0.0])
        expected = 1 - (1 - 0.5) ** 0.5
        assert cumulative_failure_at(hazard, 15) == pytest.approx(expected)

    def test_interpolasi_pada_langkah_kedua(self):
        hazard = np.array([0.2, 0.5, 0.0, 0.0, 0.0, 0.0])
        # 45 hari = 1 langkah penuh (30) + setengah langkah kedua (15/30)
        survival_full = 1 - 0.2
        survival_partial = (1 - 0.5) ** 0.5
        expected = 1 - survival_full * survival_partial
        assert cumulative_failure_at(hazard, 45) == pytest.approx(expected)

    def test_monoton_naik_terhadap_hari(self):
        rng = np.random.default_rng(0)
        for _ in range(20):
            hazard = rng.uniform(0, 0.4, size=6)
            days = [7, 14, 30, 60, 90, 120, 150, 180]
            values = [cumulative_failure_at(hazard, d) for d in days]
            assert all(a <= b + 1e-12 for a, b in zip(values, values[1:])), (
                f"tidak monoton untuk hazard={hazard}, nilai={values}"
            )

    def test_hasil_selalu_dalam_rentang_valid(self):
        rng = np.random.default_rng(1)
        for _ in range(20):
            hazard = rng.uniform(0, 1, size=6)
            for day in [7, 14, 30, 90, 180]:
                v = cumulative_failure_at(hazard, day)
                assert 0.0 <= v <= 1.0 + 1e-9

    def test_melebihi_jumlah_langkah_yang_tersedia(self):
        # day > 180 dengan hazard cuma 6 langkah - full_steps akan >= len(hazard),
        # jadi remainder tidak boleh diinterpolasi lagi (indeks di luar array).
        hazard = np.full(6, 0.1)
        expected = 1 - np.prod(1 - hazard)
        assert cumulative_failure_at(hazard, 210) == pytest.approx(expected)


# ------------------------------------------------------------------
# project_step - "memutar maju" fitur untuk hazard chaining
# ------------------------------------------------------------------

def _base_frame() -> pd.DataFrame:
    return pd.DataFrame({
        "_raw_days_since_installation": [0.0, 85.0, 400.0],
        "_eff_days_since_last_corrective": [10.0, 5.0, 0.0],
        "observation_on": pd.to_datetime(["2026-01-15", "2026-11-20", "2026-06-01"]),
        "log_days_since_installation": [0.0, 0.0, 0.0],
        "installation_age_band": ["x", "x", "x"],
        "log_days_since_last_corrective": [0.0, 0.0, 0.0],
        "month_sin": [0.0, 0.0, 0.0],
        "month_cos": [0.0, 0.0, 0.0],
    })


class TestProjectStep:
    def test_k0_umur_tidak_berubah(self):
        base = _base_frame()
        proj = project_step_final(base, 0)
        expected_age = np.log1p(base["_raw_days_since_installation"])
        pd.testing.assert_series_equal(
            proj["log_days_since_installation"], expected_age,
            check_names=False,
        )

    def test_umur_maju_30_hari_per_langkah(self):
        base = _base_frame()
        p0 = project_step_final(base, 0)
        p2 = project_step_final(base, 2)
        raw0 = np.expm1(p0["log_days_since_installation"])
        raw2 = np.expm1(p2["log_days_since_installation"])
        assert (raw2 - raw0).round(6).tolist() == pytest.approx([60.0, 60.0, 60.0])

    def test_age_band_pindah_kategori_saat_lewat_ambang(self):
        # baris ke-2: umur 85 hari (masih '000_090_DAYS'), k=1 -> 115 hari
        # (masuk '091_180_DAYS'). Perbaikan kategori harus ikut terjadi,
        # bukan cuma angka umurnya.
        base = _base_frame()
        p0 = project_step_final(base, 0)
        p1 = project_step_final(base, 1)
        assert p0["installation_age_band"].iloc[1] == "000_090_DAYS"
        assert p1["installation_age_band"].iloc[1] == "091_180_DAYS"

    def test_bulan_wrap_desember_ke_januari(self):
        base = pd.DataFrame({
            "_raw_days_since_installation": [0.0],
            "_eff_days_since_last_corrective": [0.0],
            "observation_on": pd.to_datetime(["2026-12-20"]),
            "log_days_since_installation": [0.0],
            "installation_age_band": ["x"],
            "log_days_since_last_corrective": [0.0],
            "month_sin": [0.0],
            "month_cos": [0.0],
        })
        # +30 hari dari 20 Des 2026 = 19 Jan 2027
        proj = project_step_final(base, 1)
        future_month = 1
        expected_sin = np.sin(2.0 * np.pi * (future_month - 1) / 12.0)
        expected_cos = np.cos(2.0 * np.pi * (future_month - 1) / 12.0)
        assert proj["month_sin"].iloc[0] == pytest.approx(expected_sin)
        assert proj["month_cos"].iloc[0] == pytest.approx(expected_cos)

    def test_umur_tidak_pernah_negatif(self):
        base = pd.DataFrame({
            "_raw_days_since_installation": [-5.0],  # data kotor hipotetis
            "_eff_days_since_last_corrective": [-5.0],
            "observation_on": pd.to_datetime(["2026-01-01"]),
            "log_days_since_installation": [0.0],
            "installation_age_band": ["x"],
            "log_days_since_last_corrective": [0.0],
            "month_sin": [0.0],
            "month_cos": [0.0],
        })
        proj = project_step_final(base, 0)
        assert proj["log_days_since_installation"].iloc[0] == pytest.approx(0.0)

    def test_dua_salinan_fungsi_identik(self):
        """score_final_risk_report.py dan score_multi_horizon_risk.py punya
        salinan project_step yang SAMA PERSIS (bukan dipanggil dari satu
        sumber). Kalau salah satu diedit tanpa yang lain, test ini gagal -
        itu tandanya, bukan cuma dugaan dari membaca kode."""
        base = _base_frame()
        for k in range(3):
            a = project_step_final(base, k)
            b = project_step_multi(base, k)
            pd.testing.assert_frame_equal(a, b)


# ------------------------------------------------------------------
# reliability_tier - proxy dukungan historis
# ------------------------------------------------------------------

class TestReliabilityTier:
    def test_ambang_tinggi_sedang_rendah(self):
        support = pd.Series([5000, 4999, 300, 299, 0])
        category = pd.Series(["A"] * 5)
        result = list(reliability_tier(support, category))
        assert result == ["Tinggi", "Sedang", "Sedang", "Rendah", "Rendah"]

    def test_unknown_selalu_rendah_walau_dukungan_besar(self):
        support = pd.Series([999999])
        category = pd.Series(["UNKNOWN"])
        result = list(reliability_tier(support, category))
        assert result == ["Rendah"]

    def test_urutan_kategori_ordered(self):
        support = pd.Series([1])
        category = pd.Series(["A"])
        result = reliability_tier(support, category)
        assert list(result.categories) == ["Tinggi", "Sedang", "Rendah"]
        assert result.ordered


# ------------------------------------------------------------------
# failure_window - jendela waktu kegagalan yang dilaporkan ke user
# ------------------------------------------------------------------

class TestFailureWindow:
    def test_kelompok_rendah_selalu_pesan_tetap(self):
        hazard = np.full(6, 0.9)  # hazard tinggi pun harus diabaikan
        assert failure_window(hazard, "Rendah") == (
            "Risiko rendah - jendela waktu belum bisa diperkirakan"
        )

    def test_total_risiko_kecil_pesan_tidak_bisa_diperkirakan(self):
        hazard = np.full(6, 0.001)  # total risiko 180 hari << 5%
        result = failure_window(hazard, "Sedang")
        assert "terlalu kecil" in result

    def test_hazard_konstan_pertengahan_pertama(self):
        # hazard 0.5 di langkah pertama, nol setelahnya: seluruh massa
        # kegagalan jatuh di langkah 1 (hari 1-30).
        hazard = np.array([0.5, 0.0, 0.0, 0.0, 0.0, 0.0])
        result = failure_window(hazard, "Tinggi")
        assert result == "1-30 hari"

    def test_format_selalu_rentang_hari(self):
        hazard = np.array([0.05, 0.1, 0.15, 0.2, 0.1, 0.05])
        result = failure_window(hazard, "Tinggi")
        assert result.endswith(" hari")
        lo, hi = result.replace(" hari", "").split("-")
        assert int(lo) <= int(hi)

    def test_kelompok_sedang_dan_tinggi_pakai_logika_sama(self):
        hazard = np.array([0.1, 0.1, 0.1, 0.1, 0.1, 0.1])
        assert failure_window(hazard, "Sedang") == failure_window(hazard, "Tinggi")
