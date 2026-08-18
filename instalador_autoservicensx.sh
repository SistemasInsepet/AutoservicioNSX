#!/usr/bin/env bash
set -Eeuo pipefail

# Instalador especifico Autoservicio NSX.
# Ejecutar despues del instalador base de Orange Pi.

PACKAGE_URL="${PACKAGE_URL:-https://raw.githubusercontent.com/SistemasInsepet/AutoservicioNSX/main/autoservicensx-package.tar.gz}"
DB_NAME="${DB_NAME:-autoservicionsx}"
PG_USER="${PG_USER:-postgres}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PASS="${PG_PASS:-admin}"
APP_USER="${APP_USER:-orangepi}"
APP_GROUP="${APP_GROUP:-}"
APP_HOME="${APP_HOME:-}"
DOCUMENTS_DIR="${DOCUMENTS_DIR:-}"
NODE_DIR="${NODE_DIR:-}"
RESET_DB="${RESET_DB:-ask}"
INSTALL_APP="${INSTALL_APP:-yes}"
RUN_NPM_INSTALL="${RUN_NPM_INSTALL:-yes}"

SERVICES=(
  autoservicensx-server.service
  autoservicensx-consola.service
  autoservicensx-terminal.service
  gestor-led.service
)

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[AVISO] $*" >&2
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

step() {
  echo ""
  echo "============================================================"
  echo "[PASO] $*"
  echo "============================================================"
}

require_root() {
  [ "${EUID}" -eq 0 ] || fail "Ejecuta como root: sudo bash $0"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Falta $1. Ejecuta primero el instalador base."
}

resolve_app_user() {
  local resolved=""

  if id "$APP_USER" >/dev/null 2>&1; then
    resolved="$APP_USER"
  elif id orangepi >/dev/null 2>&1; then
    resolved="orangepi"
  elif id insepet >/dev/null 2>&1; then
    resolved="insepet"
  elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ] && id "${SUDO_USER}" >/dev/null 2>&1; then
    resolved="${SUDO_USER}"
  else
    fail "No encontre usuario de aplicacion. Define APP_USER=usuario."
  fi

  APP_USER="$resolved"
  APP_GROUP="$(id -gn "$APP_USER")"
  APP_HOME="${APP_HOME:-$(getent passwd "$APP_USER" | cut -d: -f6)}"
  DOCUMENTS_DIR="${DOCUMENTS_DIR:-${APP_HOME}/Documents}"
  NODE_DIR="${NODE_DIR:-${DOCUMENTS_DIR}/Node}"

  log "Usuario app: $APP_USER"
  log "Directorio Node: $NODE_DIR"
}

validate_base_installer() {
  require_cmd curl
  require_cmd tar
  require_cmd gzip
  require_cmd gunzip
  require_cmd node
  require_cmd npm
  require_cmd psql
  require_cmd createdb
  require_cmd dropdb
  require_cmd systemctl

  systemctl start postgresql 2>/dev/null || true

  PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -h "$PG_HOST" -d postgres -tAc "SELECT 1" >/dev/null \
    || fail "No pude conectar a PostgreSQL con usuario=$PG_USER password=$PG_PASS. Ejecuta primero el instalador base."

  log "Node: $(node --version)"
  log "NPM: $(npm --version)"
  log "PostgreSQL OK"
}

download_package() {
  local output_file="$1"
  local curl_args=(-fL --retry 3 --connect-timeout 20 -o "$output_file")

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}" "${curl_args[@]}")
  fi

  log "Descargando paquete:"
  log "$PACKAGE_URL"

  if ! curl "${curl_args[@]}" "$PACKAGE_URL"; then
    fail "No pude descargar el paquete. Revisa la URL, la rama o si el repo es privado."
  fi

  local size
  size="$(wc -c < "$output_file" | tr -d '[:space:]')"
  [ "${size:-0}" -gt 1000 ] || {
    echo ""
    warn "El archivo descargado es demasiado pequeno ($size bytes). Contenido:"
    cat "$output_file" || true
    fail "GitHub no entrego el paquete real."
  }

  gzip -t "$output_file" || fail "El paquete descargado no es un .tar.gz valido."
}

extract_package() {
  local package_file="$1"
  local extract_dir="$2"

  mkdir -p "$extract_dir"
  tar -xzf "$package_file" -C "$extract_dir"

  if [ -d "$extract_dir/autoservicensx-package" ]; then
    echo "$extract_dir/autoservicensx-package"
    return 0
  fi

  local found
  found="$(find "$extract_dir" -mindepth 1 -maxdepth 2 -type f -name manifest.json -print -quit)"
  [ -n "$found" ] || fail "No encontre manifest.json dentro del paquete."
  dirname "$found"
}

backup_existing_node_dir() {
  [ -d "$NODE_DIR" ] || return 0

  local backup_dir="/root/backups_autoservicensx"
  local stamp
  stamp="$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup_dir"

  log "Respaldando Node actual en $backup_dir/Node_$stamp.tar.gz"
  tar -C "$(dirname "$NODE_DIR")" -czf "$backup_dir/Node_$stamp.tar.gz" "$(basename "$NODE_DIR")"
}

install_app_files() {
  local package_dir="$1"
  local src="$package_dir/app/Node"

  if [ "$INSTALL_APP" != "yes" ]; then
    warn "INSTALL_APP=$INSTALL_APP, se omite copia de app."
    return 0
  fi

  [ -d "$src" ] || fail "No existe la app dentro del paquete: $src"

  resolve_app_user
  backup_existing_node_dir

  mkdir -p "$NODE_DIR"

  log "Copiando app a $NODE_DIR"
  find "$NODE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -C "$src" -cpf - . | tar -C "$NODE_DIR" -xpf -
  chown -R "$APP_USER:$APP_GROUP" "$NODE_DIR"
}

database_exists() {
  PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -h "$PG_HOST" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1
}

ask_reset_db() {
  if [ "$RESET_DB" = "yes" ] || [ "$RESET_DB" = "no" ]; then
    return 0
  fi

  if database_exists; then
    echo ""
    warn "La base $DB_NAME ya existe."
    read -r -p "Deseas borrarla y restaurar el backup incluido? [s/N]: " answer
    case "$answer" in
      s|S|si|SI|Si|yes|YES) RESET_DB="yes" ;;
      *) RESET_DB="no" ;;
    esac
  else
    RESET_DB="yes"
  fi
}

restore_database() {
  local package_dir="$1"
  local backup_file="$package_dir/database/${DB_NAME}.sql.gz"

  [ -f "$backup_file" ] || fail "No existe backup: $backup_file"
  gzip -t "$backup_file" || fail "Backup de base no valido: $backup_file"

  ask_reset_db
  if [ "$RESET_DB" != "yes" ]; then
    warn "Se omite restauracion de base."
    return 0
  fi

  if database_exists; then
    log "Cerrando conexiones y borrando $DB_NAME"
    PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -h "$PG_HOST" -d postgres -v ON_ERROR_STOP=1 \
      -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}';" >/dev/null || true
    PGPASSWORD="$PG_PASS" dropdb -U "$PG_USER" -h "$PG_HOST" "$DB_NAME"
  fi

  log "Creando base $DB_NAME"
  PGPASSWORD="$PG_PASS" createdb -U "$PG_USER" -h "$PG_HOST" "$DB_NAME"

  log "Restaurando $backup_file"
  gunzip -c "$backup_file" | PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -h "$PG_HOST" -d "$DB_NAME" -v ON_ERROR_STOP=1 >/dev/null

  local tables
  tables="$(PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -h "$PG_HOST" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');" | tr -d '[:space:]')"
  log "Base restaurada. Tablas encontradas: ${tables:-0}"
}

npm_install_dir() {
  local dir="$1"
  [ -f "$dir/package.json" ] || return 0

  if [ "$RUN_NPM_INSTALL" != "yes" ]; then
    warn "RUN_NPM_INSTALL=$RUN_NPM_INSTALL, se omite npm install en $dir"
    return 0
  fi

  log "npm install en $dir"
  sudo -u "$APP_USER" bash -lc "cd '$dir' && npm install --omit=dev"
}

install_npm_dependencies() {
  resolve_app_user

  npm_install_dir "$NODE_DIR/server"
  npm_install_dir "$NODE_DIR/consola"
  npm_install_dir "$NODE_DIR/terminal"
  npm_install_dir "$NODE_DIR/gestor_leds"
}

install_services() {
  local package_dir="$1"
  local services_dir="$package_dir/services"

  [ -d "$services_dir" ] || fail "No existe carpeta de servicios: $services_dir"

  for svc in "${SERVICES[@]}"; do
    [ -f "$services_dir/$svc" ] || fail "Falta servicio en paquete: $services_dir/$svc"
    cp "$services_dir/$svc" "/etc/systemd/system/$svc"
  done

  systemctl daemon-reload

  for svc in "${SERVICES[@]}"; do
    systemctl enable "$svc"
  done
}

restart_services() {
  for svc in "${SERVICES[@]}"; do
    log "Reiniciando $svc"
    if systemctl restart "$svc"; then
      if systemctl is-active --quiet "$svc"; then
        log "$svc activo"
      else
        warn "$svc no quedo activo"
      fi
    else
      warn "No se pudo iniciar $svc"
    fi
  done
}

show_status() {
  echo ""
  systemctl status "${SERVICES[@]}" --no-pager || true
}

main() {
  require_root

  local work_dir package_file package_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  package_file="$work_dir/autoservicensx-package.tar.gz"

  echo "============================================================"
  echo "  INSTALADOR ESPECIFICO - AUTOSERVICIO NSX"
  echo "============================================================"

  step "1. Validar instalador base"
  validate_base_installer

  step "2. Descargar paquete"
  download_package "$package_file"

  step "3. Descomprimir paquete"
  package_dir="$(extract_package "$package_file" "$work_dir/extracted")"
  log "Paquete detectado: $package_dir"

  step "4. Instalar app"
  install_app_files "$package_dir"

  step "5. Restaurar base de datos"
  restore_database "$package_dir"

  step "6. Instalar dependencias npm"
  install_npm_dependencies

  step "7. Instalar servicios"
  install_services "$package_dir"

  step "8. Iniciar servicios"
  restart_services

  step "9. Estado final"
  show_status

  echo ""
  log "Instalacion especifica completada"
}

main "$@"
