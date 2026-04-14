#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

APP_DIR="${APP_DIR:-/var/www/pg_manager}"
ENV_FILE="${1:-${APP_DIR}/backend/.env}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OS_FAMILY=""
PKG_TOOL=""

wait_for_tcp_port() {
    local port="$1"
    local retries="${2:-90}"
    local i

    for i in $(seq 1 "${retries}"); do
        if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|\\]|:)${port}$"; then
            return 0
        fi
        sleep 1
    done

    return 1
}

show_unit_logs() {
    local unit="$1"
    echo "--- systemctl status ${unit} ---"
    systemctl status "${unit}" --no-pager -l 2>/dev/null || true
    echo "--- journalctl -u ${unit} (last 120) ---"
    journalctl -u "${unit}" --no-pager -n 120 2>/dev/null || true
}

read_env_value() {
    local key="$1"
    if [ ! -f "${ENV_FILE}" ]; then
        return 0
    fi
    grep -m1 "^${key}=" "${ENV_FILE}" | cut -d'=' -f2- || true
}

detect_os() {
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" =~ (debian|ubuntu) ]] || [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
        OS_FAMILY="debian"
        PKG_TOOL="apt"
        return
    fi
    if [[ "${ID:-}" =~ (rhel|rocky|almalinux|centos|fedora) ]] || [[ "${ID_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
        OS_FAMILY="rhel"
        if command -v dnf >/dev/null 2>&1; then
            PKG_TOOL="dnf"
        else
            PKG_TOOL="yum"
        fi
        return
    fi
    echo "Distribucion no soportada para configure_sql_proxy.sh"
    exit 1
}

pkg_install() {
    if [ "${PKG_TOOL}" = "apt" ]; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pgbouncer haproxy
        return
    fi
    if [ "${PKG_TOOL}" = "dnf" ]; then
        dnf install -y epel-release >/dev/null 2>&1 || true
        dnf install -y pgbouncer haproxy >/dev/null
        return
    fi
    yum install -y pgbouncer haproxy >/dev/null
}

PUBLIC_DB_PORT="${PUBLIC_DB_PORT:-$(read_env_value PUBLIC_DB_PORT)}"
PUBLIC_DB_PORT="${PUBLIC_DB_PORT:-5432}"
POSTGRES_PORT="${DB_PORT:-$(read_env_value DB_PORT)}"
POSTGRES_PORT="${POSTGRES_PORT:-5433}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-$(read_env_value PGBOUNCER_PORT)}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
POOL_MODE="${POOL_MODE:-$(read_env_value POOL_MODE)}"
POOL_MODE="${POOL_MODE:-transaction}"
PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-$(read_env_value PGBOUNCER_MAX_CLIENT_CONN)}"
PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-2000}"
PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-$(read_env_value PGBOUNCER_DEFAULT_POOL_SIZE)}"
PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-80}"
PGBOUNCER_MIN_POOL_SIZE="${PGBOUNCER_MIN_POOL_SIZE:-$(read_env_value PGBOUNCER_MIN_POOL_SIZE)}"
PGBOUNCER_MIN_POOL_SIZE="${PGBOUNCER_MIN_POOL_SIZE:-20}"
PGBOUNCER_RESERVE_POOL_SIZE="${PGBOUNCER_RESERVE_POOL_SIZE:-$(read_env_value PGBOUNCER_RESERVE_POOL_SIZE)}"
PGBOUNCER_RESERVE_POOL_SIZE="${PGBOUNCER_RESERVE_POOL_SIZE:-40}"
PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC="${PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC:-$(read_env_value PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC)}"
PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC="${PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC:-5}"
SQL_PROXY_LISTEN_BACKLOG="${SQL_PROXY_LISTEN_BACKLOG:-$(read_env_value SQL_PROXY_LISTEN_BACKLOG)}"
SQL_PROXY_LISTEN_BACKLOG="${SQL_PROXY_LISTEN_BACKLOG:-4096}"
PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC="${PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC:-$(read_env_value PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC)}"
PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC="${PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC:-120}"
PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC="${PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC:-$(read_env_value PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC)}"
PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC="${PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC:-120}"
PGBOUNCER_SERVER_LOGIN_RETRY_SEC="${PGBOUNCER_SERVER_LOGIN_RETRY_SEC:-$(read_env_value PGBOUNCER_SERVER_LOGIN_RETRY_SEC)}"
PGBOUNCER_SERVER_LOGIN_RETRY_SEC="${PGBOUNCER_SERVER_LOGIN_RETRY_SEC:-15}"
HAPROXY_MAXCONN="${HAPROXY_MAXCONN:-$(read_env_value HAPROXY_MAXCONN)}"
HAPROXY_MAXCONN="${HAPROXY_MAXCONN:-4000}"
HAPROXY_TIMEOUT_CONNECT="${HAPROXY_TIMEOUT_CONNECT:-$(read_env_value HAPROXY_TIMEOUT_CONNECT)}"
HAPROXY_TIMEOUT_CONNECT="${HAPROXY_TIMEOUT_CONNECT:-15s}"
HAPROXY_TIMEOUT_CLIENT="${HAPROXY_TIMEOUT_CLIENT:-$(read_env_value HAPROXY_TIMEOUT_CLIENT)}"
HAPROXY_TIMEOUT_CLIENT="${HAPROXY_TIMEOUT_CLIENT:-5m}"
HAPROXY_TIMEOUT_SERVER="${HAPROXY_TIMEOUT_SERVER:-$(read_env_value HAPROXY_TIMEOUT_SERVER)}"
HAPROXY_TIMEOUT_SERVER="${HAPROXY_TIMEOUT_SERVER:-5m}"
HAPROXY_TIMEOUT_QUEUE="${HAPROXY_TIMEOUT_QUEUE:-$(read_env_value HAPROXY_TIMEOUT_QUEUE)}"
HAPROXY_TIMEOUT_QUEUE="${HAPROXY_TIMEOUT_QUEUE:-90s}"
DB_USER_FROM_ENV="$(read_env_value DB_USER)"
PGBOUNCER_ADMIN_USERS="${PGBOUNCER_ADMIN_USERS:-$(read_env_value PGBOUNCER_ADMIN_USERS)}"
PGBOUNCER_ADMIN_USERS="${PGBOUNCER_ADMIN_USERS:-${DB_USER_FROM_ENV:-postgres}}"
PGBOUNCER_STATS_USERS="${PGBOUNCER_STATS_USERS:-$(read_env_value PGBOUNCER_STATS_USERS)}"
PGBOUNCER_STATS_USERS="${PGBOUNCER_STATS_USERS:-${PGBOUNCER_ADMIN_USERS}}"
PGBOUNCER_AUTH_FILE="${PGBOUNCER_AUTH_FILE:-$(read_env_value PGBOUNCER_AUTH_FILE)}"
PGBOUNCER_AUTH_FILE="${PGBOUNCER_AUTH_FILE:-/etc/pgbouncer/userlist.txt}"

render_template() {
    local template_path="$1"
    sed \
        -e "s|__PUBLIC_PORT__|${PUBLIC_DB_PORT}|g" \
        -e "s|__POSTGRES_PORT__|${POSTGRES_PORT}|g" \
        -e "s|__PGBOUNCER_PORT__|${PGBOUNCER_PORT}|g" \
        -e "s|__POOL_MODE__|${POOL_MODE}|g" \
        -e "s|__MAX_CLIENT_CONN__|${PGBOUNCER_MAX_CLIENT_CONN}|g" \
        -e "s|__DEFAULT_POOL_SIZE__|${PGBOUNCER_DEFAULT_POOL_SIZE}|g" \
        -e "s|__MIN_POOL_SIZE__|${PGBOUNCER_MIN_POOL_SIZE}|g" \
        -e "s|__RESERVE_POOL_SIZE__|${PGBOUNCER_RESERVE_POOL_SIZE}|g" \
        -e "s|__RESERVE_POOL_TIMEOUT_SEC__|${PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC}|g" \
        -e "s|__LISTEN_BACKLOG__|${SQL_PROXY_LISTEN_BACKLOG}|g" \
        -e "s|__CLIENT_LOGIN_TIMEOUT_SEC__|${PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC}|g" \
        -e "s|__QUERY_WAIT_TIMEOUT_SEC__|${PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC}|g" \
        -e "s|__SERVER_LOGIN_RETRY_SEC__|${PGBOUNCER_SERVER_LOGIN_RETRY_SEC}|g" \
        -e "s|__HAPROXY_MAXCONN__|${HAPROXY_MAXCONN}|g" \
        -e "s|__TIMEOUT_CONNECT__|${HAPROXY_TIMEOUT_CONNECT}|g" \
        -e "s|__TIMEOUT_CLIENT__|${HAPROXY_TIMEOUT_CLIENT}|g" \
        -e "s|__TIMEOUT_SERVER__|${HAPROXY_TIMEOUT_SERVER}|g" \
        -e "s|__TIMEOUT_QUEUE__|${HAPROXY_TIMEOUT_QUEUE}|g" \
        -e "s|__ADMIN_USERS__|${PGBOUNCER_ADMIN_USERS}|g" \
        -e "s|__STATS_USERS__|${PGBOUNCER_STATS_USERS}|g" \
        -e "s|__AUTH_FILE__|${PGBOUNCER_AUTH_FILE}|g" \
        "${template_path}"
}

echo "Instalando stack de pooling SQL (PgBouncer + HAProxy)..."
detect_os
pkg_install

if ! id -u pgbouncer >/dev/null 2>&1; then
    useradd --system --home /var/lib/pgbouncer --create-home --shell /usr/sbin/nologin pgbouncer || true
fi

mkdir -p /etc/pgbouncer
touch "${PGBOUNCER_AUTH_FILE}"
chown postgres:postgres "${PGBOUNCER_AUTH_FILE}" || true
chmod 640 "${PGBOUNCER_AUTH_FILE}"

if [ -f /etc/default/pgbouncer ]; then
    sed -i "s/^START=.*/START=1/" /etc/default/pgbouncer || true
fi
if [ -f /etc/default/haproxy ]; then
    sed -i "s/^ENABLED=.*/ENABLED=1/" /etc/default/haproxy || true
fi

render_template "${SCRIPT_DIR}/pgbouncer.ini.template" > /etc/pgbouncer/pgbouncer.ini
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini || true
chmod 640 /etc/pgbouncer/pgbouncer.ini

render_template "${SCRIPT_DIR}/haproxy.cfg.template" > /etc/haproxy/haproxy.cfg
chown root:root /etc/haproxy/haproxy.cfg
chmod 644 /etc/haproxy/haproxy.cfg

if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -f /etc/haproxy/haproxy.cfg
fi

systemctl daemon-reload
systemctl enable --now pgbouncer haproxy
systemctl restart pgbouncer
systemctl restart haproxy

if ! wait_for_tcp_port "${PGBOUNCER_PORT}" 90; then
    show_unit_logs pgbouncer
    echo "PgBouncer no quedo escuchando en ${PGBOUNCER_PORT}" >&2
    exit 1
fi

if ! wait_for_tcp_port "${PUBLIC_DB_PORT}" 90; then
    show_unit_logs haproxy
    echo "HAProxy no quedo escuchando en ${PUBLIC_DB_PORT}" >&2
    exit 1
fi

echo "Stack SQL configurado:"
echo "  PostgreSQL interno: 127.0.0.1:${POSTGRES_PORT}"
echo "  PgBouncer interno:  127.0.0.1:${PGBOUNCER_PORT}"
echo "  HAProxy publico:    0.0.0.0:${PUBLIC_DB_PORT}"
