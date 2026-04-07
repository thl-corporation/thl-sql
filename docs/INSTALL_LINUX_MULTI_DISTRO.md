# Instalacion Linux Multi-Distro

Este proyecto soporta instalacion automatica en:

- Debian / Ubuntu
- RHEL / Rocky / AlmaLinux / CentOS

## Metodo recomendado (one-link)

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

El instalador pedira:

1. Usuario admin
2. Password admin
3. Dominio (opcional)
4. Si no hay dominio, IP y puerto web

## Variables de entorno soportadas

Puedes automatizar la instalacion con:

```bash
THL_ADMIN_USER=admin \
THL_ADMIN_PASS='change_me' \
THL_DOMAIN=sql.example.com \
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Variables:

- `THL_DOMAIN`
- `THL_BIND_IP`
- `THL_PORT`
- `THL_ADMIN_USER`
- `THL_ADMIN_PASS`
- `THL_PG_PASSWORD` (opcional)
- `THL_NONINTERACTIVE=1` (opcional)

## Resultado esperado

- `postgresql` activo en `5433` interno.
- `pgbouncer` activo en `6432`.
- `haproxy` activo en `5432`.
- `pg_manager` activo en `127.0.0.1:8000`.
- `nginx` publicando panel web.
- Firewall configurado automaticamente:
  - Debian/Ubuntu: `ufw`
  - RHEL-family: `firewalld`
