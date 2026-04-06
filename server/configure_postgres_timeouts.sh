#!/bin/bash
set -euo pipefail

# Aplica timeouts persistentes de PostgreSQL para cerrar sesiones inactivas.
# Usa ALTER SYSTEM para que sobreviva reinicios y updates.

IDLE_SESSION_TIMEOUT="${IDLE_SESSION_TIMEOUT:-60s}"

echo "Configurando PostgreSQL: idle_session_timeout=${IDLE_SESSION_TIMEOUT}"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET idle_session_timeout = '${IDLE_SESSION_TIMEOUT}';
SQL

systemctl restart postgresql

sudo -u postgres psql -Atqc "show idle_session_timeout;"

echo "PostgreSQL actualizado."
