<p align="center">
  <img src="docs/assets/thl-corporation-logo.png" alt="THL Corporation" width="180">
</p>

# THL SQL

Production-ready SQL platform for fast and repeatable Linux deployments.

Company: [THL Corporation](https://thlcorporation.com)  
Contact: `admin@thlcorporation.com`

## Why THL SQL

- Scales concurrent client traffic with `HAProxy + PgBouncer`.
- Keeps PostgreSQL isolated on an internal port.
- Manages SQL access by IP/CIDR from the admin panel.
- Standardizes Linux setup with a one-command installer.

Operational architecture:

`SQL Client -> HAProxy:5432 -> PgBouncer:6432 -> PostgreSQL:5433`

## Official Install

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Fallback (manual execution with the same installer):

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

Supported families:

- Debian / Ubuntu
- RHEL / Rocky / AlmaLinux / CentOS

## Installer Inputs

- `THL_DOMAIN`
- `THL_BIND_IP`
- `THL_PORT`
- `THL_ADMIN_USER`
- `THL_ADMIN_PASS`
- `THL_PG_PASSWORD`
- `THL_NONINTERACTIVE=1`
- `THL_INSTALL_DEBUG=1` (enables `set -x`)
- `THL_INSTALL_LOG_FILE=/var/log/thl-sql-install.log`
- `THL_SYSTEM_UPGRADE_POLICY=none|upgrade|full` (default: `full`)
- `THL_UX_MODE=1` (default, minimal prompts)
- `THL_PRESERVE_EXISTING=1` (default, keeps existing credentials/config on upgrade)
- `THL_ACTION=reinstall|upgrade|uninstall`
- `THL_FORCE=1` (required for non-interactive destructive actions)
- `THL_AUTO_CACHE_CLEAN=1` (default, clears package/temp caches automatically)

## Installation Modes (3 options)

1. Full wipe + new install:

```bash
THL_ACTION=reinstall THL_FORCE=1 curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

2. Upgrade in place (preserve credentials/config):

```bash
THL_ACTION=upgrade curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

3. Uninstall app and all managed data:

```bash
THL_ACTION=uninstall THL_FORCE=1 curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Interactive one-link behavior:

- If you run `curl ... | bash` from a terminal and do not set `THL_ACTION`, installer shows the 3 options menu automatically.
- Each installer phase prints `OK` on success; if any phase fails, it auto-generates a diagnostic report in `/var/log/thl-sql-failure-*.log`.

UX one-command with domain (recommended for production):

```bash
THL_DOMAIN=sql.example.com \
THL_ADMIN_USER=admin \
THL_ADMIN_PASS='Change_This_Immediately_123!' \
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Non-interactive example:

```bash
THL_ADMIN_USER=admin \
THL_ADMIN_PASS='change_me' \
THL_DOMAIN=sql.example.com \
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

## Ubuntu Empty VPS Notes

Recommended preflight:

```bash
id -u
systemctl --version
```

If the installer stops at `[1/11]`, re-run in debug mode and inspect the log:

```bash
THL_INSTALL_DEBUG=1 \
THL_INSTALL_LOG_FILE=/var/log/thl-sql-install.log \
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Quick diagnostics:

```bash
tail -n 120 /var/log/thl-sql-install.log
journalctl -u pg_manager -n 80 --no-pager
```

Domain note:

- If `THL_DOMAIN` is set, installer uses HTTPS flow with certbot.
- If `THL_DOMAIN` is empty, installer uses IP mode (`http://IP:PORT`).
- If an existing install is detected, credentials and current `.env` settings are preserved by default.

## Dashboard Runtime Metrics

- On host installations, `/api/stats` uses `psutil` to report CPU and memory.
- On container installations, `/api/stats` reads CPU and memory usage from Linux cgroups when available so limited containers reflect container quotas instead of host totals.
- The dashboard metrics refresh interval is `10000` ms (10 seconds).

## Repository Sync

- Use `./push_dual_repos.ps1` from the repo root to push the current branch to both `thl-corporation/thl-sql` and the SPA mirror.
- Use `./push_dual_repos.ps1 -DryRun` to validate both targets without publishing.
- The preferred SPA target is `thl-corporation-spa/thl-sql`.
- If that SPA repo is not available yet, the script automatically falls back to `thl-corporation-spa/vps-kamatera-SQL-01`.
- `THL_SQL_CORP_SSH_KEY` can override the dedicated SSH key path for `thl-corporation/thl-sql`.
- `THL_SQL_SPA_REPO_URL`, `THL_SQL_SPA_LEGACY_REPO_URL`, and `THL_SQL_CORP_REPO_URL` can override the default repo URLs.

## Technical Validation

On the VPS:

```bash
cd /var/www/pg_manager
source venv/bin/activate
python verify_deployment.py
python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8
bash server/run_test_suite.sh
```

From an external client:

```bash
python verify_remote.py
```

## Publication Safety

- No real secrets are stored in git.
- Sensitive values are handled through `*.example` templates.
- Keys and credentials are blocked in `.gitignore`.
- Run this safety check before publishing:

```bash
bash server/check_repo_safety.sh
```

## Documentation

- `docs/INSTALL_LINUX_MULTI_DISTRO.md`
- `docs/REPLICAR_EN_OTRO_VPS.md`
- `docs/PRUEBA_1000_CONEXIONES.md`
- `INSTRUCCIONES_UPDATE_VPS.md`
- `INSTRUCCIONES_TEST_REMOTO.md`
