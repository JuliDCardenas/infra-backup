#!/usr/bin/env bash
set -euo pipefail

# DEFINICIÓN DE VARIABLES
REPO="${INFRA_BACKUP_REPO:-$HOME/infra-backup}"

# POLICY: Archivos permitidos (añadir aquí bajo revisión)
# Requiere revisión humana de contenido, no asuma que está libre de secretos.
ALLOWLIST=(
    "/etc/caddy/Caddyfile"
)

# PARSE ARGUMENTS
DRY_RUN=0
SRC=""
MSG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -*)
            echo "Error: Argumento desconocido $1"
            exit 1
            ;;
        *)
            if [[ -z "$SRC" ]]; then
                SRC="$1"
            elif [[ -z "$MSG" ]]; then
                MSG="$1"
            else
                echo "Error: Argumentos extra ignorados: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$SRC" ]]; then
    echo "Uso: $0 [--dry-run] /ruta/al/archivo [mensaje]"
    exit 1
fi

# Convertir a ruta absoluta
if [[ "$SRC" != /* ]]; then
    SRC="$(pwd)/$SRC"
fi

if [[ ! -f "$SRC" ]]; then
    echo "Error: No existe: $SRC"
    exit 1
fi

# RESOLVE SYMLINKS AND TRAVERSAL
# Usamos realpath para obtener la ruta absoluta limpia y resolver symlinks
REAL_SRC="$(realpath -q "$SRC" || echo "$SRC")"

# SECRET CHECK
BASENAME="$(basename "$REAL_SRC")"
# Bloqueo heurístico de secretos
if [[ "$BASENAME" == .env* ]] || [[ "$BASENAME" == *.key ]] || [[ "$BASENAME" == *.pem ]] || [[ "$BASENAME" == *secret* ]] || [[ "$BASENAME" == *credential* ]]; then
    echo "Error: El archivo $REAL_SRC parece contener secretos según su nombre. Bloqueado."
    exit 1
fi

# ALLOWLIST CHECK
ALLOWED=0
for allowed_file in "${ALLOWLIST[@]}"; do
    if [[ "$REAL_SRC" == "$allowed_file" ]]; then
        ALLOWED=1
        break
    fi
done

if [[ "$ALLOWED" -eq 0 ]]; then
    echo "Error: Ruta no permitida en ALLOWLIST: $REAL_SRC"
    exit 1
fi

# DESTINO
REL="${REAL_SRC#/}"
DST="$REPO/snapshots/$REL"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: Origen validado: $REAL_SRC"
    echo "DRY-RUN: Destino previsto: $DST"
fi

cd "$REPO" || { echo "Error: No se pudo entrar al repositorio $REPO"; exit 1; }

# PRE-FLIGHT GIT CHECKS

# Índice limpio
if ! git diff --cached --quiet; then
    echo "Error: Hay cambios cacheados (staged) en el índice de Git. Abortando por seguridad."
    exit 1
fi

# Upstream configurado
UPSTREAM=$(git rev-parse --abbrev-ref @{u} 2>/dev/null || true)
if [[ -z "$UPSTREAM" ]]; then
    echo "Error: No hay rama upstream configurada para empujar."
    exit 1
fi

# Divergencia
AHEAD_BEHIND=$(git rev-list --left-right --count HEAD..."$UPSTREAM" 2>/dev/null || echo "0 0")
AHEAD=$(echo "$AHEAD_BEHIND" | awk '{print $1}')
BEHIND=$(echo "$AHEAD_BEHIND" | awk '{print $2}')

if [[ "$BEHIND" -gt 0 ]]; then
    echo "Error: La rama local está detrás de la remota (divergencia). No se puede empujar."
    exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$AHEAD" -gt 0 ]]; then
        echo "DRY-RUN: Se detectaron $AHEAD commits pendientes de push."
    fi
fi

# BACKUP PROCESS

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: Crearía directorio $(dirname "$DST")"
    echo "DRY-RUN: Copiaría $REAL_SRC a $DST"

    if [[ ! -f "$DST" ]] || ! cmp -s "$REAL_SRC" "$DST"; then
        echo "DRY-RUN: Archivo modificado o nuevo. Se haría git add, commit y push."
    else
        echo "DRY-RUN: Sin cambios en el archivo."
        if [[ "$AHEAD" -gt 0 ]]; then
            echo "DRY-RUN: Hay commits pendientes, se realizaría push."
        fi
    fi
    exit 0
fi

# Aplicar copia
mkdir -p "$(dirname "$DST")"
cp "$REAL_SRC" "$DST" 2>/dev/null || sudo cp "$REAL_SRC" "$DST"
# Restaurar permisos mínimos (sólo el archivo modificado)
sudo chown "$USER:$USER" "$DST" >/dev/null 2>&1 || true

# GIT COMMIT & PUSH
CHANGED=0
if git status --porcelain -- "$DST" | grep -q .; then
    CHANGED=1
    git add "$DST"
    if [[ -n "$MSG" ]]; then
        git commit -m "$MSG"
    else
        git commit -m "Backup $(basename "$REAL_SRC") $(date +'%F %T')"
    fi
fi

if [[ "$CHANGED" -eq 1 ]] || [[ "$AHEAD" -gt 0 ]]; then
    if git push; then
        echo "OK: Push exitoso."
        exit 0
    else
        echo "Error: Falló el git push. El commit local se conserva para reintento."
        exit 1
    fi
else
    echo "Sin cambios ni commits pendientes: $REAL_SRC"
    exit 0
fi
