#!/bin/bash
set -e

# ============================================================
# Script de ACTUALIZACION para VPS ya instalado
# Uso: ssh root@servidor "cd /var/www/pg_manager && git pull && bash deploy_remote.sh"
# Para instalacion nueva usar: install.sh
# ============================================================

APP_DIR="/var/www/pg_manager"

echo "Actualizando dependencias..."
cd "$APP_DIR"
source venv/bin/activate
pip install -q -r backend/requirements.txt

echo "Reinstalando servicio..."
cp server/pg_manager.service /etc/systemd/system/pg_manager.service 2>/dev/null || true

echo "Actualizando watchdog..."
cp server/pg_manager_watchdog.sh /usr/local/bin/pg_manager_watchdog.sh 2>/dev/null || true
chmod +x /usr/local/bin/pg_manager_watchdog.sh 2>/dev/null || true

systemctl daemon-reload
systemctl restart pg_manager

echo "Update complete!"
