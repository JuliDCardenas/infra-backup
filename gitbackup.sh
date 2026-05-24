#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/infra-backup"
SRC="${1:-}"

if [[ -z "$SRC" ]]; then
  echo "Uso: $0 /ruta/al/archivo"
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "No existe: $SRC"
  exit 1
fi

# Destino dentro del repo (respeta estructura)
REL="${SRC#/}"                 # quita el / inicial
DST="$REPO/snapshots/$REL"

mkdir -p "$(dirname "$DST")"

# Copia (si requiere sudo, úsalo; si no, copia normal)
sudo cp "$SRC" "$DST" 2>/dev/null || cp "$SRC" "$DST"
sudo chown -R "$USER:$USER" "$REPO" >/dev/null 2>&1 || true

cd "$REPO"

# OJO: si el archivo aún no está trackeado, esto lo marca como "cambio"
if git diff --quiet -- "$DST" 2>/dev/null; then
  echo "Sin cambios: $SRC"
  exit 0
fi

git add "$DST"
git commit -m "Backup $(basename "$SRC") $(date +'%F %T')"
git push
echo "OK: $SRC -> $DST"
