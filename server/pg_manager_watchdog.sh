#!/bin/bash
# Watchdog: verifica que pg_manager, postgresql, pgbouncer y haproxy esten activos.
# Instalar en crontab: * * * * * /usr/local/bin/pg_manager_watchdog.sh

LOG="/var/log/pg_manager_watchdog.log"

if ! systemctl is-active --quiet postgresql; then
    echo "$(date) - PostgreSQL caido, reiniciando..." >> "$LOG"
    systemctl restart postgresql
fi

if ! systemctl is-active --quiet pg_manager; then
    echo "$(date) - pg_manager caido, reiniciando..." >> "$LOG"
    systemctl restart pg_manager
fi

if ! systemctl is-active --quiet pgbouncer; then
    echo "$(date) - pgbouncer caido, reiniciando..." >> "$LOG"
    systemctl restart pgbouncer
fi

if ! systemctl is-active --quiet haproxy; then
    echo "$(date) - haproxy caido, reiniciando..." >> "$LOG"
    systemctl restart haproxy
fi

# Health check HTTP
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8000/login 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
    echo "$(date) - pg_manager no responde (HTTP $HTTP_CODE), reiniciando..." >> "$LOG"
    systemctl restart pg_manager
fi

if ! timeout 5 bash -c "</dev/tcp/127.0.0.1/5432" 2>/dev/null; then
    echo "$(date) - SQL proxy no responde en 127.0.0.1:5432, reiniciando haproxy y pgbouncer..." >> "$LOG"
    systemctl restart pgbouncer
    systemctl restart haproxy
fi
