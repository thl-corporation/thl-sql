# CLAUDE.md

Notes for contributors working on this repository.

## Project Overview

THL SQL is a web admin panel for PostgreSQL and VPS firewall management.
The UI language is Spanish and the service is designed for Linux servers with systemd.

## Tech Stack

- Backend: FastAPI (`backend/main.py`)
- Frontend: static HTML (`backend/static/index.html`, `backend/static/login.html`)
- Database: PostgreSQL + psycopg2
- Auth: cookie session + CSRF token
- SQL scale: HAProxy + PgBouncer + PostgreSQL internal port

## Commands

```bash
# Local development
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
cp backend/.env.example backend/.env
cd backend && uvicorn main:app --host 127.0.0.1 --port 8000

# Fresh install on Linux VPS (as root)
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash

# Update existing server
cd /var/www/pg_manager && git pull origin main && bash deploy_remote.sh
```

## Security Rules

- Never commit `.env` or private keys.
- Keep placeholders in `*.example` files.
- Avoid hardcoded IPs/domains/usernames/passwords in code and docs.
