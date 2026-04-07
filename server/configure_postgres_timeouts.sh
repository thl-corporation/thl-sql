#!/usr/bin/env bash
set -euo pipefail

# Ajusta PostgreSQL para operar detras de PgBouncer y mantiene los cambios persistentes.

POSTGRES_INTERNAL_PORT="${POSTGRES_INTERNAL_PORT:-5433}"
POSTGRES_LISTEN_ADDRESSES="${POSTGRES_LISTEN_ADDRESSES:-127.0.0.1}"
IDLE_SESSION_TIMEOUT="${IDLE_SESSION_TIMEOUT:-60s}"
IDLE_IN_TX_TIMEOUT="${IDLE_IN_TX_TIMEOUT:-30s}"
POSTGRES_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-250}"
SUPERUSER_RESERVED_CONNECTIONS="${SUPERUSER_RESERVED_CONNECTIONS:-10}"

find_pg_hba() {
    find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1 || true
}

run_psql_as_postgres() {
    local sql="$1"
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"${sql}\"" >/dev/null
}

run_psql_show() {
    local field="$1"
    su - postgres -c "psql -p \"${POSTGRES_INTERNAL_PORT}\" -Atqc \"show ${field};\"" || true
}

PG_HBA="$(find_pg_hba)"
if [ -n "${PG_HBA}" ] && [ -f "${PG_HBA}" ]; then
    sed -i "s/^host all all 127\\.0\\.0\\.1\\/32 scram-sha-256$/host all postgres 127.0.0.1\\/32 scram-sha-256/" "${PG_HBA}" || true
    if ! grep -q "^host all postgres 127.0.0.1/32 scram-sha-256$" "${PG_HBA}"; then
        echo "host all postgres 127.0.0.1/32 scram-sha-256" >> "${PG_HBA}"
    fi
fi

echo "Configurando PostgreSQL interno en ${POSTGRES_LISTEN_ADDRESSES}:${POSTGRES_INTERNAL_PORT}"
echo "Ajustando timeouts y capacidad para usar PgBouncer"

run_psql_as_postgres "ALTER SYSTEM SET port = '${POSTGRES_INTERNAL_PORT}';"
run_psql_as_postgres "ALTER SYSTEM SET listen_addresses = '${POSTGRES_LISTEN_ADDRESSES}';"
run_psql_as_postgres "ALTER SYSTEM SET idle_session_timeout = '${IDLE_SESSION_TIMEOUT}';"
run_psql_as_postgres "ALTER SYSTEM SET idle_in_transaction_session_timeout = '${IDLE_IN_TX_TIMEOUT}';"
run_psql_as_postgres "ALTER SYSTEM SET max_connections = '${POSTGRES_MAX_CONNECTIONS}';"
run_psql_as_postgres "ALTER SYSTEM SET superuser_reserved_connections = '${SUPERUSER_RESERVED_CONNECTIONS}';"
run_psql_as_postgres "ALTER SYSTEM SET password_encryption = 'scram-sha-256';"

systemctl restart postgresql

echo "port=$(run_psql_show port)"
echo "listen_addresses=$(run_psql_show listen_addresses)"
echo "idle_session_timeout=$(run_psql_show idle_session_timeout)"
echo "PostgreSQL actualizado."
