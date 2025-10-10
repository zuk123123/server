#!/usr/bin/env bash
set -euo pipefail

# Загружаем .env если есть
if [[ -f ".env" ]]; then
  set -o allexport
  source .env
  set +o allexport
fi

HOST="${POS2_BIND:-0.0.0.0}"
PORT="${POS2_PORT:-8080}"
WORKERS="${POS2_WORKERS:-2}"

CERT="${POS2_TLS_CRT:-$(dirname "$0")/server.crt}"
KEY="${POS2_TLS_KEY:-$(dirname "$0")/server.key}"

APP_MODULE="app.server:app"

if [[ -f "$CERT" && -f "$KEY" ]]; then
  echo "[run] Starting with TLS: $CERT"
  exec uvicorn "$APP_MODULE" \
    --host "$HOST" --port "$PORT" \
    --workers "$WORKERS" \
    --ssl-keyfile "$KEY" --ssl-certfile "$CERT" \
    --http h11
else
  echo "[run] Starting without TLS"
  exec uvicorn "$APP_MODULE" \
    --host "$HOST" --port "$PORT" \
    --workers "$WORKERS"
fi
