#!/usr/bin/env bash
set -euo pipefail
WORKDIR="$HOME/Рабочий стол/server"
cd "$WORKDIR"

if [[ ! -f cf_url.txt ]]; then
  echo "[ERR] нет cf_url.txt"
  exit 1
fi

URL="$(cat cf_url.txt)"
HOST="${URL#https://}"

if [[ -z "$HOST" ]]; then
  echo "[ERR] пустой HOST"
  exit 2
fi

echo "[info] unmap $HOST"
sudo sed -i.bak "/[[:space:]]$HOST$/d" /etc/hosts
echo "[ok] запись удалена. Текущие строки для $HOST:"
grep -n "$HOST" /etc/hosts || echo "(нет)"
