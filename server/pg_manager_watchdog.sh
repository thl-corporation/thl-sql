#!/bin/bash
# Watchdog: verifica que pg_manager, postgresql, pgbouncer y haproxy esten activos.
# Instalar en crontab: * * * * * /usr/local/bin/pg_manager_watchdog.sh

LOG="/var/log/pg_manager_watchdog.log"
SERVICE_MANAGER="${SERVICE_MANAGER:-}"

is_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

detect_service_manager() {
    case "${SERVICE_MANAGER}" in
        systemd|service)
            return
            ;;
    esac

    if is_systemd_available; then
        SERVICE_MANAGER="systemd"
    else
        SERVICE_MANAGER="service"
    fi
}

service_action() {
    local action="$1"
    local service_name="$2"
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl "${action}" "${service_name}"
        return
    fi
    service "${service_name}" "${action}"
}

service_is_active() {
    local service_name="$1"
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl is-active --quiet "${service_name}"
        return
    fi
    service "${service_name}" status >/dev/null 2>&1
}

detect_service_manager

if ! service_is_active postgresql; then
    echo "$(date) - PostgreSQL caido, reiniciando..." >> "$LOG"
    service_action restart postgresql
fi

if ! service_is_active pg_manager; then
    echo "$(date) - pg_manager caido, reiniciando..." >> "$LOG"
    service_action restart pg_manager
fi

if ! service_is_active pgbouncer; then
    echo "$(date) - pgbouncer caido, reiniciando..." >> "$LOG"
    service_action restart pgbouncer
fi

if ! service_is_active haproxy; then
    echo "$(date) - haproxy caido, reiniciando..." >> "$LOG"
    service_action restart haproxy
fi

# Health check HTTP
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8000/login 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
    echo "$(date) - pg_manager no responde (HTTP $HTTP_CODE), reiniciando..." >> "$LOG"
    service_action restart pg_manager
fi

if ! timeout 5 bash -c "</dev/tcp/127.0.0.1/5432" 2>/dev/null; then
    echo "$(date) - SQL proxy no responde en 127.0.0.1:5432, reiniciando haproxy y pgbouncer..." >> "$LOG"
    service_action restart pgbouncer
    service_action restart haproxy
fi
