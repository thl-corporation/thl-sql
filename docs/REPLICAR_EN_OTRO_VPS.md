# Replicar En Otro VPS

## Prerrequisitos

- VPS Linux con systemd.
- Usuario con permisos root.
- Conectividad saliente para instalar paquetes.
- DNS configurado si usaras dominio.

## Pasos

1. Ejecutar instalacion one-link:

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

2. Confirmar estado de servicios:

```bash
systemctl is-active postgresql pgbouncer haproxy pg_manager nginx
```

3. Validar puertos:

```bash
ss -ltn '( sport = :5432 or sport = :6432 or sport = :5433 or sport = :8000 )'
```

4. Ejecutar smoke test local:

```bash
cd /var/www/pg_manager
source venv/bin/activate
python verify_deployment.py
```

5. Ejecutar smoke test remoto:

```bash
python verify_remote.py
```

## Comandos de diagnostico

- Logs app: `journalctl -u pg_manager -f`
- Logs PgBouncer: `journalctl -u pgbouncer -f`
- Logs HAProxy: `journalctl -u haproxy -f`
- Firewall (Debian): `ufw status verbose`
- Firewall (RHEL): `firewall-cmd --list-all`
