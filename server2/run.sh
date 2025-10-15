#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# venv
if [[ ! -d ".venv" ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
python -m pip install --upgrade pip >/dev/null
python -m pip install -r requirements.txt

# init DB if missing
if [[ ! -f "app/db.sqlite" ]]; then
  echo "[run] initializing DB from sql_init.sql"
  sqlite3 app/db.sqlite < sql_init.sql
fi

export POS2_DB_PATH="$(pwd)/app/db.sqlite"
exec python3 -m uvicorn app.server:app --host 0.0.0.0 --port 8080
