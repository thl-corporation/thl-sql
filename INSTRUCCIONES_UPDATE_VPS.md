# Guia de actualizacion del VPS

Esta guia deja versionado el camino para actualizar una instalacion existente:

`HAProxy:5432 -> PgBouncer:6432 -> PostgreSQL:5433`

## Comando rapido

En el servidor:

```bash
cd /var/www/pg_manager
git pull origin main
bash deploy_remote.sh
```

## Que hace `deploy_remote.sh`

1. Actualiza dependencias Python.
2. Fuerza variables de pooling en `backend/.env`.
3. Reaplica tuning de PostgreSQL interno (`5433`).
4. Reinstala y valida `PgBouncer + HAProxy`.
5. Regenera auth de PgBouncer desde metadata del panel.
6. Reinicia `pg_manager`, `pgbouncer` y `haproxy`.

## Validacion posterior al deploy

En el VPS:

```bash
cd /var/www/pg_manager
source venv/bin/activate
python verify_deployment.py
python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8
```

Desde tu maquina local:

```bash
python verify_remote.py
```

## Servicios a revisar

```bash
systemctl status postgresql
systemctl status pgbouncer
systemctl status haproxy
systemctl status pg_manager
systemctl status nginx
```

## Archivos clave en el servidor

- `/var/www/pg_manager/backend/.env`
- `/etc/pgbouncer/pgbouncer.ini`
- `/etc/pgbouncer/userlist.txt`
- `/etc/haproxy/haproxy.cfg`
- `/etc/systemd/system/pg_manager.service`

## Firewall segun distro

- Debian/Ubuntu: `sudo ufw status verbose`
- RHEL/Rocky/Alma: `sudo firewall-cmd --list-all`
