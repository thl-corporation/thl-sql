# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

THL SQL is a web admin panel for PostgreSQL and VPS firewall management.
The UI language is Spanish and the service is designed for Linux servers with systemd.

## Tech Stack

- Backend: FastAPI (`backend/main.py`, ~2350 lines — single file)
- Frontend: static HTML (`backend/static/index.html`, `backend/static/login.html`)
- Database: PostgreSQL + psycopg2
- Auth: in-memory session store + CSRF token + Fernet encryption for stored secrets
- SQL scale: HAProxy + PgBouncer + PostgreSQL internal port

## Commands

```bash
# Local development
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
cp backend/.env.example backend/.env
# Generate ENCRYPTION_KEY: python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
cd backend && uvicorn main:app --host 127.0.0.1 --port 8000

# Fresh install on Linux VPS (as root)
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash

# Update existing server
cd /var/www/pg_manager && git pull origin main && bash deploy_remote.sh

# Maintenance scripts (run from backend/ with .env loaded)
python audit_db.py          # Find and remove zombie DBs / orphan users (interactive)
python migrate_sql_access.py  # Create sql_access_ips / sql_access_ip_databases tables
python cleanup_vps.py       # VPS cleanup utility
```

## Architecture

### Backend (`backend/main.py`)

All application logic lives in a single FastAPI file. Key sections:

**Startup / environment detection** (lines 1–160): Auto-detects runtime environment (container vs host via `/.dockerenv`, cgroup paths, `/proc`), service manager (systemd vs sysv), firewall backend (ufw → firewalld → none), and `pg_hba.conf` path by PostgreSQL version.

**Required env vars** — the app crashes at startup if missing:
- `ADMIN_PASSWORD` — panel login password
- `ENCRYPTION_KEY` — a Fernet key; used to encrypt DB passwords stored in `managed_clients`

**Auth flow**: `POST /login` → creates in-memory session token + CSRF token → cookies `access_token` (HttpOnly) + `csrf_token` (JS-readable). Sessions are in-memory; a server restart logs everyone out. CSRF is validated via `require_csrf` dependency on all mutating routes.

**Client lifecycle** (`/create-client`, `/clients/{id}`, `/clients/{id}/pause|resume`): Creates a PostgreSQL user (`user_{slug}`) + database, stores metadata in `managed_clients` with the password Fernet-encrypted, and syncs PgBouncer's `userlist.txt` via `sync_pgbouncer_auth()`.

**Firewall** (`/api/ports/*`): Wraps `ufw` or `firewall-cmd` via `run_sudo_command()`. Auto-detects backend; can be forced with `FIREWALL_BACKEND=ufw|firewalld|none`. Protected ports (22, 80, 443, app port, DB port) are never closed.

**SQL access** (`/api/sql-access/*`): Manages a fenced section in `pg_hba.conf` between `# BEGIN THL SQL MANAGED RULES` / `# END THL SQL MANAGED RULES`, then calls `reload_postgres_runtime()` (pg_ctl reload or `systemctl reload`). Also tracks allowed IPs and their databases in the `sql_access_ips` / `sql_access_ip_databases` tables.

**Metrics** (`/api/stats`): Reads cgroup v1/v2 files (`/sys/fs/cgroup/...`) for container-aware CPU/memory stats, falling back to `psutil` for host stats. Uses a sampling pattern to avoid blocking the event loop.

**Pooling** (`/api/pooling/status`): Reads PgBouncer's admin console via `psycopg2` on `PGBOUNCER_PORT`. `sync_pgbouncer_auth()` writes `userlist.txt` and sends `RELOAD` to PgBouncer.

**Config endpoint** (`/api/config`): Returns runtime-detected values including `PUBLIC_DB_HOST`/`PUBLIC_DB_PORT` (what clients use to connect — may differ from internal `DB_HOST`/`DB_PORT`).

### Database Schema (`backend/schema.sql`)

Three tables in the `postgres` database:
- `managed_clients` — panel-managed DBs and users; passwords stored Fernet-encrypted
- `sql_access_ips` — IP CIDRs allowed through the firewall for SQL access
- `sql_access_ip_databases` — per-IP database allowlist (FK → `sql_access_ips`)

Tables are created automatically at startup via `CREATE TABLE IF NOT EXISTS` inside `main.py`.

### Two-host model

`DB_HOST`/`DB_PORT` = internal connection (app → Postgres, often via PgBouncer on 5433).
`PUBLIC_DB_HOST`/`PUBLIC_DB_PORT` = what is shown to clients in connection strings.
`TAILSCALE_IP` — when set, overrides `PUBLIC_DB_HOST` for Tailscale VPN deployments.

### Server scripts (`server/`)

Shell utilities for the deployed Linux host: `configure_sql_proxy.sh` (HAProxy/PgBouncer setup), `configure_postgres_timeouts.sh`, `pg_manager_watchdog.sh`, `run_test_suite.sh`.

## Security Rules

- Never commit `.env` or private keys.
- Keep placeholders in `*.example` files.
- Avoid hardcoded IPs/domains/usernames/passwords in code and docs.
- All SQL identifiers use `psycopg2.sql.Identifier` / `sql.Literal` — never f-string interpolation into queries.
- `run_sudo_command()` tries direct → passwordless sudo → `ROOT_PASSWORD` sudo in that order; do not bypass this pattern.
