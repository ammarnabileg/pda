import os
import secrets
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _load_env_file():
    """Read server/.env (KEY=VALUE lines) into the environment if present."""
    path = BASE_DIR / ".env"
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


_load_env_file()

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql+psycopg://postgres:postgres@localhost:5432/tamween"
)
SECRET_KEY = os.environ.get("SECRET_KEY") or ""
if not SECRET_KEY:
    # Sessions reset on restart without a fixed key; run.py writes one to .env on first start.
    SECRET_KEY = secrets.token_urlsafe(32)
PORT = int(os.environ.get("PORT", "9001"))
HOST = os.environ.get("HOST", "0.0.0.0")
PAIRING_MINUTES = 30
# Invoice photos and scans. Kept next to the database, and copied by scripts/backup.py.
FILES_DIR = os.environ.get("FILES_DIR") or (
    os.path.join(os.environ.get("ProgramData", "C:\\ProgramData"), "Tamween", "Files") if os.name == "nt"
    else str(BASE_DIR / "files"))
MAX_UPLOAD_MB = 10
# Shown at the top of printed statements. Set COOP_NAME in server/.env.
COOP_NAME = os.environ.get("COOP_NAME") or "الجمعية التعاونية"
# Where setup.ps1 puts the daily backups (and backup.log).
BACKUP_DIR = os.environ.get("BACKUP_DIR") or (
    os.path.join(os.environ.get("ProgramData", "C:\\ProgramData"), "Tamween", "Backups") if os.name == "nt"
    else str(BASE_DIR / "backups"))
