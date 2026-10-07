#!/usr/bin/env bash
set -euo pipefail

echo "=== Iniciando pruebas automatizadas de gitbackup.sh ==="

# Preparar entorno temporal
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

BARE_REPO="$TEST_DIR/remote.git"
CLONE_REPO="$TEST_DIR/infra-backup"
CADDY_DIR="$TEST_DIR/etc/caddy"
SECRET_DIR="$TEST_DIR/secrets"
UNAUTH_DIR="$TEST_DIR/unauth"

mkdir -p "$CADDY_DIR"
mkdir -p "$SECRET_DIR"
mkdir -p "$UNAUTH_DIR"

# 1. Configurar repositorios Git
git init --bare "$BARE_REPO" > /dev/null
git clone "$BARE_REPO" "$CLONE_REPO" > /dev/null 2>&1

# Guardamos el dir original
ORIG_DIR="$PWD"

# Configurar identidad de Git temporal
cd "$CLONE_REPO"
git config user.name "Test User"
git config user.email "test@example.com"
git commit --allow-empty -m "Initial commit" > /dev/null
git push origin master > /dev/null 2>&1
cd "$ORIG_DIR"

export INFRA_BACKUP_REPO="$CLONE_REPO"
SCRIPT="$CLONE_REPO/gitbackup.sh"

# Copiar scripts al clon temporal para usar esa versión
cp "$ORIG_DIR/gitbackup.sh" "$SCRIPT"
chmod +x "$SCRIPT"

# Actualizar el script para que use el Caddyfile del entorno de prueba en su allowlist
# Modificamos la ALLOWLIST en el script copiado
sed -i "s|/etc/caddy/Caddyfile|$CADDY_DIR/Caddyfile|g" "$SCRIPT"

# Crear archivos de prueba
CADDYFILE="$CADDY_DIR/Caddyfile"
echo "localhost" > "$CADDYFILE"

SECRET_FILE="$CADDY_DIR/.env.secret"
echo "secret=123" > "$SECRET_FILE"

UNAUTH_FILE="$UNAUTH_DIR/config.txt"
echo "unauth" > "$UNAUTH_FILE"

# --- FUNCIONES DE AYUDA ---
assert_success() {
    if ! "$@"; then
        echo "FALLO: Se esperaba éxito de '$*'"
        exit 1
    fi
}

assert_failure() {
    if "$@"; then
        echo "FALLO: Se esperaba fallo de '$*'"
        exit 1
    fi
}

assert_output_contains() {
    local str="$1"
    shift
    if ! "$@" | grep -q "$str"; then
        echo "FALLO: La salida de '$*' no contiene '$str'"
        exit 1
    fi
}

# --- CASOS DE PRUEBA ---

echo "[Test 1] Archivo no permitido (fuera de allowlist)"
assert_failure "$SCRIPT" "$UNAUTH_FILE"

echo "[Test 2] Archivo secreto (bloqueado por nombre)"
assert_failure "$SCRIPT" "$SECRET_FILE"

echo "[Test 3] Dry run (nuevo archivo permitido)"
assert_success "$SCRIPT" --dry-run "$CADDYFILE"
if [[ -f "$CLONE_REPO/snapshots/$CADDY_DIR/Caddyfile" ]]; then
    echo "FALLO: Dry run copió el archivo"
    exit 1
fi

echo "[Test 4] Nuevo archivo permitido (primer backup)"
assert_success "$SCRIPT" "$CADDYFILE"
if [[ ! -f "$CLONE_REPO/snapshots${CADDY_DIR}/Caddyfile" ]]; then
    echo "FALLO: El archivo no se copió a snapshots"
    exit 1
fi

echo "[Test 5] Sin cambios"
OUTPUT=$("$SCRIPT" "$CADDYFILE")
if ! echo "$OUTPUT" | grep -q "Sin cambios"; then
    echo "FALLO: No detectó que el archivo no tenía cambios"
    exit 1
fi

echo "[Test 6] Archivo modificado y mensaje opcional"
echo "localhost:8080" > "$CADDYFILE"
assert_success "$SCRIPT" "$CADDYFILE" "Mensaje de prueba"
LOG=$(cd "$CLONE_REPO" && git log -1 --pretty=%B)
if ! echo "$LOG" | grep -q "Mensaje de prueba"; then
    echo "FALLO: El mensaje de commit personalizado no se usó"
    exit 1
fi

echo "[Test 7] Fallo de push y reintento"
echo "localhost:80" > "$CADDYFILE"
# Simulamos fallo de push renombrando temporalmente el remoto
mv "$BARE_REPO" "${BARE_REPO}_tmp"
# El script debe fallar y conservar el commit local
if "$SCRIPT" "$CADDYFILE" > /dev/null 2>&1; then
    echo "FALLO: El script debió fallar al no poder hacer push"
    exit 1
fi
AHEAD=$(cd "$CLONE_REPO" && git rev-list --count HEAD...@{u})
if [[ "$AHEAD" -eq 0 ]]; then
    echo "FALLO: El commit local se perdió tras el fallo de push"
    exit 1
fi

# Restauramos el remoto
mv "${BARE_REPO}_tmp" "$BARE_REPO"

# Test de reintento sin cambios en el archivo original
# Debería empujar los commits pendientes
OUTPUT=$("$SCRIPT" "$CADDYFILE")
if ! echo "$OUTPUT" | grep -q "Push exitoso"; then
    echo "FALLO: No se empujaron los commits pendientes"
    exit 1
fi

echo "[Test 8] Symlink traversal (intento de escape)"
SYMLINK="$CADDY_DIR/symlink_to_unauth"
ln -s "$UNAUTH_FILE" "$SYMLINK"
# El script debe resolver el symlink, ver que apunta a unauth, y bloquearlo
assert_failure "$SCRIPT" "$SYMLINK"

echo "[Test 9] Cambios cacheados (staged) ajenos"
cd "$CLONE_REPO"
echo "basura" > basura.txt
git add basura.txt
assert_failure "$SCRIPT" "$CADDYFILE"
git reset HEAD basura.txt
rm basura.txt

echo "=== Todas las pruebas pasaron exitosamente ==="
