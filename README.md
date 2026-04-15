<p align="center">
  <img src="docs/assets/thl-corporation-logo.png" alt="THL Corporation" width="180">
</p>

# THL SQL

**EN** | Production-ready SQL platform for fast and repeatable Linux deployments.  
**ES** | Plataforma SQL lista para produccion con despliegues rapidos y repetibles en Linux.

Company / Empresa: [THL Corporation](https://thlcorporation.com)  
Contact / Contacto: `admin@thlcorporation.com`

---

## Why THL SQL / Por que THL SQL

**EN**

- Scales concurrent client traffic with `HAProxy + PgBouncer`.
- Keeps PostgreSQL isolated on an internal port.
- Manages SQL access by IP/CIDR from the admin panel.
- Standardizes Linux setup with a one-command installer.
- Optional Tailscale VPN for private access to the panel and databases.
- Container-aware: detects cgroup limits for accurate CPU/RAM metrics inside Docker.

**ES**

- Escala trafico concurrente con `HAProxy + PgBouncer`.
- Mantiene PostgreSQL aislado en un puerto interno.
- Gestiona acceso SQL por IP/CIDR desde el panel de administracion.
- Estandariza la configuracion de Linux con un instalador de un solo comando.
- VPN Tailscale opcional para acceso privado al panel y bases de datos.
- Compatible con contenedores: detecta limites cgroup para metricas precisas de CPU/RAM en Docker.

### Architecture / Arquitectura

```
SQL Client -> HAProxy:5432 -> PgBouncer:6432 -> PostgreSQL:5433
```

---

## Quick Install / Instalacion Rapida

**EN** | Run as root on a fresh Linux VPS. The installer is fully interactive.  
**ES** | Ejecutar como root en un VPS Linux nuevo. El instalador es completamente interactivo.

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

Fallback (manual download / descarga manual):

```bash
curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

### Supported Distros / Distribuciones Soportadas

- Debian / Ubuntu
- RHEL / Rocky / AlmaLinux / CentOS

---

## Installation Modes / Modos de Instalacion

**EN** | Three modes are available. If you run the one-liner without `THL_ACTION`, the installer shows an interactive menu.  
**ES** | Tres modos disponibles. Si ejecutas el one-liner sin `THL_ACTION`, el instalador muestra un menu interactivo.

### 1. Full wipe + new install / Instalacion limpia

```bash
THL_ACTION=reinstall THL_FORCE=1 \
  curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

### 2. Upgrade in place / Actualizar sin perder datos

```bash
THL_ACTION=upgrade \
  curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

### 3. Uninstall / Desinstalar

```bash
THL_ACTION=uninstall THL_FORCE=1 \
  curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

### Production example / Ejemplo produccion

```bash
THL_DOMAIN=sql.example.com \
THL_ADMIN_USER=admin \
THL_ADMIN_PASS='Change_This_Immediately_123!' \
  curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

---

## Tailscale VPN

**EN** | The installer can optionally set up Tailscale so the panel and databases are only reachable through a private VPN IP (e.g. `100.x.x.x`). When enabled, this IP becomes the default connection host for all generated credentials.  
**ES** | El instalador puede configurar Tailscale opcionalmente para que el panel y las bases de datos solo sean accesibles a traves de una IP privada de VPN (ej. `100.x.x.x`). Cuando esta habilitado, esta IP se convierte en el host de conexion predeterminado para todas las credenciales generadas.

### How it works / Como funciona

1. **EN** | During installation the installer asks _"Install Tailscale?"_. Set `THL_INSTALL_TAILSCALE=1` to skip the prompt.  
   **ES** | Durante la instalacion se pregunta _"Instalar Tailscale?"_. Usar `THL_INSTALL_TAILSCALE=1` para omitir el prompt.

2. **EN** | `tailscale up` runs and prints an authentication URL. Open it in your browser to link the node.  
   **ES** | `tailscale up` se ejecuta y muestra una URL de autenticacion. Abrirla en el navegador para vincular el nodo.

3. **EN** | Once authenticated, the installer automatically:
   - Sets `PUBLIC_DB_HOST` to the Tailscale IP.
   - Updates `ALLOWED_ORIGINS` so the panel accepts requests via VPN.
   - Configures the firewall to allow Tailscale interface traffic.
   - Restarts `pg_manager` so the app serves the Tailscale IP in all connection strings.  
   **ES** | Una vez autenticado, el instalador automaticamente:
   - Establece `PUBLIC_DB_HOST` con la IP de Tailscale.
   - Actualiza `ALLOWED_ORIGINS` para que el panel acepte peticiones via VPN.
   - Configura el firewall para permitir trafico en la interfaz de Tailscale.
   - Reinicia `pg_manager` para que la app entregue la IP de Tailscale en todos los connection strings.

4. **EN** | Connection strings displayed in the panel will show `postgresql://user:pass@100.x.x.x:5432/db`.  
   **ES** | Los connection strings que se muestran en el panel indicaran `postgresql://user:pass@100.x.x.x:5432/db`.

### Docker + Tailscale

**EN** | In containers without systemd, the installer starts `tailscaled` in userspace networking mode automatically. No extra Docker flags are required.  
**ES** | En contenedores sin systemd, el instalador inicia `tailscaled` en modo userspace networking automaticamente. No se necesitan flags adicionales de Docker.

### Manual override / Override manual

**EN** | If Tailscale is already configured outside the installer, set these in `backend/.env`:  
**ES** | Si Tailscale ya esta configurado fuera del instalador, establecer en `backend/.env`:

```dotenv
PUBLIC_DB_HOST=100.x.x.x
PUBLIC_DB_HOST_SOURCE=tailscale
TAILSCALE_IP=100.x.x.x
```

---

## Installer Variables / Variables del Instalador

| Variable | Description / Descripcion |
|----------|--------------------------|
| `THL_DOMAIN` | Domain for HTTPS (certbot). Leave empty for IP mode. / Dominio para HTTPS. Dejar vacio para modo IP. |
| `THL_BIND_IP` | Bind IP for the panel. / IP de enlace del panel. |
| `THL_PORT` | Web port (default `80`). / Puerto web. |
| `THL_ADMIN_USER` | Admin username (default `admin`). / Usuario administrador. |
| `THL_ADMIN_PASS` | Admin password. Auto-generated if empty. / Contrasena admin. Se genera automaticamente si esta vacia. |
| `THL_PG_PASSWORD` | PostgreSQL password. Auto-generated if empty. / Contrasena PostgreSQL. |
| `THL_NONINTERACTIVE=1` | Skip all prompts. / Omitir todos los prompts. |
| `THL_UX_MODE=1` | Minimal prompts (default). / Prompts minimos. |
| `THL_INSTALL_TAILSCALE=1` | Install Tailscale without prompting. / Instalar Tailscale sin preguntar. |
| `THL_INSTALL_DEBUG=1` | Enable `set -x` trace. / Habilitar traza `set -x`. |
| `THL_INSTALL_LOG_FILE` | Log file path. / Ruta del archivo de log. |
| `THL_SYSTEM_UPGRADE_POLICY` | `none`, `upgrade`, or `full` (default). / Politica de actualizacion del sistema. |
| `THL_PRESERVE_EXISTING=1` | Keep credentials/config on upgrade (default). / Preservar credenciales al actualizar. |
| `THL_ACTION` | `reinstall`, `upgrade`, or `uninstall`. / Modo de instalacion. |
| `THL_FORCE=1` | Required for destructive non-interactive actions. / Requerido para acciones destructivas. |
| `THL_AUTO_CACHE_CLEAN=1` | Clear package/temp caches (default). / Limpiar caches automaticamente. |
| `PUBLIC_HOST` | Override public panel host (useful in Docker). / Override del host publico del panel. |
| `PUBLIC_PORT` | Override public panel port (useful in Docker). / Override del puerto publico del panel. |
| `PUBLIC_SCHEME` | `http` or `https` override. / Override del esquema. |
| `PANEL_URL` | Full panel URL override. / Override completo de la URL del panel. |
| `PUBLIC_DB_HOST` | SQL host shown in credentials. / Host SQL mostrado en credenciales. |
| `PUBLIC_DB_PORT` | SQL port shown in credentials. / Puerto SQL mostrado en credenciales. |
| `ALLOWED_PORTS` | Panel firewall policy (`*` = unrestricted). / Politica de firewall del panel. |
| `PROTECTED_PORTS` | Ports the panel cannot close/open. / Puertos que el panel no puede cerrar/abrir. |
| `CONTAINER_CPU_CORES` | Override CPU core count in containers. / Override de cores CPU en contenedores. |
| `CONTAINER_MEMORY_BYTES` | Override memory limit in containers (bytes). / Override de limite de memoria en contenedores. |

---

## Docker Usage / Uso con Docker

```bash
docker build -t thl-sql:local .
```

```bash
docker run -d \
  -p 8080:80 \
  -p 2222:22 \
  -p 5432:5432 \
  -e PUBLIC_HOST=localhost \
  -e PUBLIC_PORT=8080 \
  -e PUBLIC_DB_HOST=localhost \
  -e PUBLIC_DB_PORT=5432 \
  --name thl_sql_01 \
  thl-sql:local
```

**EN** | Then run the installer inside the container:  
**ES** | Luego ejecutar el instalador dentro del contenedor:

```bash
docker exec -it thl_sql_01 bash -lc 'THL_ACTION=reinstall THL_FORCE=1 bash /opt/thl-sql/install.sh --no-systemd'
```

Docker Compose:

```bash
docker compose up -d
docker compose exec thl-sql bash -lc 'THL_ACTION=reinstall THL_FORCE=1 bash /opt/thl-sql/install.sh --no-systemd'
```

### Docker Notes / Notas Docker

**EN**

- `Dockerfile` sets `PUBLIC_HOST=localhost`, `PUBLIC_PORT=80`, `PUBLIC_SCHEME=http`, `PUBLIC_DB_HOST=localhost`, `PUBLIC_DB_PORT=5432` as safe defaults.
- If the mapped host port differs from `80`, set `PUBLIC_PORT` explicitly.
- If the mapped SQL port differs from `5432`, set `PUBLIC_DB_PORT` explicitly.
- Inside Docker, the panel cannot publish new container ports; published ports come from `docker run -p` or Compose.
- SQL allowlists are enforced by HAProxy when no host firewall backend is available.
- Container CPU/RAM metrics read from cgroups. If detection fails, set `CONTAINER_CPU_CORES` and `CONTAINER_MEMORY_BYTES` env vars.

**ES**

- `Dockerfile` establece `PUBLIC_HOST=localhost`, `PUBLIC_PORT=80`, `PUBLIC_SCHEME=http`, `PUBLIC_DB_HOST=localhost`, `PUBLIC_DB_PORT=5432` como valores por defecto.
- Si el puerto mapeado en el host no es `80`, establecer `PUBLIC_PORT` explicitamente.
- Si el puerto SQL mapeado no es `5432`, establecer `PUBLIC_DB_PORT` explicitamente.
- Dentro de Docker, el panel no puede publicar puertos nuevos; los puertos publicados vienen de `docker run -p` o Compose.
- Las listas de acceso SQL son aplicadas por HAProxy cuando no hay firewall del host disponible.
- Las metricas de CPU/RAM del contenedor se leen desde cgroups. Si la deteccion falla, usar las variables `CONTAINER_CPU_CORES` y `CONTAINER_MEMORY_BYTES`.

---

## Dashboard Metrics / Metricas del Dashboard

**EN**

- On host installs, `/api/stats` uses `psutil` for CPU and memory.
- On container installs, `/api/stats` reads cgroup v1/v2 files for container-accurate metrics.
- Supports hybrid cgroup setups and walks up the cgroup hierarchy to find limits.
- Uses `os.sched_getaffinity()` as a fallback for CPU set detection.
- When cgroup detection fails, set `CONTAINER_CPU_CORES` and `CONTAINER_MEMORY_BYTES` as env var overrides.
- Startup logs print detected cgroup version, assigned cores, and memory limits for diagnostics.
- The dashboard cards show both current usage and assigned capacity.
- Refresh interval: 10 seconds.

**ES**

- En instalaciones host, `/api/stats` usa `psutil` para CPU y memoria.
- En instalaciones contenedor, `/api/stats` lee archivos cgroup v1/v2 para metricas precisas del contenedor.
- Soporta configuraciones hibridas de cgroup y recorre la jerarquia cgroup buscando limites.
- Usa `os.sched_getaffinity()` como fallback para deteccion de CPU set.
- Si la deteccion de cgroup falla, usar `CONTAINER_CPU_CORES` y `CONTAINER_MEMORY_BYTES` como variables de entorno.
- Los logs de inicio imprimen la version de cgroup detectada, cores asignados y limites de memoria para diagnostico.
- Las tarjetas del dashboard muestran uso actual y capacidad asignada.
- Intervalo de refresco: 10 segundos.

---

## Firewall Behavior / Comportamiento del Firewall

**EN**

- On host installs, the installer configures the native firewall safely and keeps existing rules intact.
- Debian/Ubuntu: `ufw --force enable` for non-interactive installation.
- RHEL-family: uses the current firewalld default zone.
- Legacy `ALLOWED_PORTS=22,80,443,5432` is treated as unrestricted behavior for backwards compatibility.
- Protected ports (SSH, web, SQL) are blocked from direct close/open operations in the UI.
- In containers, SQL IP restrictions work through HAProxy ACLs.
- When Tailscale is enabled, the Tailscale interface (`tailscale0`) is allowed through the firewall automatically.

**ES**

- En instalaciones host, el instalador configura el firewall nativo de forma segura y preserva reglas existentes.
- Debian/Ubuntu: `ufw --force enable` para instalacion no interactiva.
- Familia RHEL: usa la zona por defecto actual de firewalld.
- El valor legacy `ALLOWED_PORTS=22,80,443,5432` se trata como comportamiento sin restriccion por compatibilidad.
- Puertos protegidos (SSH, web, SQL) estan bloqueados de operaciones directas de cierre/apertura en la UI.
- En contenedores, las restricciones de IP de SQL funcionan a traves de ACLs de HAProxy.
- Cuando Tailscale esta habilitado, la interfaz de Tailscale (`tailscale0`) se permite en el firewall automaticamente.

---

## Troubleshooting / Solucion de Problemas

**EN** | If the installer stops at `[1/11]`, re-run in debug mode:  
**ES** | Si el instalador se detiene en `[1/11]`, re-ejecutar en modo debug:

```bash
THL_INSTALL_DEBUG=1 \
THL_INSTALL_LOG_FILE=/var/log/thl-sql-install.log \
  curl -fsSL https://raw.githubusercontent.com/thl-corporation/thl-sql/main/install.sh | bash
```

```bash
# Quick diagnostics / Diagnosticos rapidos
tail -n 120 /var/log/thl-sql-install.log
journalctl -u pg_manager -n 80 --no-pager
```

### Domain notes / Notas de dominio

- **EN** | If `THL_DOMAIN` is set, installer uses HTTPS with certbot. If empty, IP mode (`http://IP:PORT`).
- **ES** | Si `THL_DOMAIN` esta definido, el instalador usa HTTPS con certbot. Si esta vacio, modo IP (`http://IP:PUERTO`).

### Preflight on Ubuntu / Preflight en Ubuntu

```bash
id -u          # must be 0 (root) / debe ser 0 (root)
systemctl --version
```

---

## Update Existing Server / Actualizar Servidor Existente

```bash
cd /var/www/pg_manager && git pull origin main && bash deploy_remote.sh
```

**EN** | `deploy_remote.sh` preserves Tailscale configuration during upgrades automatically.  
**ES** | `deploy_remote.sh` preserva la configuracion de Tailscale durante actualizaciones automaticamente.

---

## Technical Validation / Validacion Tecnica

**EN** | On the VPS:  
**ES** | En el VPS:

```bash
cd /var/www/pg_manager
source venv/bin/activate
python verify_deployment.py
python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8
bash server/run_test_suite.sh
```

**EN** | From an external client:  
**ES** | Desde un cliente externo:

```bash
python verify_remote.py
```

---

## Repository Sync / Sincronizacion de Repositorios

```powershell
./push_dual_repos.ps1              # push to both repos / push a ambos repos
./push_dual_repos.ps1 -DryRun     # validate without publishing / validar sin publicar
```

**EN** | Targets: `thl-corporation/thl-sql` (corp) and `thl-corporation-spa/thl-sql` (SPA mirror).  
**ES** | Destinos: `thl-corporation/thl-sql` (corp) y `thl-corporation-spa/thl-sql` (mirror SPA).

Environment overrides: `THL_SQL_CORP_SSH_KEY`, `THL_SQL_SPA_REPO_URL`, `THL_SQL_SPA_LEGACY_REPO_URL`, `THL_SQL_CORP_REPO_URL`.

---

## Publication Safety / Seguridad de Publicacion

**EN** | No real secrets are stored in git. Sensitive values use `*.example` templates. Keys and credentials are blocked in `.gitignore`.  
**ES** | No se almacenan secretos reales en git. Los valores sensibles usan plantillas `*.example`. Claves y credenciales estan bloqueadas en `.gitignore`.

```bash
bash server/check_repo_safety.sh
```

---

## Documentation / Documentacion

- `docs/INSTALL_LINUX_MULTI_DISTRO.md`
- `docs/REPLICAR_EN_OTRO_VPS.md`
- `docs/PRUEBA_1000_CONEXIONES.md`
- `INSTRUCCIONES_UPDATE_VPS.md`
- `INSTRUCCIONES_TEST_REMOTO.md`
