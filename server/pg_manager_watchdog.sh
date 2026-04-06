#!/bin/bash
# Watchdog: verifica que pg_manager y postgresql esten activos, los reinicia si no
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

# Health check HTTP
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8000/login 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
    echo "$(date) - pg_manager no responde (HTTP $HTTP_CODE), reiniciando..." >> "$LOG"
    systemctl restart pg_manager
fi
