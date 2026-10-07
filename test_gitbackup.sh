#!/usr/bin/env bash
set -euo pipefail

echo "=== Iniciando pruebas automatizadas de gitbackup.sh ==="

# Preparar entorno temporal
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Aislar entorno
export HOME="$TEST_DIR/home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_CONFIG_SYSTEM="$HOME/.gitconfig_system"
mkdir -p "$HOME"

# Configurar SUDO stub
mkdir -p "$TEST_DIR/bin"
cat << 'EOF' > "$TEST_DIR/bin/sudo"
#!/usr/bin/env bash
echo "SUDO_INVOKED" >> "$HOME/sudo_log.txt"
if [[ "$SUDO_SHOULD_FAIL" == "1" ]]; then
    exit 1
fi
# En pruebas sin red/elevacion real, ejecutar sin sudo.
"$@"
EOF
chmod +x "$TEST_DIR/bin/sudo"
export PATH="$TEST_DIR/bin:$PATH"

BARE_REPO="$TEST_DIR/remote.git"
CLONE_REPO="$TEST_DIR/infra-backup"
CADDY_DIR="$TEST_DIR/etc/caddy"
SECRET_DIR="$TEST_DIR/secrets"
UNAUTH_DIR="$TEST_DIR/unauth"

mkdir -p "$CADDY_DIR"
mkdir -p "$SECRET_DIR"
mkdir -p "$UNAUTH_DIR"

# 1. Configurar repositorios Git
# Forzar rama inicial para evitar problemas con la configuracion del usuario
git init --bare --initial-branch=master "$BARE_REPO" > /dev/null
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

echo "[Test 10] Cambios unstaged ajenos"
assert_success "$SCRIPT" "$CADDYFILE" "Backup with unstaged changes"
rm basura.txt

echo "[Test 11] Escape de destino (symlink en snapshots)"
# Create a symlink inside the snapshots directory pointing to an external directory
cd "$CLONE_REPO"
mkdir -p "snapshots${CADDY_DIR}"
rm -rf "snapshots${CADDY_DIR}/Caddyfile"
ln -s "$UNAUTH_DIR" "snapshots${CADDY_DIR}/Caddyfile"
echo "updated_localhost" > "$CADDYFILE"
# Debe fallar porque el destino final escaparía de snapshots
assert_failure "$SCRIPT" "$CADDYFILE"
rm "snapshots${CADDY_DIR}/Caddyfile"

echo "[Test 12] Dry-run no produce efectos secundarios"
echo "localhost_dryrun" > "$CADDYFILE"
rm -f "$HOME/sudo_log.txt"
OLD_HEAD=$(cd "$CLONE_REPO" && git rev-parse HEAD)
assert_success "$SCRIPT" --dry-run "$CADDYFILE"
NEW_HEAD=$(cd "$CLONE_REPO" && git rev-parse HEAD)
if [[ "$OLD_HEAD" != "$NEW_HEAD" ]]; then
    echo "FALLO: Dry run creó un commit"
    exit 1
fi
if [[ -f "$HOME/sudo_log.txt" ]]; then
    echo "FALLO: Dry run invocó sudo"
    exit 1
fi

echo "[Test 13] Validar que sin cambios no se genera commit extra"
OLD_HEAD=$(cd "$CLONE_REPO" && git rev-parse HEAD)
assert_success "$SCRIPT" "$CADDYFILE" "Commit normal"
NEW_HEAD_1=$(cd "$CLONE_REPO" && git rev-parse HEAD)
if [[ "$OLD_HEAD" == "$NEW_HEAD_1" ]]; then
    echo "FALLO: No se creó commit para archivo modificado"
    exit 1
fi
assert_success "$SCRIPT" "$CADDYFILE"
NEW_HEAD_2=$(cd "$CLONE_REPO" && git rev-parse HEAD)
if [[ "$NEW_HEAD_1" != "$NEW_HEAD_2" ]]; then
    echo "FALLO: Se creó commit adicional a pesar de no haber cambios"
    exit 1
fi

echo "[Test 14] Divergencia (behind remote)"
# Simulamos que un remote tiene un commit más
cd "$CLONE_REPO"
git commit --allow-empty -m "Remote commit"
git push origin master > /dev/null 2>&1
git reset --hard HEAD~1 > /dev/null 2>&1
echo "divergent_localhost" > "$CADDYFILE"
assert_failure "$SCRIPT" "$CADDYFILE"
# Sincronizamos
git pull origin master > /dev/null 2>&1

echo "[Test 15] Falla si no hay rama upstream"
cd "$CLONE_REPO"
git branch test_no_upstream
git checkout test_no_upstream > /dev/null 2>&1
echo "no_upstream" > "$CADDYFILE"
assert_failure "$SCRIPT" "$CADDYFILE"
git checkout master > /dev/null 2>&1

echo "[Test 16] Bloqueo de rutas sensibles explícitas"
SSH_DIR="$TEST_DIR/home/.ssh"
mkdir -p "$SSH_DIR"
ID_RSA="$SSH_DIR/id_rsa"
echo "secret_key" > "$ID_RSA"

# El script ya tiene la allowlist apuntando a $CADDY_DIR/Caddyfile debido a la configuración inicial.
# Añadimos la ruta del id_rsa a la allowlist para comprobar que el veto explícito prevalece
sed -i "s|$CADDY_DIR/Caddyfile|$ID_RSA|g" "$SCRIPT"
assert_failure "$SCRIPT" "$ID_RSA"

# Probar también un nombre neutro dentro de un directorio sensible
NEUTRAL_FILE="$SSH_DIR/config.txt"
echo "neutral_content" > "$NEUTRAL_FILE"
sed -i "s|$ID_RSA|$NEUTRAL_FILE|g" "$SCRIPT"
assert_failure "$SCRIPT" "$NEUTRAL_FILE"

# Restaurar allowlist
sed -i "s|$NEUTRAL_FILE|$CADDY_DIR/Caddyfile|g" "$SCRIPT"

echo "[Test 17] Escape de destino interno (symlink a otro snapshot)"
cd "$CLONE_REPO"
# Creamos un archivo "ajeno" ya trackeado en otro snapshot
mkdir -p snapshots/other-service
echo "PRESERVE OTHER CONFIG" > snapshots/other-service/conf.txt
git add snapshots/other-service/conf.txt
git commit -m "Add other service conf" > /dev/null
# Forzamos que el destino esperado sea un symlink que apunta al conf.txt ajeno
mkdir -p "snapshots${CADDY_DIR}"
rm -f "snapshots${CADDY_DIR}/Caddyfile"
ln -s "$CLONE_REPO/snapshots/other-service/conf.txt" "snapshots${CADDY_DIR}/Caddyfile"

# Intentamos respaldar (debe fallar antes de mutar)
echo "attempt_overwrite" > "$CADDYFILE"
assert_failure "$SCRIPT" "$CADDYFILE"

# Verificamos que el archivo ajeno no se alteró
if ! grep -q "PRESERVE OTHER CONFIG" snapshots/other-service/conf.txt; then
    echo "FALLO: El archivo ajeno fue modificado"
    exit 1
fi
rm "snapshots${CADDY_DIR}/Caddyfile"

echo "[Test 18] Destino padre symlink interno/externo"
cd "$CLONE_REPO"
# Reemplazamos la carpeta del destino con un symlink
rm -rf "snapshots${CADDY_DIR}"
ln -s "$UNAUTH_DIR" "snapshots${CADDY_DIR}"
assert_failure "$SCRIPT" "$CADDYFILE"
rm "snapshots${CADDY_DIR}"

echo "=== Todas las pruebas pasaron exitosamente ==="
