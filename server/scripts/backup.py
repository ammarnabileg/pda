#!/usr/bin/env python3
"""Daily database backup. Keeps the newest 30 files.

    python scripts/backup.py                 # writes to server/backups/
    python scripts/backup.py --dir D:\\backup  # another folder (USB drive, synced folder)
"""
import argparse
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import config  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(config.BASE_DIR / "backups"))
    ap.add_argument("--keep", type=int, default=30)
    args = ap.parse_args()
    exe = shutil.which("pg_dump")
    if not exe:
        sys.exit("pg_dump not found. Add PostgreSQL's bin folder to PATH.")
    out_dir = Path(args.dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"tamween-{datetime.now():%Y%m%d-%H%M}.dump"
    url = config.DATABASE_URL.replace("postgresql+psycopg://", "postgresql://")
    subprocess.run([exe, "--no-owner", "--format=custom", "--file", str(out), url], check=True)
    files = sorted(out_dir.glob("tamween-*.dump"))
    for old in files[:-args.keep]:
        old.unlink()
    print(f"Backup written: {out}")


if __name__ == "__main__":
    main()
