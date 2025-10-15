#!/usr/bin/env bash
set -euo pipefail
WORKDIR="$HOME/Рабочий стол/server"
cd "$WORKDIR"

if [[ ! -f cf_url.txt || ! -f cf.log ]]; then
  echo "[ERR] нет cf_url.txt или cf.log — сначала ./start_tunnel.sh"
  exit 1
fi

URL="$(cat cf_url.txt)"
HOST="${URL#https://}"

# вытащить edge IP из лога (поддержка JSON и старого формата)
IP="$(grep -m1 -Eo '"ip":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' cf.log | sed -E 's/.*"ip":"([0-9.]+)".*/\1/' || true)"
if [[ -z "${IP:-}" ]]; then
  IP="$(grep -m1 -Eo 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' cf.log | cut -d= -f2 || true)"
fi

if [[ -z "$HOST" || -z "$IP" ]]; then
  echo "[ERR] не смог получить HOST/IP. HOST=\"$HOST\" IP=\"$IP\""
  exit 2
fi

echo "[info] map $HOST -> $IP"

# удалить старые строки для HOST и добавить новую
sudo sed -i.bak "/[[:space:]]$HOST$/d" /etc/hosts
echo "$IP $HOST" | sudo tee -a /etc/hosts >/dev/null

echo "[ok] /etc/hosts обновлён:"
grep -n "[[:space:]]$HOST$" /etc/hosts || true

# быстрый тест и открытие в браузере
echo "[curl] https://$HOST/ping"
curl -vk --max-time 8 "https://$HOST/ping" || true
command -v xdg-open >/dev/null && xdg-open "https://$HOST/docs" >/dev/null 2>&1 || true
echo "[tip] чтобы убрать запись — запусти cf_unmap_host.sh"
