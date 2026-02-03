#!/bin/bash
set -e

# 1. Setup Postgres Config (Idempotent-ish)
if ! grep -q "listen_addresses = '*'" /etc/postgresql/16/main/postgresql.conf; then
    echo "listen_addresses = '*'" >> /etc/postgresql/16/main/postgresql.conf
fi

if ! grep -q "host all all 0.0.0.0/0 scram-sha-256" /etc/postgresql/16/main/pg_hba.conf; then
    echo "host all all 0.0.0.0/0 scram-sha-256" >> /etc/postgresql/16/main/pg_hba.conf
fi

systemctl restart postgresql

# 1.5 Setup Firewall (UFW)
# Ensure UFW is installed
apt-get install -y ufw

# Allow SSH, HTTP, and PostgreSQL
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 5432/tcp

# Enable UFW non-interactively
echo "y" | ufw enable

# 2. Setup Python Env
cd /var/www/pg_manager
python3 -m venv venv
source venv/bin/activate
pip install -r backend/requirements.txt

# 3. Create Systemd Service
cat <<EOF > /etc/systemd/system/pg_manager.service
[Unit]
Description=PostgreSQL Manager Web App
After=network.target postgresql.service

[Service]
User=root
WorkingDirectory=/var/www/pg_manager
ExecStart=/var/www/pg_manager/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 4. Create Nginx Config
cat <<EOF > /etc/nginx/sites-available/pg_manager
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# 5. Enable Sites
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pg_manager /etc/nginx/sites-enabled/

systemctl daemon-reload
systemctl restart nginx
systemctl enable pg_manager
systemctl restart pg_manager

echo "Deployment Complete!"
