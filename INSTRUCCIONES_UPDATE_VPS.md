# Guia de actualizacion del VPS

Este repo deja versionado el camino completo para actualizar el servidor y reaplicar la arquitectura:

`HAProxy:5432 -> PgBouncer:6432 -> PostgreSQL:5433`

## Comando rapido

Desde la raiz del proyecto en tu maquina local:

```bash
ssh -i ./ssh_keys/vps_kamatera_id_ed25519 root@66.55.75.32 "cd /var/www/pg_manager && GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_github' git pull origin main && bash deploy_remote.sh"
```

## Que hace `deploy_remote.sh`

1. Actualiza dependencias Python del backend.
2. Fuerza en `backend/.env` las variables del stack de pooling.
3. Reconfigura PostgreSQL para usar `5433` interno.
4. Reinstala y valida `PgBouncer + HAProxy`.
5. Regenera el auth file de PgBouncer desde la metadata del panel.
6. Reinicia `pg_manager`, `pgbouncer` y `haproxy`.

## Validacion posterior al deploy

Dentro del VPS:

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

Chequeo de firewall (diagnostico rapido):

```bash
sudo ufw status verbose
```

## Servicios a revisar

```bash
systemctl status postgresql
systemctl status pgbouncer
systemctl status haproxy
systemctl status pg_manager
```

## Archivos clave en el servidor

- `/var/www/pg_manager/backend/.env`
- `/etc/pgbouncer/pgbouncer.ini`
- `/etc/pgbouncer/userlist.txt`
- `/etc/haproxy/haproxy.cfg`
- `/etc/systemd/system/pg_manager.service`

## Nota de migracion

Si `server/sync_pgbouncer_auth.py` avisa que no pudo desencriptar la clave de un cliente historico, ese usuario no entrara al `auth_file` de PgBouncer hasta que se actualice su password.

La forma segura de resolverlo es:

1. Entrar al panel.
2. Cambiar la password de ese cliente.
3. Verificar que vuelva a aparecer en `/etc/pgbouncer/userlist.txt`.

## Llaves y acceso

- Llave local: `./ssh_keys/vps_kamatera_id_ed25519`
- Llave GitHub en el VPS: `~/.ssh/id_ed25519_github`
- VPS actual: `root@66.55.75.32`
