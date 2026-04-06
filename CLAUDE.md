# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Web admin panel for managing a PostgreSQL server and VPS firewall (UFW) on a Kamatera VPS. Published at https://sql.thlcorporation.com. The UI is in Spanish.

## Tech Stack

- **Backend**: Python FastAPI monolith (`backend/main.py`) — single file ~500 lines
- **Frontend**: Two static HTML files with vanilla JS (`backend/static/index.html`, `backend/static/login.html`)
- **Database**: PostgreSQL via psycopg2 (direct SQL, no ORM)
- **Auth**: Cookie-based sessions with CSRF tokens, in-memory session store, Fernet-encrypted DB passwords
- **System integration**: UFW firewall and pg_hba.conf management via `sudo` subprocess calls

## Commands

```bash
# Setup
python -m venv .venv && .venv/Scripts/activate  # Windows
pip install -r backend/requirements.txt

# Run locally (from backend/ directory)
cd backend && uvicorn main:app --host 127.0.0.1 --port 8000 --log-level info

# Environment config
cp backend/.env.example backend/.env  # then fill in values
```

There are no tests, linters, or CI configured in this project.

## Architecture

### Single-file API (`backend/main.py`)

All API logic lives in one file: routes, auth, DB operations, firewall management, and pg_hba.conf generation. Key patterns:

- **DB connections**: `get_db_connection()` returns a psycopg2 connection with `autocommit=True`. Always use `psycopg2.sql` module for identifier/literal interpolation (never f-strings in SQL).
- **Auth flow**: `get_session(request)` validates cookie → in-memory session store. `require_csrf(request)` enforces double-submit CSRF. `enforce_login_rate_limit(request)` is IP-based in-memory rate limiting.
- **Sudo commands**: `run_sudo_command(cmd_args)` tries direct execution → sudo -n → sudo -S with password. Used for UFW and pg_hba.conf operations.
- **pg_hba.conf management**: `rebuild_pg_hba_rules()` regenerates a separate include file (`pg_hba_sql_manager.conf`) from DB state, then reloads PostgreSQL. This controls which IPs can connect to which databases.
- **Input validation**: `normalize_identifier()`, `normalize_client_name()`, `normalize_user_slug()`, `normalize_sql_ip()` — all inputs are validated/sanitized before use.
- **Metadata tables**: `managed_clients` (client DBs/users), `sql_access_ips` + `sql_access_ip_databases` (IP-based access rules). Schema auto-creates on startup via `init_metadata_db()`.
- **Public access**: Unified in the SQL access card. Adding `0.0.0.0/0` as an IP grants public access to the selected databases (adds `0.0.0.0/0` rule to pg_hba and opens UFW 5432/tcp). Any other IP creates a specific firewall + pg_hba rule.

### Utility Scripts

- `backend/audit_db.py` — Interactive script to find/delete zombie databases and orphan users not tracked in `managed_clients`
- `backend/cleanup_vps.py` — Drops ALL managed client databases/users and truncates metadata (destructive reset)
- `backend/migrate_sql_access.py` — Creates the `sql_access_ips` and `sql_access_ip_databases` tables

### Frontend

Both HTML files are self-contained with inline CSS/JS. `index.html` is the main dashboard (clients, ports, SQL access, stats). `login.html` is the login page. All API calls from the frontend include CSRF headers.

## Key Environment Variables

Required: `DB_PASSWORD`, `ADMIN_PASSWORD`, `ENCRYPTION_KEY` (Fernet key for encrypting stored DB passwords).

The app refuses to start without these three.
