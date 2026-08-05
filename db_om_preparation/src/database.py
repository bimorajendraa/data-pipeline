"""Koneksi PostgreSQL kecil untuk pipeline cleaning database OMEXP."""

from __future__ import annotations

import os
from pathlib import Path

import psycopg
from dotenv import load_dotenv


PROJECT_DIR = Path(__file__).resolve().parents[1]


def load_environment() -> None:
    load_dotenv(PROJECT_DIR / ".env")


def connect() -> psycopg.Connection:
    load_environment()
    required = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
    missing = [name for name in required if not os.getenv(name)]
    if missing:
        raise RuntimeError(
            "Konfigurasi database belum lengkap: " + ", ".join(missing)
            + ". Salin .env.example menjadi .env lalu isi nilainya."
        )

    if os.environ["DB_NAME"].casefold() != "omexp":
        raise RuntimeError("DB_NAME harus OMEXP; pipeline tidak membuat database baru.")

    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode=os.getenv("DB_SSLMODE", "prefer"),
        application_name="db_om_preparation",
        connect_timeout=10,
    )
