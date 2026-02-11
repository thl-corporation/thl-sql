#!/bin/bash
set -e

PG_LISTEN_ADDRESSES=${PG_LISTEN_ADDRESSES:-localhost}
PG_ALLOWED_CIDR=${PG_ALLOWED_CIDR:-127.0.0.1/32}
DOMAIN=${DOMAIN:-_}
SSL_CERT_PATH=${SSL_CERT_PATH:-/etc/letsencrypt/live/$DOMAIN/fullchain.pem}
SSL_KEY_PATH=${SSL_KEY_PATH:-/etc/letsencrypt/live/$DOMAIN/privkey.pem}

# 1. Setup Postgres Config (Idempotent-ish)
if ! grep -q "listen_addresses = '$PG_LISTEN_ADDRESSES'" /etc/postgresql/16/main/postgresql.conf; then
    echo "listen_addresses = '$PG_LISTEN_ADDRESSES'" >> /etc/postgresql/16/main/postgresql.conf
fi

if ! grep -q "host all all $PG_ALLOWED_CIDR scram-sha-256" /etc/postgresql/16/main/pg_hba.conf; then
    echo "host all all $PG_ALLOWED_CIDR scram-sha-256" >> /etc/postgresql/16/main/pg_hba.conf
fi

systemctl restart postgresql

# 1.5 Setup Firewall (UFW)
# Ensure UFW is installed
apt-get install -y ufw

# Allow SSH, HTTP, and PostgreSQL
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow from "$PG_ALLOWED_CIDR" to any port 5432 proto tcp

# Enable UFW non-interactively
echo "y" | ufw enable

# 2. Setup Python Env
cd /var/www/pg_manager
python3 -m venv venv
source venv/bin/activate
pip install -r backend/requirements.txt

# 3. Create Systemd Service
useradd --system --no-create-home --shell /usr/sbin/nologin pg_manager || true
cat <<EOF > /etc/systemd/system/pg_manager.service
[Unit]
Description=PostgreSQL Manager Web App
After=network.target postgresql.service

[Service]
User=pg_manager
Group=pg_manager
WorkingDirectory=/var/www/pg_manager/backend
ExecStart=/var/www/pg_manager/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 4. Create Nginx Config
if [ -f "$SSL_CERT_PATH" ] && [ -f "$SSL_KEY_PATH" ]; then
cat <<EOF > /etc/nginx/sites-available/pg_manager
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()";
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
else
cat <<EOF > /etc/nginx/sites-available/pg_manager
server {
    listen 80;
    server_name $DOMAIN;

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
    }
}
EOF
fi

# 5. Enable Sites
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pg_manager /etc/nginx/sites-enabled/

systemctl daemon-reload
systemctl restart nginx
systemctl enable pg_manager
systemctl restart pg_manager

echo "Deployment Complete!"
