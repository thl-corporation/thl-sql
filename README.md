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
