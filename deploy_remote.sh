#!/bin/bash
set -e

# ============================================================
# Script de ACTUALIZACION para VPS ya instalado
# Uso: ssh root@servidor "cd /var/www/pg_manager && git pull && bash deploy_remote.sh"
# Para instalacion nueva usar: install.sh
# ============================================================

APP_DIR="/var/www/pg_manager"

ensure_env_var() {
    local key="$1"
    local value="$2"
    local env_file="backend/.env"
    local tmp_file
    if grep -q "^${key}=" "${env_file}" 2>/dev/null; then
        tmp_file="$(mktemp "${env_file}.XXXXXX")"
        awk -v k="${key}" -v v="${value}" '{
            pos = index($0, "=")
            if (pos > 0 && substr($0, 1, pos - 1) == k) {
                print k "=" v
            } else {
                print
            }
        }' "${env_file}" > "${tmp_file}"
        mv "${tmp_file}" "${env_file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${env_file}"
    fi
}

echo "Actualizando dependencias..."
cd "$APP_DIR"
source venv/bin/activate
pip install -q -r backend/requirements.txt

echo "Asegurando variables de pooling en backend/.env..."
ensure_env_var "DB_PORT" "5433"
ensure_env_var "PUBLIC_DB_PORT" "5432"
ensure_env_var "POOLING_ENABLED" "true"
ensure_env_var "PGBOUNCER_HOST" "127.0.0.1"
ensure_env_var "PGBOUNCER_PORT" "6432"
ensure_env_var "POOL_MODE" "transaction"
ensure_env_var "PGBOUNCER_MAX_CLIENT_CONN" "2000"
ensure_env_var "PGBOUNCER_DEFAULT_POOL_SIZE" "80"
ensure_env_var "PGBOUNCER_MIN_POOL_SIZE" "20"
ensure_env_var "PGBOUNCER_RESERVE_POOL_SIZE" "40"
ensure_env_var "PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC" "5"
ensure_env_var "SQL_PROXY_LISTEN_BACKLOG" "4096"
ensure_env_var "PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC" "120"
ensure_env_var "PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC" "120"
ensure_env_var "PGBOUNCER_SERVER_LOGIN_RETRY_SEC" "15"
ensure_env_var "HAPROXY_MAXCONN" "4000"
ensure_env_var "HAPROXY_TIMEOUT_CONNECT" "15s"
ensure_env_var "HAPROXY_TIMEOUT_CLIENT" "5m"
ensure_env_var "HAPROXY_TIMEOUT_SERVER" "5m"
ensure_env_var "HAPROXY_TIMEOUT_QUEUE" "90s"

echo "Reinstalando servicio..."
cp server/pg_manager.service /etc/systemd/system/pg_manager.service 2>/dev/null || true

echo "Actualizando watchdog..."
cp server/pg_manager_watchdog.sh /usr/local/bin/pg_manager_watchdog.sh 2>/dev/null || true
chmod +x /usr/local/bin/pg_manager_watchdog.sh 2>/dev/null || true

echo "Actualizando configuracion de PostgreSQL..."
cp server/configure_postgres_timeouts.sh /usr/local/bin/configure_postgres_timeouts.sh 2>/dev/null || true
chmod +x /usr/local/bin/configure_postgres_timeouts.sh 2>/dev/null || true
/usr/local/bin/configure_postgres_timeouts.sh

echo "Configurando HAProxy + PgBouncer..."
chmod +x server/configure_sql_proxy.sh 2>/dev/null || true
bash server/configure_sql_proxy.sh backend/.env
venv/bin/python3 server/sync_pgbouncer_auth.py --env-file backend/.env

systemctl daemon-reload
systemctl restart pgbouncer
systemctl restart haproxy
systemctl restart pg_manager

echo "Update complete!"
