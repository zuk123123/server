#!/usr/bin/env bash
set -euo pipefail

# Подхват .env, если есть
if [[ -f ".env" ]]; then
  set -o allexport
  source .env
  set +o allexport
fi

HOST="${POS2_BIND:-0.0.0.0}"
PORT="${POS2_PORT:-8080}"

# >>> ВАЖНО: укажи корневую БД с данными <<<
export POS2_DB_PATH="${POS2_DB_PATH:-$(pwd)/db.sqlite}"

APP_MODULE="app.server:app"

echo "[run] DB_PATH=$POS2_DB_PATH"
echo "[run] Starting without TLS (Cloudflare даёт TLS снаружи)"

# SQLite + запись = 1 воркер, иначе будут «database is locked»
exec uvicorn "$APP_MODULE" \
  --host "$HOST" --port "$PORT" \
  --workers 1

