# thl-sql

Panel web para administrar PostgreSQL y firewall en VPS Linux, con stack SQL de alto volumen:

`Cliente SQL -> HAProxy:5432 -> PgBouncer:6432 -> PostgreSQL:5433`

## Instalacion one-link

Ejecutar como `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

El instalador soporta familias:

- Debian / Ubuntu
- RHEL / Rocky / AlmaLinux / CentOS

Tambien puedes pasar variables de entorno:

```bash
THL_ADMIN_USER=admin \
THL_ADMIN_PASS='change_me' \
THL_DOMAIN=sql.example.com \
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Variables soportadas:

- `THL_DOMAIN` (opcional)
- `THL_BIND_IP` (si no hay dominio)
- `THL_PORT` (si no hay dominio)
- `THL_ADMIN_USER`
- `THL_ADMIN_PASS`

## Arquitectura y servicios

- App FastAPI: `pg_manager` (systemd)
- Proxy SQL: `haproxy` en `5432`
- Pooling: `pgbouncer` en `6432`
- PostgreSQL interno: `5433`
- Reverse proxy web: `nginx`
- Firewall detectado automaticamente:
  - `ufw` en Debian/Ubuntu
  - `firewalld` en RHEL/Rocky/Alma

## Variables de entorno backend

Usa `backend/.env.example` como base. Variables clave:

- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`
- `PUBLIC_DB_HOST`, `PUBLIC_DB_PORT`
- `POOLING_ENABLED`, `PGBOUNCER_*`, `HAPROXY_*`
- `ADMIN_USERNAME`, `ADMIN_PASSWORD`
- `ENCRYPTION_KEY`

## Suite de validacion

En el VPS:

```bash
cd /var/www/pg_manager
source venv/bin/activate
python verify_deployment.py
python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8
bash server/run_test_suite.sh
```

Desde una maquina externa:

```bash
python verify_remote.py
```

## Documentacion adicional

- `INSTRUCCIONES_UPDATE_VPS.md`
- `INSTRUCCIONES_TEST_REMOTO.md`
- `docs/PRUEBA_1000_CONEXIONES.md`
- `docs/INSTALL_LINUX_MULTI_DISTRO.md`
- `docs/REPLICAR_EN_OTRO_VPS.md`

## Seguridad

- No commitear `.env`, llaves SSH ni backups de credenciales.
- Revisar `.gitignore` antes de cada push.
- Reemplazar placeholders de `*.example` antes de desplegar a produccion.
- Validar repo antes de publicar: `bash server/check_repo_safety.sh`
