#!/usr/bin/env bash
set -euo pipefail

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

find_pg_hba() {
    find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1 || true
}

detect_active_postgres_port() {
    local candidate
    for candidate in "${POSTGRES_INTERNAL_PORT}" "5432" "5433"; do
        if su - postgres -c "psql -h 127.0.0.1 -p \"${candidate}\" -Atqc \"select 1\"" >/dev/null 2>&1; then
            echo "${candidate}"
            return 0
        fi
    done

    if su - postgres -c "psql -Atqc \"show port\"" >/dev/null 2>&1; then
        su - postgres -c "psql -Atqc \"show port\"" | head -1
        return 0
    fi

    return 1
}

wait_for_postgres_port() {
    local port="$1"
    local retries="${2:-45}"
    local i

    for i in $(seq 1 "${retries}"); do
        if command -v pg_isready >/dev/null 2>&1; then
            if su - postgres -c "pg_isready -h 127.0.0.1 -p \"${port}\"" >/dev/null 2>&1; then
                return 0
            fi
        else
            if su - postgres -c "psql -h 127.0.0.1 -p \"${port}\" -Atqc \"select 1\"" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 1
    done

    return 1
}

run_psql_as_postgres() {
    local sql="$1"
    local port="$2"
    su - postgres -c "psql -h 127.0.0.1 -p \"${port}\" -v ON_ERROR_STOP=1 -c \"${sql}\"" >/dev/null
}

show_setting_or_na() {
    local field="$1"
    local value
    if value="$(su - postgres -c "psql -h 127.0.0.1 -p \"${POSTGRES_INTERNAL_PORT}\" -Atqc \"show ${field};\"" 2>/dev/null)"; then
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
fi

log "Configurando PostgreSQL interno en ${POSTGRES_LISTEN_ADDRESSES}:${POSTGRES_INTERNAL_PORT}"
log "Ajustando timeouts y capacidad para usar PgBouncer"

CURRENT_POSTGRES_PORT="$(detect_active_postgres_port || true)"
if [ -z "${CURRENT_POSTGRES_PORT}" ]; then
    warn "No se pudo detectar puerto activo de PostgreSQL."
    systemctl status postgresql --no-pager -l || true
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

systemctl restart postgresql

if ! wait_for_postgres_port "${POSTGRES_INTERNAL_PORT}" 45; then
    warn "PostgreSQL no quedo disponible en puerto ${POSTGRES_INTERNAL_PORT}."
    systemctl status postgresql --no-pager -l || true
    journalctl -u postgresql --no-pager -n 80 || true
    exit 1
fi

show_setting_or_na port
show_setting_or_na listen_addresses
show_setting_or_na idle_session_timeout
log "PostgreSQL actualizado."
