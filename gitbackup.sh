#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/infra-backup"
SRC="${1:-}"
MSG="${2:-}"

if [[ -z "$SRC" ]]; then
  echo "Uso: $0 /ruta/al/archivo"
  exit 1
fi

# Si SRC es relativo, convertirlo a absoluto desde el directorio actual
if [[ "$SRC" != /* ]]; then
  SRC="$(pwd)/$SRC"
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

# Si es nuevo (untracked) o está modificado, hay que commitear
if git status --porcelain -- "$DST" | grep -q .; then
  git add "$DST"
  if [[ -n "$MSG" ]]; then
    git commit -m "$MSG"
  else
    git commit -m "Backup $(basename "$SRC") $(date +'%F %T')"
  fi
  git push
  echo "OK: $SRC -> $DST"
else
  echo "Sin cambios: $SRC"
fi

git add "$DST"
git commit -m "Backup $(basename "$SRC") $(date +'%F %T')"
git push
echo "OK: $SRC -> $DST"
