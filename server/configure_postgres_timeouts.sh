#!/bin/bash
set -euo pipefail

# Aplica parametros persistentes para operar PostgreSQL detras de PgBouncer.
# Usa ALTER SYSTEM para que sobreviva reinicios y updates.

POSTGRES_INTERNAL_PORT="${POSTGRES_INTERNAL_PORT:-5433}"
POSTGRES_LISTEN_ADDRESSES="${POSTGRES_LISTEN_ADDRESSES:-127.0.0.1}"
IDLE_SESSION_TIMEOUT="${IDLE_SESSION_TIMEOUT:-60s}"
IDLE_IN_TX_TIMEOUT="${IDLE_IN_TX_TIMEOUT:-30s}"
POSTGRES_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-250}"
SUPERUSER_RESERVED_CONNECTIONS="${SUPERUSER_RESERVED_CONNECTIONS:-10}"
PG_HBA=$(find /etc/postgresql -name pg_hba.conf | head -1)

if [ -n "${PG_HBA}" ] && [ -f "${PG_HBA}" ]; then
    sed -i "s/^host all all 127\\.0\\.0\\.1\\/32 scram-sha-256$/host all postgres 127.0.0.1\\/32 scram-sha-256/" "${PG_HBA}" || true
    if ! grep -q "^host all postgres 127.0.0.1/32 scram-sha-256$" "${PG_HBA}"; then
        echo "host all postgres 127.0.0.1/32 scram-sha-256" >> "${PG_HBA}"
    fi
fi

echo "Configurando PostgreSQL interno en ${POSTGRES_LISTEN_ADDRESSES}:${POSTGRES_INTERNAL_PORT}"
echo "Ajustando timeouts y capacidad para usar PgBouncer"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET port = '${POSTGRES_INTERNAL_PORT}';
ALTER SYSTEM SET listen_addresses = '${POSTGRES_LISTEN_ADDRESSES}';
ALTER SYSTEM SET idle_session_timeout = '${IDLE_SESSION_TIMEOUT}';
ALTER SYSTEM SET idle_in_transaction_session_timeout = '${IDLE_IN_TX_TIMEOUT}';
ALTER SYSTEM SET max_connections = '${POSTGRES_MAX_CONNECTIONS}';
ALTER SYSTEM SET superuser_reserved_connections = '${SUPERUSER_RESERVED_CONNECTIONS}';
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
SQL

systemctl restart postgresql

sudo -u postgres psql -p "${POSTGRES_INTERNAL_PORT}" -Atqc "show port;"
sudo -u postgres psql -p "${POSTGRES_INTERNAL_PORT}" -Atqc "show listen_addresses;"
sudo -u postgres psql -p "${POSTGRES_INTERNAL_PORT}" -Atqc "show idle_session_timeout;"

echo "PostgreSQL actualizado."
