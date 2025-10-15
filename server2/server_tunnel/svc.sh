#!/usr/bin/env bash
set -euo pipefail

# ─ paths ─
ROOT="$(cd "$(dirname "$0")/.."; pwd)"
APP_DIR="$ROOT/app"
TUN_DIR="$ROOT/server_tunnel"
VENV="$ROOT/.venv"
UVICORN="$VENV/bin/uvicorn"
PYTHON="$VENV/bin/python"
PIP="$VENV/bin/pip"
CF="/usr/local/bin/cloudflared"

APP_MODULE="app.server:app"
HOST="0.0.0.0"
PORT="8080"

SRV_PID="$TUN_DIR/server.pid"
CF_PID="$TUN_DIR/cloudflared.pid"
CF_LOG="$TUN_DIR/cf.log"
SRV_LOG="$TUN_DIR/server.log"
CF_URL_FILE="$TUN_DIR/cf_url.txt"

CURL="curl -sS"
CURLV="curl -sS -vk --max-time 8"

log(){ printf "%s %s\n" "[$(date '+%H:%M:%S')]" "$*"; }
lan_ip(){ hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -n1 || echo "127.0.0.1"; }
is_alive(){ ps -p "$1" >/dev/null 2>&1; }

get_cf_url(){ [[ -f "$CF_LOG" ]] && grep -m1 -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CF_LOG" || true; }
get_cf_edge_ip(){
  [[ -f "$CF_LOG" ]] || return 1
  local ip
  ip=$(grep -m1 -Eo '"ip":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' "$CF_LOG" | sed -E 's/.*"ip":"([0-9.]+)".*/\1/' || true)
  [[ -n "$ip" ]] || ip=$(grep -m1 -Eo 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$CF_LOG" | cut -d= -f2 || true)
  [[ -n "${ip:-}" ]] && echo "$ip" || true
}
wait_http_ok(){ local base="$1" path="${2:-/ping}" tries=40; for _ in $(seq 1 $tries); do $CURL -f "$base$path" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }

ensure_venv(){
  if [[ ! -x "$PYTHON" ]]; then log "создаю venv: $VENV"; python3 -m venv "$VENV"; fi
  if [[ ! -x "$UVICORN" ]]; then log "ставлю зависимости"; "$PIP" install --upgrade pip >/dev/null; "$PIP" install -r "$ROOT/requirements.txt"; fi
}

# ——— сервер ————————————————————————————————————————————————————————————————
# НЕ убиваем чужой uvicorn: если /ping отвечает — считаем сервер поднят (dev-режим).
start_server_if_needed(){
  if wait_http_ok "http://127.0.0.1:$PORT" "/ping"; then
    log "сервер уже работает на :$PORT — не трогаю (dev-режим, управляет VS Code)"
    return 0
  fi
  ensure_venv
  log "запуск FastAPI на $HOST:$PORT ..."
  pushd "$ROOT" >/dev/null
  nohup env PYTHONPATH="$ROOT" "$UVICORN" "$APP_MODULE" \
    --host "$HOST" --port "$PORT" --app-dir "$ROOT" \
    >"$SRV_LOG" 2>&1 & echo $! > "$SRV_PID"
  popd >/dev/null
  sleep 0.4
  if wait_http_ok "http://127.0.0.1:$PORT" "/ping"; then
    log "сервер ОК: http://127.0.0.1:$PORT/ping"
  else
    log "сервер НЕ отвечает: смотри $SRV_LOG"; exit 1
  fi
}
stop_server(){
  if [[ -f "$SRV_PID" ]]; then
    pid=$(cat "$SRV_PID"||true)
    if [[ -n "${pid:-}" ]] && is_alive "$pid"; then
      log "останов сервера pid=$pid"; kill "$pid"||true; sleep 0.5
    fi
    rm -f "$SRV_PID"
  else
    log "server (управляемый скриптом) не запущен. VS Code сервер я не трогаю."
  fi
}
kill8080(){
  local pids; pids=$(ss -tulnp | awk -v p=":$PORT " '$0~p && /python/ {print $NF}' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
  if [[ -n "${pids:-}" ]]; then log "принудительно убиваю процессы на :$PORT ($pids)"; kill $pids 2>/dev/null || true; sleep 0.8; else log "на :$PORT никого нет"; fi
}

# ——— туннель ————————————————————————————————————————————————————————————————
start_tunnel(){
  command -v "$CF" >/dev/null 2>&1 || { log "cloudflared не найден: $CF"; exit 1; }
  rm -f "$CF_LOG" "$CF_URL_FILE"
  log "запуск cloudflared (origin http://127.0.0.1:$PORT, IPv4+HTTP/2) ..."
  nohup "$CF" tunnel \
    --url "http://127.0.0.1:$PORT" \
    --edge-ip-version 4 \
    --protocol http2 \
    --no-autoupdate \
    --loglevel info \
    --logfile "$CF_LOG" \
    >/dev/null 2>&1 & echo $! > "$CF_PID"

  local url=""
  for _ in $(seq 1 30); do url="$(get_cf_url)"; [[ -n "$url" ]] && break; sleep 1; done
  [[ -n "$url" ]] || { log "URL не найден в $CF_LOG"; exit 1; }
  echo "$url" | tee "$CF_URL_FILE" >/dev/null
  log "Туннель: $url"

  if $CURL -f "$url/ping" >/dev/null 2>&1; then
    log "внешний /ping OK"
  else
    log "DNS до $url/ping не прошёл — попробую edge IP"
    local host="${url#https://}" edge; edge="$(get_cf_edge_ip || true)"
    if [[ -n "${edge:-}" ]] && $CURLV --resolve "$host:443:$edge" "https://$host/ping" >/dev/null 2>&1; then
      log "внешний /ping OK через --resolve ($edge)"
    else
      log "не достучался ни по DNS, ни через edge IP"
    fi
  fi
}
stop_tunnel(){
  if [[ -f "$CF_PID" ]]; then
    pid=$(cat "$CF_PID"||true)
    if [[ -n "${pid:-}" ]] && is_alive "$pid"; then
      log "останов cloudflared pid=$pid"; kill "$pid"||true; sleep 0.5
    fi
    rm -f "$CF_PID"
  else
    log "cloudflared не запущен"
  fi
}

# /etc/hosts map/unmap на актуальный edge IP
map_host(){
  [[ -f "$CF_URL_FILE" ]] || { echo "[ERR] нет CF URL. Запусти ./svc.sh start tunnel"; exit 1; }
  local url host edge; url=$(cat "$CF_URL_FILE"); host="${url#https://}"; edge="$(get_cf_edge_ip || true)"
  [[ -n "${edge:-}" ]] || { echo "[ERR] edge IP не найден в $CF_LOG"; exit 1; }
  echo "[hosts] add $edge $host"
  sudo sed -i.bak -E "/[[:space:]]$host$/d" /etc/hosts
  echo "$edge $host" | sudo tee -a /etc/hosts >/dev/null
  echo "[test] curl https://$host/ping"; $CURLV "https://$host/ping" || true
}
unmap_host(){
  if [[ -f "$CF_URL_FILE" ]]; then host="$(sed 's#https://##' "$CF_URL_FILE")"; else read -rp "host: " host; fi
  echo "[hosts] remove $host"; sudo sed -i.bak -E "/[[:space:]]$host$/d" /etc/hosts || true
}

# ——— команды ————————————————————————————————————————————————————————————————
cmd_start_all(){ start_server_if_needed; start_tunnel; cmd_status; }
cmd_start_tunnel(){ start_tunnel; cmd_status; }
cmd_stop(){ stop_tunnel; stop_server; }
cmd_restart(){ cmd_stop; sleep 0.5; cmd_start_all; }

cmd_status(){
  [[ -f "$SRV_PID" ]] && { pid=$(cat "$SRV_PID"||true); is_alive "${pid:-0}" || rm -f "$SRV_PID"; }
  [[ -f "$CF_PID"  ]] && { pid=$(cat "$CF_PID" ||true); is_alive "${pid:-0}" || rm -f "$CF_PID"; }
  local s_pid="-"; [[ -f "$SRV_PID" ]] && s_pid="$(cat "$SRV_PID")"
  local c_pid="-"; [[ -f "$CF_PID"  ]] && c_pid="$(cat "$CF_PID")"
  local lan="http://$(lan_ip):$PORT"
  local pub=""; [[ -f "$CF_URL_FILE" ]] && pub="$(cat "$CF_URL_FILE" || true)"

  echo "── STATUS ─────────────────────────────────"
  printf "Server:     %-8s  (%s)\n" "$s_pid" "$([[ -n "${s_pid:-}" ]] && is_alive "$s_pid" && echo up || echo down)"
  printf "Cloudflared:%-8s  (%s)\n" "$c_pid" "$([[ -n "${c_pid:-}" ]] && is_alive "$c_pid" && echo up || echo down)"
  printf "LAN URL:    %s\n" "$lan"
  printf "Public URL: %s\n" "${pub:-<none>}"

  # LOCAL /ping — всегда по loopback
  if $CURL -f "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1; then
    echo "LOCAL /ping: OK"
  else
    echo "LOCAL /ping: FAIL"
  fi

  # LAN /ping — по локальному IP
  if $CURL -f "$lan/ping" >/dev/null 2>&1; then
    echo "LAN /ping:   OK"
  else
    echo "LAN /ping:   FAIL"
  fi

  # PUBLIC /ping — если есть URL
  if [[ -n "$pub" ]] && $CURL -f "$pub/ping" >/dev/null 2>&1; then
    echo "PUB /ping:   OK"
  else
    echo "PUB /ping:   FAIL"
  fi
  echo "──────────────────────────────────────────"
}

cmd_urls(){ echo "http://$(lan_ip):$PORT"; [[ -f "$CF_URL_FILE" ]] && cat "$CF_URL_FILE" || echo "(no public url yet)"; }
cmd_logs(){ echo "─ server.log ─"; tail -n 80 "$SRV_LOG" 2>/dev/null || echo "<нет>"; echo; echo "─ cf.log ─"; tail -n 80 "$CF_LOG" 2>/dev/null || echo "<нет>"; }

cmd_doctor(){
  echo "== DOCTOR =="; echo "- who listens on :$PORT:"; ss -tulnp | grep ":$PORT " || echo "<none>"
  echo "- import app.server:"; PYTHONPATH="$ROOT" "$PYTHON" - <<'PY' || true
import importlib, sys
try: importlib.import_module("app.server"); print("OK: app.server importable")
except Exception as e: print("IMPORT FAIL:", type(e).__name__, e, file=sys.stderr)
PY
  echo "- local /ping:"; $CURL -vik "http://127.0.0.1:$PORT/ping" || true
  if [[ -f "$CF_URL_FILE" ]]; then
    url=$(cat "$CF_URL_FILE"); host="${url#https://}"; edge="$(get_cf_edge_ip || true)"
    echo "- public /ping DNS:"; $CURLV "$url/ping" || true
    if [[ -n "${edge:-}" ]]; then echo "- public /ping via --resolve $edge:"; $CURLV --resolve "$host:443:$edge" "https://$host/ping" || true; fi
  fi
}

usage(){ cat <<EOF
Usage: $(basename "$0") <command>
  start           — старт всего (сервер если его нет) + cloudflared
  start tunnel    — старт только cloudflared (dev-режим: сервер крутит VS Code)
  stop            — стоп туннеля и сервера (только своего)
  restart         — рестарт
  status          — статус и проверки /ping (LOCAL/LAN/PUB)
  urls            — вывести LAN и Public URL
  logs            — хвост логов
  doctor          — диагностика
  map             — прописать домен туннеля в /etc/hosts на текущий edge IP
  unmap           — убрать запись из /etc/hosts
  kill8080        — принудительно убить процесс(ы) на :8080
EOF
}

mkdir -p "$TUN_DIR"
case "${1:-status}" in
  start)         shift || true; [[ "${1:-all}" == "tunnel" ]] && cmd_start_tunnel || cmd_start_all ;;
  stop)          cmd_stop ;;
  restart)       cmd_restart ;;
  status)        cmd_status ;;
  urls)          cmd_urls ;;
  logs)          cmd_logs ;;
  doctor)        cmd_doctor ;;
  map)           map_host ;;
  unmap)         unmap_host ;;
  kill8080)      kill8080 ;;
  *)             usage; exit 1 ;;
esac

