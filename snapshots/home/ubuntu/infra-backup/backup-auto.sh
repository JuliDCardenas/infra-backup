#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/infra-backup"
SRC="/etc/caddy/Caddyfile"
DST="$REPO/caddy/Caddyfile"

# Copia desde /etc (requiere sudo) hacia el repo
sudo cp "$SRC" "$DST"
sudo chown -R "$USER:$USER" "$REPO"

cd "$REPO"

# Si no hay cambios, salir (evita commits basura)
if git diff --quiet -- "$DST"; then
  exit 0
fi

git add "$DST"
git commit -m "Caddyfile $(date +'%F %T')"
git push
