#!/usr/bin/env bash
# Starts the server on a scratch database, loads demo data and runs the app's
# end-to-end sync test against it. Needs a local PostgreSQL (postgres/postgres).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
DB=tamween_e2e
export DATABASE_URL="postgresql+psycopg://postgres:postgres@localhost:5432/$DB"
export SECRET_KEY=e2e PORT=9011
PGPASSWORD=postgres psql -h localhost -U postgres -qc "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
cd "$ROOT/server"
"$PY" scripts/demo_data.py --pairing-code 424242 >/dev/null
"$PY" -m uvicorn app.main:app --host 127.0.0.1 --port 9011 --log-level warning &
PID=$!
trap 'kill $PID' EXIT
for _ in $(seq 30); do curl -sf http://127.0.0.1:9011/api/v1/ping >/dev/null && break; sleep 0.5; done
cd "$ROOT/app"
TAMWEEN_SERVER=127.0.0.1:9011 TAMWEEN_CODE=424242 flutter test test/server_sync_test.dart
