#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_DIR="${APP_DIR:-/var/www/pg_manager}"
THL_REPO_URL="${THL_REPO_URL:-https://github.com/thl-corporation/thl-sql.git}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/opt/thl-sql-installer}"
THL_INSTALL_DEBUG="${THL_INSTALL_DEBUG:-0}"
THL_INSTALL_LOG_FILE="${THL_INSTALL_LOG_FILE:-/var/log/thl-sql-install.log}"
THL_SYSTEM_UPGRADE_POLICY="${THL_SYSTEM_UPGRADE_POLICY:-full}"
THL_INSTALL_LOG_INITIALIZED="${THL_INSTALL_LOG_INITIALIZED:-0}"
FIREWALL_BACKEND=""
OS_FAMILY=""
PKG_TOOL=""
NGINX_CONF_FILE="/etc/nginx/conf.d/pg_manager.conf"

log() {
    echo -e "${CYAN}$*${NC}"
}

warn() {
    echo -e "${YELLOW}$*${NC}"
}

die() {
    echo -e "${RED}$*${NC}"
    exit 1
}

on_error() {
    local exit_code="$?"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local failed_command="${BASH_COMMAND:-unknown}"

    echo -e "${RED}Error: fallo en linea ${line_no} (exit ${exit_code}): ${failed_command}${NC}" >&2
    if [ -n "${THL_INSTALL_LOG_FILE:-}" ]; then
        echo -e "${YELLOW}Log: ${THL_INSTALL_LOG_FILE}${NC}" >&2
    fi
    exit "${exit_code}"
}

trap 'on_error' ERR

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Error: ejecuta este script como root."
    fi
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        die "Error: este instalador requiere systemd."
    fi
}

validate_install_settings() {
    case "${THL_INSTALL_DEBUG}" in
        0|1) ;;
        *)
            die "Valor invalido THL_INSTALL_DEBUG=${THL_INSTALL_DEBUG}. Usa 0 o 1."
            ;;
    esac

    case "${THL_SYSTEM_UPGRADE_POLICY}" in
        none|upgrade|full) ;;
        *)
            die "Valor invalido THL_SYSTEM_UPGRADE_POLICY=${THL_SYSTEM_UPGRADE_POLICY}. Usa none, upgrade o full."
            ;;
    esac
}

init_install_logging() {
    if [ "${THL_INSTALL_LOG_INITIALIZED}" = "1" ]; then
        if [ "${THL_INSTALL_DEBUG}" = "1" ]; then
            set -x
        fi
        return
    fi

    mkdir -p "$(dirname "${THL_INSTALL_LOG_FILE}")"
    touch "${THL_INSTALL_LOG_FILE}"
    chmod 600 "${THL_INSTALL_LOG_FILE}" || true

    exec > >(tee -a "${THL_INSTALL_LOG_FILE}") 2>&1
    export THL_INSTALL_LOG_INITIALIZED=1

    log "Log de instalacion: ${THL_INSTALL_LOG_FILE}"
    if [ "${THL_INSTALL_DEBUG}" = "1" ]; then
        log "Modo debug habilitado (THL_INSTALL_DEBUG=1)."
        set -x
    fi
}

detect_os() {
    if [ ! -f /etc/os-release ]; then
        die "No se pudo detectar la distribucion (falta /etc/os-release)."
    fi
    # shellcheck disable=SC1091
    source /etc/os-release

    local os_name="${ID:-}"
    local os_like="${ID_LIKE:-}"

    if [[ "${os_name}" =~ (debian|ubuntu) ]] || [[ "${os_like}" =~ (debian|ubuntu) ]]; then
        OS_FAMILY="debian"
        PKG_TOOL="apt"
        FIREWALL_BACKEND="ufw"
        return
    fi

    if [[ "${os_name}" =~ (rhel|rocky|almalinux|centos|fedora) ]] || [[ "${os_like}" =~ (rhel|fedora|centos) ]]; then
        OS_FAMILY="rhel"
        if command -v dnf >/dev/null 2>&1; then
            PKG_TOOL="dnf"
        else
            PKG_TOOL="yum"
        fi
        FIREWALL_BACKEND="firewalld"
        return
    fi

    die "Distribucion no soportada: ID=${os_name} ID_LIKE=${os_like}"
}

run_with_retry() {
    local retries="$1"
    shift

    local attempt=1
    local rc=0
    while true; do
        if "$@"; then
            return 0
        fi

        rc=$?
        if [ "${attempt}" -ge "${retries}" ]; then
            return "${rc}"
        fi

        warn "Intento ${attempt}/${retries} fallo (rc=${rc}). Reintentando..."
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done
}

apt_recover() {
    warn "Intentando recuperar estado de APT/DPKG..."
    dpkg --configure -a || true
    apt-get install -f -y || true
    apt --fix-broken install -y || true
}

pkg_update() {
    if [ "${PKG_TOOL}" = "apt" ]; then
        run_with_retry 3 apt-get update
        return
    fi
    if [ "${PKG_TOOL}" = "dnf" ]; then
        run_with_retry 2 dnf -y makecache
        return
    fi
    run_with_retry 2 yum -y makecache
}

pkg_upgrade_system() {
    if [ "${THL_SYSTEM_UPGRADE_POLICY}" = "none" ]; then
        log "Politica de upgrade del sistema: none (omitido)."
        return
    fi

    if [ "${PKG_TOOL}" = "apt" ]; then
        local apt_upgrade_cmd="upgrade"
        if [ "${THL_SYSTEM_UPGRADE_POLICY}" = "full" ]; then
            apt_upgrade_cmd="full-upgrade"
        fi
        log "Aplicando ${apt_upgrade_cmd} del sistema..."
        run_with_retry 2 env DEBIAN_FRONTEND=noninteractive apt-get "${apt_upgrade_cmd}" -y
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        log "Aplicando upgrade del sistema con dnf..."
        run_with_retry 2 dnf upgrade -y
        return
    fi

    log "Aplicando upgrade del sistema con yum..."
    run_with_retry 2 yum update -y
}

pkg_install_critical() {
    if [ "$#" -eq 0 ]; then
        return
    fi

    if [ "${PKG_TOOL}" = "apt" ]; then
        if run_with_retry 2 env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
            return
        fi

        warn "Fallo instalacion critica con APT. Ejecutando recuperacion..."
        apt_recover
        if run_with_retry 1 env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
            return
        fi

        die "No se pudieron instalar paquetes criticos: $*"
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        run_with_retry 2 dnf install -y "$@" || die "No se pudieron instalar paquetes criticos: $*"
        return
    fi

    run_with_retry 2 yum install -y "$@" || die "No se pudieron instalar paquetes criticos: $*"
}

pkg_install_optional() {
    if [ "$#" -eq 0 ]; then
        return
    fi

    if [ "${PKG_TOOL}" = "apt" ]; then
        run_with_retry 2 env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || {
            warn "No se pudieron instalar paquetes opcionales: $*"
            return 1
        }
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        run_with_retry 2 dnf install -y "$@" || {
            warn "No se pudieron instalar paquetes opcionales: $*"
            return 1
        }
        return
    fi

    run_with_retry 2 yum install -y "$@" || {
        warn "No se pudieron instalar paquetes opcionales: $*"
        return 1
    }
}

enable_service_if_exists() {
    local service="$1"
    if systemctl list-unit-files | grep -q "^${service}\.service"; then
        systemctl enable --now "${service}" >/dev/null 2>&1 || true
    fi
}

install_prerequisites() {
    log "[1/11] Instalando dependencias del sistema..."
    pkg_update
    pkg_upgrade_system

    if [ "${OS_FAMILY}" = "debian" ]; then
        pkg_install_critical bash ca-certificates curl git tar sudo openssl python3 python3-venv python3-pip \
            nginx postgresql postgresql-contrib pgbouncer haproxy ufw cron

        pkg_install_optional gnupg lsb-release software-properties-common || true
    else
        if [ "${PKG_TOOL}" = "dnf" ]; then
            dnf install -y epel-release >/dev/null 2>&1 || true
        fi
        pkg_install_critical bash ca-certificates curl git tar sudo openssl python3 python3-pip python3-virtualenv \
            nginx postgresql-server postgresql-contrib pgbouncer haproxy firewalld \
            cronie
    fi

    enable_service_if_exists nginx
    enable_service_if_exists crond
    enable_service_if_exists cron
}

install_bootstrap_tools() {
    log "[bootstrap] Instalando herramientas base para one-link..."
    pkg_update

    if [ "${OS_FAMILY}" = "debian" ]; then
        pkg_install_critical bash ca-certificates curl git tar sudo
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        dnf install -y epel-release >/dev/null 2>&1 || true
    fi
    pkg_install_critical bash ca-certificates curl git tar sudo
}

validate_safe_bootstrap_dir() {
    local target="$1"

    [ -n "${target}" ] || die "BOOTSTRAP_DIR no puede ser vacio."
    [[ "${target}" = /* ]] || die "BOOTSTRAP_DIR debe ser ruta absoluta: ${target}"

    case "${target}" in
        "/"|"/root"|"/home"|"/opt"|"/tmp"|"/var"|"/usr"|"/etc")
            die "BOOTSTRAP_DIR inseguro para operaciones destructivas: ${target}"
            ;;
    esac

    if [[ "${target}" != *thl-sql* ]]; then
        die "BOOTSTRAP_DIR debe contener 'thl-sql' por seguridad: ${target}"
    fi
}

safe_reset_bootstrap_dir() {
    validate_safe_bootstrap_dir "${BOOTSTRAP_DIR}"
    if [ -e "${BOOTSTRAP_DIR}" ]; then
        rm -rf "${BOOTSTRAP_DIR}"
    fi
}

repo_slug_from_url() {
    local repo_url="$1"
    repo_url="${repo_url%.git}"

    if [[ "${repo_url}" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

download_repo_tarball_fallback() {
    local repo_slug
    repo_slug="$(repo_slug_from_url "${THL_REPO_URL}")" || return 1

    local tarball_url="https://codeload.github.com/${repo_slug}/tar.gz/refs/heads/main"
    local tmp_tar tmp_dir extracted_dir
    tmp_tar="$(mktemp /tmp/thl-sql-bootstrap.XXXXXX.tar.gz)"
    tmp_dir="$(mktemp -d /tmp/thl-sql-bootstrap.XXXXXX)"

    if ! run_with_retry 2 curl -fL --connect-timeout 10 "${tarball_url}" -o "${tmp_tar}"; then
        rm -f "${tmp_tar}" || true
        rm -rf "${tmp_dir}" || true
        return 1
    fi

    tar -xzf "${tmp_tar}" -C "${tmp_dir}"
    extracted_dir="$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
    [ -n "${extracted_dir}" ] || die "No se pudo extraer el tarball del repositorio."

    mv "${extracted_dir}" "${BOOTSTRAP_DIR}"
    rm -f "${tmp_tar}" || true
    rm -rf "${tmp_dir}" || true
}

sync_bootstrap_repo() {
    validate_safe_bootstrap_dir "${BOOTSTRAP_DIR}"
    mkdir -p "$(dirname "${BOOTSTRAP_DIR}")"

    if [ -d "${BOOTSTRAP_DIR}/.git" ]; then
        if run_with_retry 2 git -C "${BOOTSTRAP_DIR}" fetch --depth 1 origin main && \
            git -C "${BOOTSTRAP_DIR}" checkout -f main && \
            git -C "${BOOTSTRAP_DIR}" reset --hard origin/main; then
            return
        fi

        warn "No se pudo actualizar bootstrap por git fetch. Se intentara descarga limpia."
        safe_reset_bootstrap_dir
    else
        safe_reset_bootstrap_dir
    fi

    if run_with_retry 2 git clone --depth 1 "${THL_REPO_URL}" "${BOOTSTRAP_DIR}"; then
        return
    fi

    warn "git clone fallo. Intentando fallback por tarball de GitHub..."
    safe_reset_bootstrap_dir
    if download_repo_tarball_fallback; then
        return
    fi

    die "No se pudo descargar el repositorio (${THL_REPO_URL}) por git ni por tarball."
}

ensure_repo_source() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${script_dir}/backend/main.py" ] && [ -f "${script_dir}/server/configure_sql_proxy.sh" ]; then
        SCRIPT_DIR="${script_dir}"
        return
    fi

    log "Instalacion en modo one-link detectada. Descargando repo ${THL_REPO_URL}..."
    install_bootstrap_tools
    sync_bootstrap_repo

    [ -f "${BOOTSTRAP_DIR}/install.sh" ] || die "No se encontro install.sh en ${BOOTSTRAP_DIR}."

    export THL_REPO_URL
    export THL_DOMAIN="${THL_DOMAIN:-}"
    export THL_BIND_IP="${THL_BIND_IP:-}"
    export THL_PORT="${THL_PORT:-}"
    export THL_ADMIN_USER="${THL_ADMIN_USER:-}"
    export THL_ADMIN_PASS="${THL_ADMIN_PASS:-}"
    export THL_PG_PASSWORD="${THL_PG_PASSWORD:-}"
    export THL_NONINTERACTIVE="${THL_NONINTERACTIVE:-}"
    export THL_INSTALL_DEBUG
    export THL_INSTALL_LOG_FILE
    export THL_SYSTEM_UPGRADE_POLICY
    export THL_INSTALL_LOG_INITIALIZED

    exec bash "${BOOTSTRAP_DIR}/install.sh"
}

collect_input() {
    SERVER_IP="$(curl -fsS --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')"
    if [ -z "${SERVER_IP}" ]; then
        SERVER_IP="127.0.0.1"
    fi

    ADMIN_USERNAME="${THL_ADMIN_USER:-}"
    if [ -z "${ADMIN_USERNAME}" ]; then
        read -r -p "Usuario administrador [admin]: " ADMIN_USERNAME
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    fi

    ADMIN_PASSWORD="${THL_ADMIN_PASS:-}"
    if [ -z "${ADMIN_PASSWORD}" ]; then
        while true; do
            read -r -s -p "Contrasena administrador: " ADMIN_PASSWORD
            echo ""
            [ -n "${ADMIN_PASSWORD}" ] || { warn "La contrasena no puede estar vacia."; continue; }
            read -r -s -p "Confirmar contrasena: " ADMIN_PASSWORD_CONFIRM
            echo ""
            if [ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]; then
                warn "Las contrasenas no coinciden."
                continue
            fi
            break
        done
    fi

    DOMAIN="${THL_DOMAIN:-}"
    if [ -z "${DOMAIN}" ] && [ "${THL_NONINTERACTIVE:-0}" != "1" ]; then
        echo ""
        echo "Si tienes dominio, ingresalo. Si no, deja vacio y se usa IP:puerto."
        read -r -p "Dominio (ej: sql.midominio.com) [vacio para IP]: " DOMAIN
    fi

    WEB_PORT="${THL_PORT:-}"
    if [ -n "${DOMAIN}" ]; then
        USE_DOMAIN="true"
        WEB_PORT="443"
        APP_URL="https://${DOMAIN}"
        ALLOWED_ORIGINS="https://${DOMAIN}"
        COOKIE_SECURE="true"
        PUBLIC_DB_HOST="${DOMAIN}"
    else
        USE_DOMAIN="false"
        if [ -z "${WEB_PORT}" ]; then
            if [ "${THL_NONINTERACTIVE:-0}" = "1" ]; then
                WEB_PORT="80"
            else
                read -r -p "Puerto para panel web [80]: " WEB_PORT
                WEB_PORT="${WEB_PORT:-80}"
            fi
        fi
        BIND_IP="${THL_BIND_IP:-${SERVER_IP}}"
        APP_URL="http://${BIND_IP}:${WEB_PORT}"
        ALLOWED_ORIGINS="http://${BIND_IP}:${WEB_PORT},http://${BIND_IP}"
        COOKIE_SECURE="false"
        PUBLIC_DB_HOST="${BIND_IP}"
    fi

    PG_PASSWORD="${THL_PG_PASSWORD:-}"
    if [ -z "${PG_PASSWORD}" ]; then
        PG_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
    fi
}

show_summary() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  Resumen de instalacion${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "  OS family:       ${OS_FAMILY}"
    echo "  Firewall:        ${FIREWALL_BACKEND}"
    echo "  Admin user:      ${ADMIN_USERNAME}"
    echo "  Panel URL:       ${APP_URL}"
    echo "  Public DB host:  ${PUBLIC_DB_HOST}"
    echo "  PostgreSQL pass: ${PG_PASSWORD:0:5}..."
    echo -e "${CYAN}========================================${NC}"
    echo ""

    if [ "${THL_NONINTERACTIVE:-0}" = "1" ]; then
        return
    fi

    read -r -p "Continuar con la instalacion? [S/n]: " CONFIRM
    CONFIRM="${CONFIRM:-S}"
    if [[ ! "${CONFIRM}" =~ ^[SsYy]$ ]]; then
        die "Instalacion cancelada."
    fi
}

configure_dns() {
    log "[2/11] Ajustando DNS del sistema..."
    if systemctl is-active --quiet systemd-resolved; then
        if ! grep -q "^DNS=8.8.8.8 8.8.4.4" /etc/systemd/resolved.conf 2>/dev/null; then
            if grep -q "^#DNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^#DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
            elif grep -q "^DNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
            else
                echo "DNS=8.8.8.8 8.8.4.4" >> /etc/systemd/resolved.conf
            fi
        fi
        if ! grep -q "^FallbackDNS=1.1.1.1 1.0.0.1" /etc/systemd/resolved.conf 2>/dev/null; then
            if grep -q "^#FallbackDNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^#FallbackDNS=.*/FallbackDNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
            elif grep -q "^FallbackDNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^FallbackDNS=.*/FallbackDNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
            else
                echo "FallbackDNS=1.1.1.1 1.0.0.1" >> /etc/systemd/resolved.conf
            fi
        fi
        systemctl restart systemd-resolved || true
    fi
}

configure_postgres_service() {
    log "[3/11] Configurando PostgreSQL..."

    if [ "${OS_FAMILY}" = "rhel" ] && [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
        if command -v postgresql-setup >/dev/null 2>&1; then
            postgresql-setup --initdb >/dev/null 2>&1 || true
        fi
    fi

    systemctl enable --now postgresql >/dev/null 2>&1 || systemctl restart postgresql

    local pg_password_sql
    pg_password_sql="${PG_PASSWORD//\'/\'\'}"
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD '${pg_password_sql}';\"" >/dev/null

    local pg_conf pg_hba pg_hba_include
    pg_conf="$(find /etc/postgresql /var/lib/pgsql -name postgresql.conf 2>/dev/null | head -1 || true)"
    pg_hba="$(find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1 || true)"

    if [ -z "${pg_conf}" ] || [ -z "${pg_hba}" ]; then
        die "No se pudo localizar postgresql.conf o pg_hba.conf."
    fi

    if ! grep -q "^host all postgres 127.0.0.1/32 scram-sha-256$" "${pg_hba}"; then
        echo "host all postgres 127.0.0.1/32 scram-sha-256" >> "${pg_hba}"
    fi

    pg_hba_include="$(dirname "${pg_hba}")/pg_hba_sql_manager.conf"
    touch "${pg_hba_include}"
    chown postgres:postgres "${pg_hba_include}"
    chmod 640 "${pg_hba_include}"

    if ! grep -q "include_if_exists ${pg_hba_include}" "${pg_hba}"; then
        echo "include_if_exists ${pg_hba_include}" >> "${pg_hba}"
    fi

    systemctl restart postgresql

    cp "${SCRIPT_DIR}/server/configure_postgres_timeouts.sh" /usr/local/bin/configure_postgres_timeouts.sh
    chmod +x /usr/local/bin/configure_postgres_timeouts.sh
    if ! /usr/local/bin/configure_postgres_timeouts.sh; then
        warn "configure_postgres_timeouts.sh fallo. Reintentando una vez..."
        sleep 3
        /usr/local/bin/configure_postgres_timeouts.sh || {
            journalctl -u postgresql --no-pager -n 80 || true
            die "No se pudo completar la configuracion final de PostgreSQL."
        }
    fi
}

deploy_app() {
    log "[4/11] Desplegando aplicacion..."
    mkdir -p "${APP_DIR}"

    [ -f "${SCRIPT_DIR}/backend/main.py" ] || die "No se encontro backend/main.py en ${SCRIPT_DIR}."
    [ -f "${SCRIPT_DIR}/server/configure_sql_proxy.sh" ] || die "No se encontro server/configure_sql_proxy.sh en ${SCRIPT_DIR}."

    rm -rf "${APP_DIR}/backend" "${APP_DIR}/server"
    cp -r "${SCRIPT_DIR}/backend" "${APP_DIR}/backend"
    cp -r "${SCRIPT_DIR}/server" "${APP_DIR}/server"

    if [ -f "${SCRIPT_DIR}/verify_deployment.py" ]; then
        cp "${SCRIPT_DIR}/verify_deployment.py" "${APP_DIR}/verify_deployment.py"
    fi
    if [ -f "${SCRIPT_DIR}/verify_remote.py" ]; then
        cp "${SCRIPT_DIR}/verify_remote.py" "${APP_DIR}/verify_remote.py"
    fi
}

setup_python_env() {
    log "[5/11] Instalando dependencias Python..."
    python3 -m venv "${APP_DIR}/venv"
    "${APP_DIR}/venv/bin/pip" install --upgrade pip
    "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/backend/requirements.txt"
}

write_env_file() {
    log "[6/11] Generando backend/.env..."
    local encryption_key
    encryption_key="$("${APP_DIR}/venv/bin/python3" -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")"

    cat > "${APP_DIR}/backend/.env" <<ENVEOF
DB_HOST=127.0.0.1
DB_PORT=5433
DB_NAME=postgres
DB_USER=postgres
DB_PASSWORD=${PG_PASSWORD}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
COOKIE_NAME=access_token
PUBLIC_DB_HOST=${PUBLIC_DB_HOST}
PUBLIC_DB_PORT=5432
POOLING_ENABLED=true
PGBOUNCER_HOST=127.0.0.1
PGBOUNCER_PORT=6432
POOL_MODE=transaction
PGBOUNCER_MAX_CLIENT_CONN=2000
PGBOUNCER_DEFAULT_POOL_SIZE=80
PGBOUNCER_MIN_POOL_SIZE=20
PGBOUNCER_RESERVE_POOL_SIZE=40
PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC=5
SQL_PROXY_LISTEN_BACKLOG=4096
PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC=120
PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC=120
PGBOUNCER_SERVER_LOGIN_RETRY_SEC=15
HAPROXY_MAXCONN=4000
HAPROXY_TIMEOUT_CONNECT=15s
HAPROXY_TIMEOUT_CLIENT=5m
HAPROXY_TIMEOUT_SERVER=5m
HAPROXY_TIMEOUT_QUEUE=90s
ALLOWED_ORIGINS=${ALLOWED_ORIGINS}
COOKIE_SECURE=${COOKIE_SECURE}
CSRF_COOKIE_NAME=csrf_token
CSRF_HEADER_NAME=x-csrf-token
LOGIN_RATE_LIMIT=8
LOGIN_RATE_WINDOW_SEC=300
SESSION_TTL_SEC=86400
TRUSTED_PROXY=true
ALLOWED_PORTS=22,80,443,5432
FIREWALL_BACKEND=auto
ENCRYPTION_KEY=${encryption_key}
ENVEOF

    chmod 600 "${APP_DIR}/backend/.env"
}

configure_sql_stack() {
    log "[7/11] Configurando HAProxy + PgBouncer..."
    chmod +x "${APP_DIR}/server/configure_sql_proxy.sh"
    bash "${APP_DIR}/server/configure_sql_proxy.sh" "${APP_DIR}/backend/.env"
    "${APP_DIR}/venv/bin/python3" "${APP_DIR}/server/sync_pgbouncer_auth.py" --env-file "${APP_DIR}/backend/.env"
}

configure_systemd_service() {
    log "[8/11] Configurando servicio systemd..."
    cat > /etc/systemd/system/pg_manager.service <<SVCEOF
[Unit]
Description=THL SQL Manager Web App
After=network.target postgresql.service

[Service]
User=root
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${APP_DIR}/backend/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable --now pg_manager
}

configure_nginx() {
    log "[9/11] Configurando Nginx..."
    mkdir -p /etc/nginx/conf.d

    if [ -d /etc/nginx/sites-enabled ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    rm -f "${NGINX_CONF_FILE}"

    if [ "${USE_DOMAIN}" = "true" ]; then
        cat > "${NGINX_CONF_FILE}" <<NGEOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
NGEOF
        nginx -t
        systemctl reload nginx

        pkg_install_optional certbot python3-certbot-nginx || true

        if command -v certbot >/dev/null 2>&1; then
            certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos \
                --register-unsafely-without-email --redirect || {
                warn "Certbot fallo. Verifica DNS de ${DOMAIN} y reintenta manualmente."
            }
        else
            warn "Certbot no esta disponible. Se omite TLS automatico."
        fi
    else
        cat > "${NGINX_CONF_FILE}" <<NGEOF
server {
    listen ${WEB_PORT};
    server_name _;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()";

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
NGEOF
        nginx -t
        systemctl reload nginx
    fi
}

configure_firewall() {
    log "[10/11] Configurando firewall (${FIREWALL_BACKEND})..."
    if [ "${FIREWALL_BACKEND}" = "ufw" ]; then
        ufw allow 22/tcp >/dev/null 2>&1 || true
        if [ "${USE_DOMAIN}" = "true" ]; then
            ufw allow 80/tcp >/dev/null 2>&1 || true
            ufw allow 443/tcp >/dev/null 2>&1 || true
        else
            ufw allow "${WEB_PORT}/tcp" >/dev/null 2>&1 || true
        fi
        printf "y\n" | ufw enable >/dev/null 2>&1 || true
        return
    fi

    systemctl enable --now firewalld >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
    if [ "${USE_DOMAIN}" = "true" ]; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
    else
        firewall-cmd --permanent --add-port="${WEB_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    firewall-cmd --reload >/dev/null 2>&1 || true
}

configure_watchdog() {
    log "[11/11] Configurando watchdog..."
    cp "${APP_DIR}/server/pg_manager_watchdog.sh" /usr/local/bin/pg_manager_watchdog.sh
    chmod +x /usr/local/bin/pg_manager_watchdog.sh

    (crontab -l 2>/dev/null | grep -q "pg_manager_watchdog.sh") || \
        (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/pg_manager_watchdog.sh") | crontab -
}

final_report() {
    local services
    services="$(systemctl is-active postgresql pgbouncer haproxy pg_manager nginx 2>/dev/null || true)"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Instalacion completada${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "Panel:          ${APP_URL}"
    echo "Usuario admin:  ${ADMIN_USERNAME}"
    echo "Firewall:       ${FIREWALL_BACKEND}"
    echo "Servicios:      ${services}"
    echo "Credenciales:   ${APP_DIR}/backend/.env"
    echo "Logs app:       journalctl -u pg_manager -f"
    echo "Health SQL:     ss -ltn '( sport = :5432 or sport = :6432 or sport = :5433 )'"
    echo -e "${GREEN}========================================${NC}"
}

main() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  THL SQL - Instalador Multi-Distro${NC}"
    echo -e "${CYAN}========================================${NC}"

    validate_install_settings
    require_root
    init_install_logging
    require_systemd
    detect_os
    ensure_repo_source
    install_prerequisites
    collect_input
    show_summary
    configure_dns
    configure_postgres_service
    deploy_app
    setup_python_env
    write_env_file
    configure_sql_stack
    configure_systemd_service
    configure_nginx
    configure_firewall
    configure_watchdog
    final_report
}

main "$@"
