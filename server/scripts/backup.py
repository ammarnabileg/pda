#!/usr/bin/env python3
"""Database backup with verification. Keeps the newest 30 files.

    python scripts/backup.py                    # writes to server/backups/
    python scripts/backup.py --dir D:\\backup     # another folder (USB drive, synced folder)
    python scripts/backup.py --restore-test      # also restore into a scratch database and compare

Every run appends to backup.log in the backup folder and exits non-zero on any failure,
so Windows Task Scheduler shows the run as failed instead of silently "succeeding".
A backup that cannot be read back by pg_restore is deleted and counts as a failure.
"""
import argparse
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import config  # noqa: E402

TABLES = ["products", "sales", "sale_lines", "employees", "receipts", "count_sessions", "stock_moves",
          "supplier_payments", "receipt_files"]


class BackupError(Exception):
    pass


def tool(name):
    exe = shutil.which(name)
    if not exe:
        raise BackupError(f"{name} not found. Add PostgreSQL's bin folder to PATH.")
    return exe


def conn_parts(url):
    u = urlsplit(url.replace("postgresql+psycopg://", "postgresql://"))
    return {"host": u.hostname or "localhost", "port": str(u.port or 5432), "user": unquote(u.username or ""),
            "password": unquote(u.password or ""), "db": u.path.lstrip("/")}


def run(cmd, env):
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise BackupError(f"{Path(cmd[0]).name} failed: {(r.stderr or r.stdout).strip()[:500]}")
    return r.stdout


def counts(c, env, db):
    sql = " UNION ALL ".join(f"SELECT '{t}', count(*) FROM {t}" for t in TABLES)
    out = run([tool("psql"), "-h", c["host"], "-p", c["port"], "-U", c["user"], "-d", db, "-tAF", "|", "-c", sql], env)
    return dict(line.split("|") for line in out.split())


def restore_test(dump, c, env, admin_env, admin_user):
    """Restore the dump into a scratch database and compare row counts with the live one."""
    scratch = "tamween_restore_check"
    psql = tool("psql")
    base = [psql, "-h", c["host"], "-p", c["port"], "-U", admin_user, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c"]
    run(base + [f"DROP DATABASE IF EXISTS {scratch}"], admin_env)
    run(base + [f"CREATE DATABASE {scratch} TEMPLATE template0"], admin_env)
    try:
        run([tool("pg_restore"), "-h", c["host"], "-p", c["port"], "-U", admin_user, "-d", scratch,
             "--no-owner", "--exit-on-error", str(dump)], admin_env)
        live, restored = counts(c, env, c["db"]), counts({**c, "user": admin_user}, admin_env, scratch)
        if live != restored:
            raise BackupError(f"restored data differs: live={live} restored={restored}")
        return restored
    finally:
        subprocess.run(base + [f"DROP DATABASE IF EXISTS {scratch}"], env=admin_env, capture_output=True)


def copy_files(src: Path, dst: Path):
    """Invoice photos are not in the database. They are never changed or deleted, so a mirror is enough:
    copy what is new, then check every file is there with the same size."""
    if not src.exists():
        return 0, 0
    copied = total = 0
    for f in src.rglob("*"):
        if not f.is_file():
            continue
        total += 1
        target = dst / f.relative_to(src)
        if not target.exists() or target.stat().st_size != f.stat().st_size:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, target)
            copied += 1
        if target.stat().st_size != f.stat().st_size:
            raise BackupError(f"copy of {f} is incomplete")
    return copied, total


def admin_login(c):
    """A login that may create the scratch database: env, then setup's saved superuser, then the app user."""
    if os.environ.get("PG_ADMIN_USER"):
        return os.environ["PG_ADMIN_USER"], os.environ.get("PG_ADMIN_PASSWORD", "")
    saved = config.BASE_DIR / ".secrets" / "pg-superuser.txt"
    if saved.exists():
        user, _, pw = saved.read_text(encoding="ascii").partition("\n")
        return user.strip(), pw.strip()
    return c["user"], c["password"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(config.BASE_DIR / "backups"))
    ap.add_argument("--keep", type=int, default=30)
    ap.add_argument("--restore-test", action="store_true",
                    help="restore into a scratch database (needs PG_ADMIN_USER / PG_ADMIN_PASSWORD or a user that can create databases)")
    args = ap.parse_args()

    out_dir = Path(args.dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    log = out_dir / "backup.log"
    stamp = datetime.now()

    def write_log(msg):
        with log.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}\n")

    c = conn_parts(config.DATABASE_URL)
    env = {**os.environ, "PGPASSWORD": c["password"]}
    out = out_dir / f"tamween-{stamp:%Y%m%d-%H%M%S}.dump"
    try:
        run([tool("pg_dump"), "-h", c["host"], "-p", c["port"], "-U", c["user"], "--no-owner",
             "--format=custom", "--file", str(out), c["db"]], env)
        if not out.exists() or out.stat().st_size < 1024:
            raise BackupError("the backup file is missing or empty")
        # Reading the table of contents proves the file is a complete, valid archive.
        toc = run([tool("pg_restore"), "--list", str(out)], env)
        missing = [t for t in TABLES if f"TABLE DATA public {t} " not in toc]
        if missing:
            raise BackupError(f"backup has no data section for: {', '.join(missing)}")
        detail = f"{out.stat().st_size // 1024} KB"
        new, total = copy_files(Path(config.FILES_DIR), out_dir / "files")
        detail += f", invoice files {total} ({new} new)"
        if args.restore_test:
            admin_user, admin_pw = admin_login(c)
            admin_env = {**os.environ, "PGPASSWORD": admin_pw}
            rows = restore_test(out, c, env, admin_env, admin_user)
            detail += ", restore test OK (" + ", ".join(f"{k} {v}" for k, v in rows.items()) + ")"
    except BackupError as e:
        if out.exists():
            out.unlink()
        write_log(f"FAILED  {e}")
        print(f"BACKUP FAILED: {e}", file=sys.stderr)
        sys.exit(1)

    for old in sorted(out_dir.glob("tamween-*.dump"))[:-args.keep]:
        old.unlink()
    write_log(f"OK      {out.name}  {detail}")
    print(f"Backup OK: {out} ({detail})")


if __name__ == "__main__":
    main()
