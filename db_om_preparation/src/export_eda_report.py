"""Eksekusi notebook EDA dan ekspor hasilnya menjadi HTML."""

from __future__ import annotations

import subprocess
import sys

from database import PROJECT_DIR


def main() -> int:
    notebook = PROJECT_DIR / "notebooks" / "01_failure_eda.ipynb"
    output_dir = PROJECT_DIR / "reports"
    output_dir.mkdir(exist_ok=True)
    command = [
        sys.executable, "-m", "jupyter", "nbconvert", "--to", "html",
        "--execute", str(notebook), "--output", "failure_eda.html",
        "--output-dir", str(output_dir),
        "--ExecutePreprocessor.timeout=600",
    ]
    result = subprocess.run(command, cwd=PROJECT_DIR, check=False)
    if result.returncode:
        print("[ERROR] Notebook EDA gagal dieksekusi.", file=sys.stderr)
        return result.returncode
    print(f"[OK] Laporan EDA: {output_dir / 'failure_eda.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
