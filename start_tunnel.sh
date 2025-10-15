#!/usr/bin/env bash
set -euo pipefail

WORKDIR="$HOME/Рабочий стол/server"
CF_LOG="$WORKDIR/cf.log"
CF_PID="$WORKDIR/cloudflared.pid"
CF_URL="$WORKDIR/cf_url.txt"
TIMEOUT_SEC=40
SLEEP_INTERVAL=1

cd "$WORKDIR"
echo "[start] working dir: $WORKDIR"

# стоп старые
pkill -f "cloudflared tunnel" 2>/dev/null || true
rm -f "$CF_PID" "$CF_LOG" "$CF_URL" || true

# стартуем cloudflared к локальному HTTP
echo "[start] launching cloudflared..."
nohup cloudflared tunnel \
  --url http://127.0.0.1:8080 \
  --edge-ip-version 4 \
  --protocol http2 \
  --no-autoupdate \
  --loglevel info \
  --logfile "$CF_LOG" \
  > /dev/null 2>&1 &
echo $! > "$CF_PID"
echo "[start] cloudflared pid: $(cat "$CF_PID")"

# ждём ссылку
echo -n "[wait] looking for trycloudflare URL"
elapsed=0
URL=""
while [[ $elapsed -lt $TIMEOUT_SEC ]]; do
  URL="$(grep -m1 -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CF_LOG" || true)"
  if [[ -n "$URL" ]]; then
    echo " ✅"
    echo "$URL" | tee "$CF_URL"
    break
  fi
  printf '.'
  sleep "$SLEEP_INTERVAL"
  elapsed=$((elapsed + SLEEP_INTERVAL))
done
if [[ -z "$URL" ]]; then
  echo " ❌"
  echo "[err] URL не найден. tail cf.log:"
  tail -n 200 "$CF_LOG" || true
  exit 1
fi

HOST="${URL#https://}"
echo "[info] HOST=$HOST"

# быстрая проверка DNS
echo "[dns] dig +short $HOST:"
dig +short "$HOST" || true

echo "[check] curl -vk $URL/ping (обычный DNS)"
if ! curl -vk --max-time 8 "$URL/ping"; then
  echo "[warn] обычный DNS не сработал, пробую через edge IP…"

  # вытащим IP — поддерживаем два формата лога:
  # 1) JSON: ..."ip":"198.41.200.193"...
  # 2) Текст: ... ip=198.41.200.193 ...
  IP="$(grep -m1 -Eo '"ip":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' "$CF_LOG" \
        | head -n1 | sed -E 's/.*"ip":"([0-9.]+)".*/\1/')" || true
  if [[ -z "${IP:-}" ]]; then
    IP="$(grep -m1 -Eo 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$CF_LOG" \
          | head -n1 | cut -d= -f2)" || true
  fi

  if [[ -n "${IP:-}" ]]; then
    echo "[fallback] IP=$IP ; curl --resolve $HOST:443:$IP https://$HOST/ping"
    curl -vk --max-time 8 --resolve "$HOST:443:$IP" "https://$HOST/ping" || true
  else
    echo "[fallback] edge IP не найден в $CF_LOG. tail:"
    tail -n 120 "$CF_LOG" || true
  fi
fi

echo "[done] URL saved to $CF_URL ; pid in $CF_PID"
echo "Stop: kill \$(cat \"$CF_PID\") && rm -f \"$CF_PID\""
