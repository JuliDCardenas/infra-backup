# infra-backup

Repositorio de respaldo para configuraciones importantes del VPS.

**ADVERTENCIA**: Este repositorio y los scripts correspondientes están diseñados **únicamente** para respaldar configuraciones de texto pre-aprobadas (por ejemplo, el `Caddyfile`). **NO** respaldan bases de datos, volúmenes de Docker, ni el estado general del servidor, y no garantizan una recuperación completa del sistema ante un fallo crítico. Cada archivo debe ser revisado humanamente para asegurar que no contenga credenciales o secretos sensibles (como contraseñas, claves, o tokens).

## Scripts

### `gitbackup.sh`

El script principal para respaldar un archivo específico de manera segura.

**Uso**:
```bash
./gitbackup.sh [--dry-run] /ruta/absoluta/al/archivo [mensaje opcional]
```

- `--dry-run`: No realiza copias ni commits reales. Muestra los pasos que realizaría, las rutas de origen y destino validadas, y si se requiere realizar algún push pendiente o commit nuevo.
- `mensaje opcional`: Un mensaje de commit personalizado para el respaldo.

**Características de seguridad y funcionamiento**:
- **Allowlist (Lista Blanca)**: Por seguridad, sólo se permite respaldar archivos listados explícitamente y en rutas absolutas. Actualmente, el único archivo permitido es `/etc/caddy/Caddyfile`. Para añadir otros, debes editar manualmente la variable `ALLOWLIST` en el script después de asegurarte de que dicho archivo no contenga secretos.
- **Protección contra secretos**: El script bloquea preventivamente respaldar archivos que tengan nombres sospechosos (ej. `.env`, `.key`, `secret`, etc.).
- **Symlinks y Traversal**: El script usa `realpath` para resolver symlinks, previniendo ataques de escalada de directorio.
- **Git Protections**: El script verifica si el índice de Git está limpio antes de continuar y que la rama no esté divergente. Si un push falla (por problemas de red, por ejemplo), el commit se queda guardado localmente de forma segura y el script intentará empujarlo la próxima vez que se ejecute.
- **Single commit**: Cada llamada que incluya un archivo con cambios resultará en exactamente 1 commit, el cual solo se procesará si verdaderamente existen modificaciones en el contenido del archivo.

### `backup-auto.sh`

Es un *wrapper* alrededor de `gitbackup.sh`. Su única finalidad es facilitar el respaldo automatizado del archivo `/etc/caddy/Caddyfile`. No añade lógica nueva, solo llama a `gitbackup.sh` pre-configurado para ese archivo, garantizando que todos los chequeos de seguridad se sigan ejecutando.

## Pruebas (Tests)

El repositorio incluye un conjunto de pruebas automatizadas aisladas para asegurar que las políticas y chequeos operen de forma correcta.

**Ejecución**:
```bash
./test_gitbackup.sh
```

Estas pruebas funcionan de forma 100% *offline*, creando un repositorio bare temporal para simular un remeto real sin interferir con la infraestructura en vivo. Las pruebas cubren escenarios como cambios nuevos, archivos sin modificar, errores de push/retries, bloqueo de symlinks, archivos secretos y archivos no permitidos.
