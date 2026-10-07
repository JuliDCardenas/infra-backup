#!/usr/bin/env bash
set -euo pipefail

# Wrapper para automatizar el backup de Caddyfile usando el script principal.
# Delega las comprobaciones de seguridad, copia y Git a gitbackup.sh.

REPO="${INFRA_BACKUP_REPO:-$HOME/infra-backup}"
SRC="/etc/caddy/Caddyfile"
MSG="Caddyfile $(date +'%F %T')"

# Llamamos a gitbackup.sh
"$REPO/gitbackup.sh" "$SRC" "$MSG"
