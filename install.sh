#!/bin/bash
set -e

# ============================================================
# PostgreSQL Manager - Instalador interactivo para VPS nuevo
# Compatible con Ubuntu 22.04 / 24.04
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_DIR="/var/www/pg_manager"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  PostgreSQL Manager - Instalador${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# --- Verificar root ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: Ejecuta este script como root${NC}"
    exit 1
fi

# --- Detectar IP del servidor ---
SERVER_IP=$(curl -s --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')
echo -e "${GREEN}IP del servidor detectada: ${SERVER_IP}${NC}"
echo ""

# ============================================================
# 1. Datos de acceso al panel
# ============================================================
echo -e "${YELLOW}--- Configuracion del panel admin ---${NC}"

read -p "Usuario administrador [admin]: " ADMIN_USERNAME
ADMIN_USERNAME=${ADMIN_USERNAME:-admin}

while true; do
    read -s -p "Contrasena administrador: " ADMIN_PASSWORD
    echo ""
    if [ -z "$ADMIN_PASSWORD" ]; then
        echo -e "${RED}La contrasena no puede estar vacia${NC}"
        continue
    fi
    read -s -p "Confirmar contrasena: " ADMIN_PASSWORD_CONFIRM
    echo ""
    if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
        echo -e "${RED}Las contrasenas no coinciden${NC}"
        continue
    fi
    break
done

# ============================================================
# 2. URL o IP
# ============================================================
echo ""
echo -e "${YELLOW}--- Configuracion del dominio ---${NC}"
echo -e "Si tienes un dominio apuntando a este servidor, ingresalo."
echo -e "Si no, presiona Enter para usar la IP (${SERVER_IP}) con un puerto."
echo ""

read -p "Dominio (ej. sql.midominio.com) [dejar vacio para IP]: " DOMAIN

if [ -n "$DOMAIN" ]; then
    USE_DOMAIN=true
    APP_URL="https://${DOMAIN}"
    ALLOWED_ORIGINS="https://${DOMAIN}"
    COOKIE_SECURE=true
    WEB_PORT=443
    echo -e "${GREEN}Se usara: ${APP_URL}${NC}"
else
    USE_DOMAIN=false
    read -p "Puerto para el panel web [80]: " WEB_PORT
    WEB_PORT=${WEB_PORT:-80}
    APP_URL="http://${SERVER_IP}:${WEB_PORT}"
    ALLOWED_ORIGINS="http://${SERVER_IP}:${WEB_PORT},http://${SERVER_IP}"
    COOKIE_SECURE=false
    echo -e "${GREEN}Se usara: ${APP_URL}${NC}"
fi

# ============================================================
# 3. Contrasena PostgreSQL
# ============================================================
echo ""
echo -e "${YELLOW}--- Configuracion de PostgreSQL ---${NC}"

read -p "Contrasena para el usuario postgres [generar automaticamente]: " PG_PASSWORD
if [ -z "$PG_PASSWORD" ]; then
    PG_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
    echo -e "${GREEN}Contrasena generada: ${PG_PASSWORD}${NC}"
fi

# ============================================================
# 4. Confirmar
# ============================================================
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Resumen de instalacion${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  Admin user:     ${ADMIN_USERNAME}"
echo -e "  URL:            ${APP_URL}"
echo -e "  PostgreSQL pwd: ${PG_PASSWORD:0:5}..."
if [ "$USE_DOMAIN" = true ]; then
    echo -e "  SSL:            Certbot (Let's Encrypt)"
else
    echo -e "  SSL:            No (acceso por IP:${WEB_PORT})"
fi
echo -e "${CYAN}========================================${NC}"
echo ""

read -p "Continuar con la instalacion? [S/n]: " CONFIRM
CONFIRM=${CONFIRM:-S}
if [[ ! "$CONFIRM" =~ ^[SsYy]$ ]]; then
    echo "Instalacion cancelada."
    exit 0
fi

# ============================================================
# 5. Instalar dependencias del sistema
# ============================================================
echo ""
echo -e "${YELLOW}[1/8] Instalando dependencias del sistema...${NC}"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip nginx postgresql postgresql-contrib ufw curl git > /dev/null

# ============================================================
# 6. Configurar DNS
# ============================================================
echo -e "${YELLOW}[2/8] Configurando DNS...${NC}"
if ! grep -q "DNS=8.8.8.8" /etc/systemd/resolved.conf 2>/dev/null; then
    sed -i 's/#DNS=/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
    sed -i 's/#FallbackDNS=/FallbackDNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved || true
fi

# ============================================================
# 7. Configurar PostgreSQL
# ============================================================
echo -e "${YELLOW}[3/8] Configurando PostgreSQL...${NC}"

# Set password
su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${PG_PASSWORD}';\"" > /dev/null

# Listen on all interfaces
PG_CONF=$(find /etc/postgresql -name postgresql.conf | head -1)
PG_HBA=$(find /etc/postgresql -name pg_hba.conf | head -1)

if [ -z "$PG_CONF" ] || [ -z "$PG_HBA" ]; then
    echo -e "${RED}No se encontro la configuracion de PostgreSQL${NC}"
    exit 1
fi

if ! grep -q "listen_addresses = '\*'" "$PG_CONF"; then
    echo "listen_addresses = '*'" >> "$PG_CONF"
fi

# Add localhost scram auth
if ! grep -q "host all all 127.0.0.1/32 scram-sha-256" "$PG_HBA"; then
    echo "host all all 127.0.0.1/32 scram-sha-256" >> "$PG_HBA"
fi

# Add include for managed rules (without quotes - PG16 requirement)
PG_HBA_INCLUDE=$(dirname "$PG_HBA")/pg_hba_sql_manager.conf
touch "$PG_HBA_INCLUDE"
chown postgres:postgres "$PG_HBA_INCLUDE"
chmod 640 "$PG_HBA_INCLUDE"

if ! grep -q "include_if_exists ${PG_HBA_INCLUDE}" "$PG_HBA"; then
    echo "include_if_exists ${PG_HBA_INCLUDE}" >> "$PG_HBA"
fi

systemctl restart postgresql

# Aplicar timeouts persistentes para sesiones SQL inactivas
cp "${SCRIPT_DIR}/server/configure_postgres_timeouts.sh" /usr/local/bin/configure_postgres_timeouts.sh
chmod +x /usr/local/bin/configure_postgres_timeouts.sh
/usr/local/bin/configure_postgres_timeouts.sh

# ============================================================
# 8. Desplegar aplicacion
# ============================================================
echo -e "${YELLOW}[4/8] Desplegando aplicacion...${NC}"

mkdir -p "$APP_DIR"

# Copy project files (if running from repo clone)
if [ -f "${SCRIPT_DIR}/backend/main.py" ]; then
    cp -r "${SCRIPT_DIR}/backend" "$APP_DIR/"
    cp -r "${SCRIPT_DIR}/server" "$APP_DIR/" 2>/dev/null || true
else
    echo -e "${RED}Error: No se encuentra backend/main.py. Ejecuta desde la raiz del repo.${NC}"
    exit 1
fi

# Create venv and install deps
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/backend/requirements.txt"

# ============================================================
# 9. Generar .env
# ============================================================
echo -e "${YELLOW}[5/8] Generando configuracion...${NC}"

ENCRYPTION_KEY=$("$APP_DIR/venv/bin/python3" -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")

cat > "$APP_DIR/backend/.env" <<ENVEOF
DB_HOST=localhost
DB_NAME=postgres
DB_USER=postgres
DB_PASSWORD=${PG_PASSWORD}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
COOKIE_NAME=access_token
PUBLIC_DB_HOST=${SERVER_IP}
PUBLIC_DB_PORT=5432
ALLOWED_ORIGINS=${ALLOWED_ORIGINS}
COOKIE_SECURE=${COOKIE_SECURE}
CSRF_COOKIE_NAME=csrf_token
CSRF_HEADER_NAME=x-csrf-token
LOGIN_RATE_LIMIT=8
LOGIN_RATE_WINDOW_SEC=300
ENCRYPTION_KEY=${ENCRYPTION_KEY}
ENVEOF

chmod 600 "$APP_DIR/backend/.env"

# ============================================================
# 10. Systemd service
# ============================================================
echo -e "${YELLOW}[6/8] Configurando servicio systemd...${NC}"

cat > /etc/systemd/system/pg_manager.service <<SVCEOF
[Unit]
Description=PostgreSQL Manager Web App
After=network.target postgresql.service

[Service]
User=root
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${APP_DIR}/backend/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable pg_manager
systemctl start pg_manager

# ============================================================
# 11. Nginx
# ============================================================
echo -e "${YELLOW}[7/8] Configurando Nginx...${NC}"

rm -f /etc/nginx/sites-enabled/default

if [ "$USE_DOMAIN" = true ]; then
    # Con dominio - primero HTTP, luego Certbot
    cat > /etc/nginx/sites-available/pg_manager <<NGEOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
NGEOF
    ln -sf /etc/nginx/sites-available/pg_manager /etc/nginx/sites-enabled/
    systemctl reload nginx

    # Certbot SSL
    echo -e "${YELLOW}Instalando certificado SSL con Certbot...${NC}"
    apt-get install -y -qq certbot python3-certbot-nginx > /dev/null
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect || {
        echo -e "${YELLOW}AVISO: Certbot fallo. Verifica que el dominio apunte a ${SERVER_IP}${NC}"
        echo -e "${YELLOW}Puedes ejecutar manualmente: certbot --nginx -d ${DOMAIN}${NC}"
    }
else
    # Sin dominio - solo IP con puerto
    cat > /etc/nginx/sites-available/pg_manager <<NGEOF
server {
    listen ${WEB_PORT};
    server_name _;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()";

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
NGEOF
    ln -sf /etc/nginx/sites-available/pg_manager /etc/nginx/sites-enabled/
    systemctl reload nginx
fi

# ============================================================
# 12. Firewall + Watchdog
# ============================================================
echo -e "${YELLOW}[8/8] Configurando firewall y watchdog...${NC}"

ufw allow 22/tcp > /dev/null 2>&1
ufw allow ${WEB_PORT}/tcp > /dev/null 2>&1
if [ "$USE_DOMAIN" = true ]; then
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
fi
echo "y" | ufw enable > /dev/null 2>&1

# Watchdog
cat > /usr/local/bin/pg_manager_watchdog.sh <<'WDEOF'
#!/bin/bash
LOG="/var/log/pg_manager_watchdog.log"

if ! systemctl is-active --quiet postgresql; then
    echo "$(date) - PostgreSQL caido, reiniciando..." >> "$LOG"
    systemctl restart postgresql
fi

if ! systemctl is-active --quiet pg_manager; then
    echo "$(date) - pg_manager caido, reiniciando..." >> "$LOG"
    systemctl restart pg_manager
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8000/login 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
    echo "$(date) - pg_manager no responde (HTTP $HTTP_CODE), reiniciando..." >> "$LOG"
    systemctl restart pg_manager
fi
WDEOF
chmod +x /usr/local/bin/pg_manager_watchdog.sh

# Add cron if not exists
(crontab -l 2>/dev/null | grep -q pg_manager_watchdog) || \
    (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/pg_manager_watchdog.sh") | crontab -

# ============================================================
# Listo
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalacion completada${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Panel:     ${CYAN}${APP_URL}${NC}"
echo -e "  Usuario:   ${ADMIN_USERNAME}"
echo -e "  PG Pass:   ${PG_PASSWORD}"
echo -e "  Logs:      journalctl -u pg_manager -f"
echo -e "  Watchdog:  /var/log/pg_manager_watchdog.log"
echo ""
echo -e "${YELLOW}Credenciales guardadas en: ${APP_DIR}/backend/.env${NC}"
echo -e "${GREEN}========================================${NC}"
