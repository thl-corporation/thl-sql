#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

# Ajusta PostgreSQL para operar detras de PgBouncer y mantiene los cambios persistentes.

POSTGRES_INTERNAL_PORT="${POSTGRES_INTERNAL_PORT:-5433}"
POSTGRES_LISTEN_ADDRESSES="${POSTGRES_LISTEN_ADDRESSES:-127.0.0.1}"
IDLE_SESSION_TIMEOUT="${IDLE_SESSION_TIMEOUT:-60s}"
IDLE_IN_TX_TIMEOUT="${IDLE_IN_TX_TIMEOUT:-30s}"
POSTGRES_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-250}"
SUPERUSER_RESERVED_CONNECTIONS="${SUPERUSER_RESERVED_CONNECTIONS:-10}"

log() {
    echo "$*"
}

warn() {
    echo "WARN: $*" >&2
}

run_as_postgres() {
    local cmd="$1"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- sh -c "${cmd}"
        return
    fi
    su -s /bin/sh postgres -c "${cmd}"
}

find_pg_hba() {
    find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1 || true
}

find_pg_conf() {
    find /etc/postgresql /var/lib/pgsql -name postgresql.conf 2>/dev/null | head -1 || true
}

detect_cluster_version() {
    if command -v pg_lsclusters >/dev/null 2>&1; then
        pg_lsclusters --no-header 2>/dev/null | awk '$2=="main" {print $1; exit}'
        return
    fi

    if [ -f /var/lib/pgsql/data/PG_VERSION ]; then
        head -1 /var/lib/pgsql/data/PG_VERSION 2>/dev/null || true
    fi
}

postgres_service_unit() {
    local cluster_version
    cluster_version="$(detect_cluster_version || true)"
    if [ -n "${cluster_version}" ] && command -v pg_lsclusters >/dev/null 2>&1; then
        echo "postgresql@${cluster_version}-main"
        return
    fi
    echo "postgresql"
}

restart_postgres_runtime() {
    local cluster_version
    cluster_version="$(detect_cluster_version || true)"

    if [ -n "${cluster_version}" ] && command -v pg_ctlcluster >/dev/null 2>&1; then
        pg_ctlcluster "${cluster_version}" main restart >/dev/null 2>&1 || true
        return
    fi

    systemctl restart "$(postgres_service_unit)" >/dev/null 2>&1 || systemctl restart postgresql >/dev/null 2>&1 || true
}

reload_postgres_runtime() {
    local cluster_version
    cluster_version="$(detect_cluster_version || true)"

    if [ -n "${cluster_version}" ] && command -v pg_ctlcluster >/dev/null 2>&1; then
        pg_ctlcluster "${cluster_version}" main reload >/dev/null 2>&1 || \
            pg_ctlcluster "${cluster_version}" main restart >/dev/null 2>&1 || true
        return
    fi

    systemctl reload "$(postgres_service_unit)" >/dev/null 2>&1 || systemctl restart postgresql >/dev/null 2>&1 || true
}

show_postgres_diagnostics() {
    local unit cluster_version pg_log pg_hba pg_conf
    unit="$(postgres_service_unit)"
    cluster_version="$(detect_cluster_version || true)"

    echo "--- systemctl status ${unit} ---"
    systemctl status "${unit}" --no-pager -l 2>/dev/null || true
    echo "--- journalctl -xeu ${unit} (last 100) ---"
    journalctl -xeu "${unit}" --no-pager -n 100 2>/dev/null || true

    if command -v pg_lsclusters >/dev/null 2>&1; then
        echo "[pg_lsclusters]"
        pg_lsclusters || true
    fi

    echo "[Ports]"
    ss -tlnp 2>/dev/null | grep -E "5432|${POSTGRES_INTERNAL_PORT}|6432|8000" || true

    if [ -n "${cluster_version}" ]; then
        pg_log="/var/log/postgresql/postgresql-${cluster_version}-main.log"
        if [ -f "${pg_log}" ]; then
            echo "--- ${pg_log} (last 200) ---"
            tail -n 200 "${pg_log}" || true
        fi
    fi

    pg_hba="$(find_pg_hba)"
    pg_conf="$(find_pg_conf)"
    if [ -n "${pg_hba}" ] && [ -f "${pg_hba}" ]; then
        echo "--- ${pg_hba} ---"
        cat "${pg_hba}" || true
    fi
    if [ -n "${pg_conf}" ] && [ -f "${pg_conf}" ]; then
        echo "--- ${pg_conf} ---"
        cat "${pg_conf}" || true
    fi
}

detect_active_postgres_port() {
    local retries="${1:-60}"
    local sleep_sec="${2:-1}"
    local attempt candidate cluster_port

    for attempt in $(seq 1 "${retries}"); do
        if command -v pg_lsclusters >/dev/null 2>&1; then
            cluster_port="$(pg_lsclusters --no-header 2>/dev/null | awk '$2=="main" && $4=="online" && $3 ~ /^[0-9]+$/ {print $3; exit}')"
            if [ -n "${cluster_port}" ]; then
                echo "${cluster_port}"
                return 0
            fi

            cluster_port="$(pg_lsclusters --no-header 2>/dev/null | awk '$4=="online" && $3 ~ /^[0-9]+$/ {print $3; exit}')"
            if [ -n "${cluster_port}" ]; then
                echo "${cluster_port}"
                return 0
            fi
        fi

        for candidate in "${POSTGRES_INTERNAL_PORT}" "5432" "5433" "5434"; do
            if run_as_postgres "psql -d postgres -p \"${candidate}\" -Atqc \"select 1\"" >/dev/null 2>&1; then
                echo "${candidate}"
                return 0
            fi
        done

        if run_as_postgres "psql -d postgres -Atqc \"show port\"" >/dev/null 2>&1; then
            run_as_postgres "psql -d postgres -Atqc \"show port\"" | head -1
            return 0
        fi

        sleep "${sleep_sec}"
    done

    return 1
}

wait_for_postgres_port() {
    local port="$1"
    local retries="${2:-90}"
    local i

    for i in $(seq 1 "${retries}"); do
        if command -v pg_isready >/dev/null 2>&1; then
            if run_as_postgres "pg_isready -q -p \"${port}\"" >/dev/null 2>&1; then
                return 0
            fi
        fi

        if run_as_postgres "psql -d postgres -p \"${port}\" -Atqc \"select 1\"" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    return 1
}

run_psql_as_postgres() {
    local sql="$1"
    local port="$2"
    run_as_postgres "psql -d postgres -p \"${port}\" -v ON_ERROR_STOP=1 -c \"${sql}\"" >/dev/null
}

show_setting_or_na() {
    local field="$1"
    local value
    if value="$(run_as_postgres "psql -d postgres -p \"${POSTGRES_INTERNAL_PORT}\" -Atqc \"show ${field};\"" 2>/dev/null)"; then
        echo "${field}=${value}"
        return
    fi

    warn "No se pudo consultar ${field} en ${POSTGRES_INTERNAL_PORT}."
    echo "${field}=n/a"
}

PG_HBA="$(find_pg_hba)"
if [ -n "${PG_HBA}" ] && [ -f "${PG_HBA}" ]; then
    sed -i "s/^host all all 127\\.0\\.0\\.1\\/32 scram-sha-256$/host all postgres 127.0.0.1\\/32 scram-sha-256/" "${PG_HBA}" || true
    if ! grep -q "^host all postgres 127.0.0.1/32 scram-sha-256$" "${PG_HBA}"; then
        echo "host all postgres 127.0.0.1/32 scram-sha-256" >> "${PG_HBA}"
    fi
    reload_postgres_runtime
fi

log "Configurando PostgreSQL interno en ${POSTGRES_LISTEN_ADDRESSES}:${POSTGRES_INTERNAL_PORT}"
log "Ajustando timeouts y capacidad para usar PgBouncer"

INITIAL_WAIT_PORT="${POSTGRES_INTERNAL_PORT}"
if command -v pg_lsclusters >/dev/null 2>&1; then
    CLUSTER_PORT="$(pg_lsclusters --no-header 2>/dev/null | awk '$2=="main" && $3 ~ /^[0-9]+$/ {print $3; exit}')"
    if [ -n "${CLUSTER_PORT}" ]; then
        INITIAL_WAIT_PORT="${CLUSTER_PORT}"
    fi
fi

if ! wait_for_postgres_port "${INITIAL_WAIT_PORT}" 60; then
    warn "Puerto ${INITIAL_WAIT_PORT} aun no responde. Se intentara detectar puertos alternativos."
fi

CURRENT_POSTGRES_PORT="$(detect_active_postgres_port 60 1 || true)"
if [ -z "${CURRENT_POSTGRES_PORT}" ]; then
    warn "No se pudo detectar puerto activo de PostgreSQL."
    show_postgres_diagnostics
    exit 1
fi
log "Puerto PostgreSQL detectado: ${CURRENT_POSTGRES_PORT}"

run_psql_as_postgres "ALTER SYSTEM SET port = '${POSTGRES_INTERNAL_PORT}';" "${CURRENT_POSTGRES_PORT}"
run_psql_as_postgres "ALTER SYSTEM SET listen_addresses = '${POSTGRES_LISTEN_ADDRESSES}';" "${CURRENT_POSTGRES_PORT}"
run_psql_as_postgres "ALTER SYSTEM SET idle_session_timeout = '${IDLE_SESSION_TIMEOUT}';" "${CURRENT_POSTGRES_PORT}"
run_psql_as_postgres "ALTER SYSTEM SET idle_in_transaction_session_timeout = '${IDLE_IN_TX_TIMEOUT}';" "${CURRENT_POSTGRES_PORT}"
run_psql_as_postgres "ALTER SYSTEM SET max_connections = '${POSTGRES_MAX_CONNECTIONS}';" "${CURRENT_POSTGRES_PORT}"
run_psql_as_postgres "ALTER SYSTEM SET superuser_reserved_connections = '${SUPERUSER_RESERVED_CONNECTIONS}';" "${CURRENT_POSTGRES_PORT}"
run_psql_as_postgres "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" "${CURRENT_POSTGRES_PORT}"

restart_postgres_runtime

if ! wait_for_postgres_port "${POSTGRES_INTERNAL_PORT}" 90; then
    warn "PostgreSQL no quedo disponible en puerto ${POSTGRES_INTERNAL_PORT}."
    show_postgres_diagnostics
    exit 1
fi

show_setting_or_na port
show_setting_or_na listen_addresses
show_setting_or_na idle_session_timeout
log "PostgreSQL actualizado."
