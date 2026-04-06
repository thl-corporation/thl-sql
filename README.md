# vps-kamatera-SQL-01

Panel web para administrar PostgreSQL y el firewall del VPS, ahora preparado para exponer SQL publico detras de un stack de pooling:

`Cliente SQL -> HAProxy:5432 -> PgBouncer:6432 -> PostgreSQL:5433`

El panel web sigue corriendo por Nginx + Uvicorn, y el backend administra PostgreSQL por el puerto interno `5433`.

## Estado actual

- Login admin con cookie de sesion y CSRF.
- Creacion y eliminacion de bases de datos y usuarios.
- Pausa y reanudacion de bases de datos.
- Apertura y cierre de puertos via UFW.
- Control de acceso SQL por IP.
- Pooling y proxy SQL listos para alta concurrencia.
- Pruebas smoke locales/remotas y prueba de 1000 conexiones versionadas en el repo.

## Arquitectura SQL

- Puerto publico SQL: `5432` atendido por `HAProxy`.
- Puerto interno de `PgBouncer`: `6432`.
- Puerto interno de `PostgreSQL`: `5433`.
- El panel (`backend/main.py`) se conecta directo a PostgreSQL por `localhost:5433`.
- Los clientes SQL externos se conectan al mismo puerto publico de siempre (`5432`), pero ahora pasan por el pooler.

## Instalacion en un VPS nuevo

1. Clona el repo en el servidor:
   - `git clone <repo-url> /var/www/pg_manager && cd /var/www/pg_manager`
2. Ejecuta el instalador como `root`:
   - `bash install.sh`
3. El script configura:
   - PostgreSQL interno en `5433`
   - PgBouncer
   - HAProxy
   - Nginx
   - UFW
   - servicio `pg_manager`
   - watchdog

## Actualizar un VPS existente

```bash
ssh root@servidor "cd /var/www/pg_manager && git pull origin main && bash deploy_remote.sh"
```

El deploy:

- actualiza dependencias Python
- fuerza variables nuevas en `backend/.env`
- reconfigura PostgreSQL para usar `5433` interno
- reinstala y valida `PgBouncer + HAProxy`
- regenera el auth file de PgBouncer
- reinicia `pg_manager`, `pgbouncer` y `haproxy`

## Variables de entorno importantes

- `DB_HOST=localhost`
- `DB_PORT=5433`
- `DB_NAME=postgres`
- `DB_USER=postgres`
- `DB_PASSWORD=...`
- `PUBLIC_DB_HOST=<IP o dominio del VPS>`
- `PUBLIC_DB_PORT=5432`
- `POOLING_ENABLED=true`
- `PGBOUNCER_HOST=127.0.0.1`
- `PGBOUNCER_PORT=6432`
- `POOL_MODE=transaction`
- `PGBOUNCER_MAX_CLIENT_CONN=2000`
- `PGBOUNCER_DEFAULT_POOL_SIZE=80`
- `PGBOUNCER_MIN_POOL_SIZE=20`
- `PGBOUNCER_RESERVE_POOL_SIZE=40`
- `PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC=5`
- `SQL_PROXY_LISTEN_BACKLOG=4096`
- `PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC=120`
- `PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC=120`
- `PGBOUNCER_SERVER_LOGIN_RETRY_SEC=15`
- `HAPROXY_MAXCONN=4000`
- `HAPROXY_TIMEOUT_CONNECT=15s`
- `HAPROXY_TIMEOUT_CLIENT=5m`
- `HAPROXY_TIMEOUT_SERVER=5m`
- `HAPROXY_TIMEOUT_QUEUE=90s`

## Scripts operativos versionados

- `install.sh`: instala un VPS nuevo.
- `deploy_remote.sh`: actualiza un VPS ya instalado.
- `server/configure_postgres_timeouts.sh`: mueve PostgreSQL al puerto interno y ajusta timeouts/capacidad.
- `server/configure_sql_proxy.sh`: renderiza y aplica la configuracion de HAProxy y PgBouncer.
- `server/sync_pgbouncer_auth.py`: regenera el auth file de PgBouncer desde las credenciales administradas por la app.
- `server/run_sql_load_test.py`: ejecuta la prueba de concurrencia / 1000 conexiones.
- `verify_deployment.py`: smoke test local en el servidor.
- `verify_remote.py`: smoke test remoto via panel web y conexion SQL publica.

## Suite de pruebas

### Smoke local en el VPS

```bash
cd /var/www/pg_manager
source venv/bin/activate
python verify_deployment.py
```

### Smoke remoto

```bash
python verify_remote.py
```

Requiere que `TEST_SQL_IP` corresponda a la IP publica desde la que ejecutas el script si quieres validar la conexion SQL real.

### Prueba de 1000 conexiones

Ejecutar en el VPS:

```bash
cd /var/www/pg_manager
source venv/bin/activate
python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8
```

El script devuelve JSON con:

- conexiones solicitadas
- conexiones exitosas/fallidas
- tiempo medio/maximo de conexion
- pico de clientes/servidores visto por PgBouncer
- pico de backends cliente en PostgreSQL

## Documentacion extra

- `INSTRUCCIONES_UPDATE_VPS.md`
- `INSTRUCCIONES_TEST_REMOTO.md`
- `docs/PRUEBA_1000_CONEXIONES.md`

## Seguridad operativa

- El acceso SQL publico sigue controlado por UFW en `5432`.
- PostgreSQL ya no queda expuesto directamente al exterior.
- `pg_hba.conf` se limita a `postgres` en localhost y a las reglas locales generadas para bases publicadas via pooler.
- El auth file de PgBouncer se regenera desde credenciales cifradas guardadas por la app.
