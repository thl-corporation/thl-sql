# Instalacion Linux Multi-Distro

Este proyecto soporta instalacion automatica en:

- Debian / Ubuntu
- RHEL / Rocky / AlmaLinux / CentOS

## Metodo recomendado (one-link)

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

## Metodo alternativo (fallback en 3 pasos)

Si quieres ver mejor los errores en consola:

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

Si desactivas UX (`THL_UX_MODE=0`), el instalador pedira:

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
- `THL_INSTALL_DEBUG=1` (opcional, activa `set -x`)
- `THL_INSTALL_LOG_FILE=/var/log/thl-sql-install.log` (opcional)
- `THL_SYSTEM_UPGRADE_POLICY=none|upgrade|full` (opcional, default `full`)
- `THL_UX_MODE=1` (opcional, default: menos prompts)
- `THL_PRESERVE_EXISTING=1` (opcional, default: conserva credenciales/configuracion en upgrades)
- `THL_ACTION=reinstall|upgrade|uninstall` (opcional)
- `THL_FORCE=1` (opcional, requerido para acciones destructivas sin prompt)

## Modos de instalacion (3 opciones)

1) Borrado completo + instalacion nueva:

```bash
THL_ACTION=reinstall THL_FORCE=1 curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

2) Actualizacion (mantiene credenciales y configuracion):

```bash
THL_ACTION=upgrade curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

3) Eliminar aplicacion y todos los datos gestionados:

```bash
THL_ACTION=uninstall THL_FORCE=1 curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

## UX recomendado con dominio

```bash
THL_DOMAIN=sql.example.com \
THL_ADMIN_USER=admin \
THL_ADMIN_PASS='Change_This_Immediately_123!' \
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Comportamiento:

- Si `THL_DOMAIN` viene definido, usa flujo HTTPS (certbot).
- Si `THL_DOMAIN` no viene definido, usa modo IP:puerto.
- Si detecta instalacion previa, preserva usuario admin, password admin y configuracion existente (`backend/.env`) por defecto.

## VPS Ubuntu vacio: preflight recomendado

```bash
id -u
systemctl --version
```

El instalador ya incluye:

- Bootstrap minimo para modo one-link (`bash`, `curl`, `ca-certificates`, `git`, `tar`, `sudo`).
- Reintentos y recuperacion APT (`dpkg --configure -a`, `apt --fix-broken install -y`).
- Logging persistente en `/var/log/thl-sql-install.log`.
- Si no hay TTY disponible, cambia automaticamente a modo no interactivo.
- En modo no interactivo sin `THL_ADMIN_PASS`, genera password admin aleatorio y lo guarda en `/var/www/pg_manager/backend/.env`.

## Troubleshooting de `[1/11] Instalando dependencias`

Ejecuta en modo debug:

```bash
THL_INSTALL_DEBUG=1 \
THL_INSTALL_LOG_FILE=/var/log/thl-sql-install.log \
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Luego revisa:

```bash
tail -n 120 /var/log/thl-sql-install.log
```

## Resultado esperado

- `postgresql` activo en `5433` interno.
- `pgbouncer` activo en `6432`.
- `haproxy` activo en `5432`.
- `pg_manager` activo en `127.0.0.1:8000`.
- `nginx` publicando panel web.
- Firewall configurado automaticamente:
  - Debian/Ubuntu: `ufw`
  - RHEL-family: `firewalld`
