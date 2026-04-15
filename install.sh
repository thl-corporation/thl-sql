#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export LANG=C

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_DIR="${APP_DIR:-/var/www/pg_manager}"
THL_REPO_URL="${THL_REPO_URL:-https://github.com/thl-corporation/thl-sql.git}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/opt/thl-sql-installer}"
THL_INSTALL_DEBUG="${THL_INSTALL_DEBUG:-0}"
THL_INSTALL_LOG_FILE="${THL_INSTALL_LOG_FILE:-/var/log/thl-sql-install.log}"
THL_SYSTEM_UPGRADE_POLICY="${THL_SYSTEM_UPGRADE_POLICY:-full}"
THL_INSTALL_LOG_INITIALIZED="${THL_INSTALL_LOG_INITIALIZED:-0}"
THL_UX_MODE="${THL_UX_MODE:-1}"
THL_INSTALL_SUMMARY_FILE="${THL_INSTALL_SUMMARY_FILE:-/root/thl-sql-install-summary.txt}"
THL_PRESERVE_EXISTING="${THL_PRESERVE_EXISTING:-1}"
THL_ACTION="${THL_ACTION:-}"
THL_FORCE="${THL_FORCE:-0}"
THL_AUTO_CACHE_CLEAN="${THL_AUTO_CACHE_CLEAN:-1}"
THL_NO_SYSTEMD="${THL_NO_SYSTEMD:-0}"
THL_PYTHON_BIN="${THL_PYTHON_BIN:-}"
THL_INSTALL_TAILSCALE="${THL_INSTALL_TAILSCALE:-}"
TAILSCALE_IP=""
PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
PUBLIC_SCHEME="${PUBLIC_SCHEME:-}"
PANEL_URL="${PANEL_URL:-}"
PUBLIC_DB_HOST="${PUBLIC_DB_HOST:-}"
PUBLIC_DB_PORT="${PUBLIC_DB_PORT:-}"
PUBLIC_DB_HOST_SOURCE="${PUBLIC_DB_HOST_SOURCE:-}"
FIREWALL_BACKEND=""
OS_FAMILY=""
PKG_TOOL=""
RUNTIME_ENV=""
SERVICE_MANAGER=""
NGINX_CONF_FILE="/etc/nginx/conf.d/pg_manager.conf"
CRON_WATCHDOG_FILE="/etc/cron.d/thl_sql_watchdog"
POSTGRES_INTERNAL_PORT="${POSTGRES_INTERNAL_PORT:-5433}"
PGBOUNCER_INTERNAL_PORT="${PGBOUNCER_INTERNAL_PORT:-6432}"
BACKEND_BIND_PORT="${BACKEND_BIND_PORT:-8000}"
ADMIN_PASSWORD_GENERATED="0"
ADMIN_PASSWORD_SOURCE="pending"
UX_MODE_ACTIVE="0"
EXISTING_INSTALL="0"
EXISTING_ENV_FILE="${APP_DIR}/backend/.env"
EXISTING_ENV_BACKUP=""
INSTALL_ACTION="upgrade"
CURRENT_STEP_INDEX="preflight"
CURRENT_STEP_NAME="inicio"
FAILURE_REPORT_FILE=""
PYTHON_VENV_BIN=""
PG_MANAGER_PID_FILE="/run/pg_manager.pid"
PG_MANAGER_LOG_FILE="/var/log/pg_manager.log"
PG_HBA_MANAGED_START="# BEGIN THL SQL MANAGED RULES"
PG_HBA_MANAGED_END="# END THL SQL MANAGED RULES"
PANEL_URL_OVERRIDE_DETECTED="0"

log() {
    echo -e "${CYAN}$*${NC}"
}

warn() {
    echo -e "${YELLOW}$*${NC}"
}

die() {
    echo -e "${RED}$*${NC}"
    exit 1
}

parse_cli_args() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --no-systemd)
                THL_NO_SYSTEMD="1"
                ;;
            --help|-h)
                cat <<'EOF'
Uso: install.sh [--no-systemd]

Opciones:
  --no-systemd   Fuerza el modo compatible con 'service' en lugar de systemd.
  --help         Muestra esta ayuda.
EOF
                exit 0
                ;;
            *)
                warn "Argumento no reconocido: ${arg}"
                ;;
        esac
    done
}

is_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

is_container_environment() {
    [ -f /.dockerenv ] && return 0
    [ -f /run/.containerenv ] && return 0
    grep -qaE '(docker|containerd|kubepods|podman|lxc)' /proc/1/cgroup 2>/dev/null && return 0
    grep -qaE '(docker|containerd|kubepods|podman|lxc)' /proc/1/environ 2>/dev/null && return 0
    return 1
}

detect_runtime_context() {
    if is_container_environment; then
        RUNTIME_ENV="container"
    else
        RUNTIME_ENV="host"
    fi

    if [ "${THL_NO_SYSTEMD}" = "1" ]; then
        if command -v service >/dev/null 2>&1; then
            SERVICE_MANAGER="service"
        else
            SERVICE_MANAGER=""
        fi
    elif is_systemd_available; then
        SERVICE_MANAGER="systemd"
    elif command -v service >/dev/null 2>&1; then
        SERVICE_MANAGER="service"
    else
        SERVICE_MANAGER=""
    fi

    log "Entorno detectado: ${RUNTIME_ENV}"
    log "Gestor de servicios detectado: ${SERVICE_MANAGER:-ninguno}"
}

resolve_panel_url() {
    local default_scheme=""
    local default_host=""
    local default_port=""

    PANEL_URL_OVERRIDE_DETECTED="0"
    if [ -n "${PANEL_URL:-}" ] || [ -n "${PUBLIC_HOST:-}" ] || [ -n "${PUBLIC_PORT:-}" ] || [ -n "${PUBLIC_SCHEME:-}" ]; then
        PANEL_URL_OVERRIDE_DETECTED="1"
    fi

    if [ "${USE_DOMAIN:-false}" = "true" ]; then
        default_scheme="https"
        default_host="${DOMAIN}"
        default_port="443"
    elif [ "${RUNTIME_ENV}" = "container" ]; then
        default_scheme="http"
        default_host="localhost"
        default_port="80"
    else
        default_scheme="http"
        default_host="${BIND_IP:-${PUBLIC_DB_HOST:-${SERVER_IP:-127.0.0.1}}}"
        default_port="${WEB_PORT:-80}"
    fi

    PUBLIC_SCHEME="${PUBLIC_SCHEME:-${default_scheme}}"
    PUBLIC_HOST="${PUBLIC_HOST:-${default_host}}"
    PUBLIC_PORT="${PUBLIC_PORT:-${default_port}}"

    if [ -n "${PANEL_URL:-}" ]; then
        return
    fi

    PANEL_URL="${PUBLIC_SCHEME}://${PUBLIC_HOST}:${PUBLIC_PORT}"
}

print_container_panel_url_warning() {
    if [ "${RUNTIME_ENV}" != "container" ] || [ "${PANEL_URL_OVERRIDE_DETECTED}" = "1" ]; then
        return
    fi

    warn "ADVERTENCIA: Detectado entorno Docker. La URL mostrada usa localhost:80 por defecto."
    warn "Verifica el mapeo real con: docker port <contenedor>"
    warn "Puedes fijarla con: PUBLIC_HOST=tu-host PUBLIC_PORT=8080 PUBLIC_SCHEME=http o PANEL_URL completo."
}

write_container_panel_url_warning() {
    if [ "${RUNTIME_ENV}" != "container" ] || [ "${PANEL_URL_OVERRIDE_DETECTED}" = "1" ]; then
        return
    fi

    echo "Advertencia: Detectado entorno Docker. La URL mostrada usa localhost:80 por defecto."
    echo "Verifica el mapeo real con: docker port <contenedor>"
    echo "Puedes fijarla con: PUBLIC_HOST=tu-host PUBLIC_PORT=8080 PUBLIC_SCHEME=http o PANEL_URL completo."
}

require_runtime_support() {
    if [ -n "${SERVICE_MANAGER}" ]; then
        return
    fi

    if [ "${THL_NO_SYSTEMD}" = "1" ]; then
        die "Se forzo modo sin systemd, pero no existe el comando 'service'. Instala init-system-helpers/sysvinit o ejecuta en un host con systemd."
    fi

    die "No se detecto un gestor de servicios compatible. Este instalador necesita systemd o el comando 'service'."
}

service_script_name() {
    local service="$1"
    case "${service}" in
        postgresql@*-main)
            echo "postgresql"
            ;;
        *)
            echo "${service}"
            ;;
    esac
}

service_script_exists() {
    local service="$1"
    local script_name
    script_name="$(service_script_name "${service}")"
    [ -f "/etc/init.d/${script_name}" ] || [ -x "/etc/init.d/${script_name}" ]
}

service_is_active() {
    local service="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl is-active --quiet "${service}"
        return
    fi

    script_name="$(service_script_name "${service}")"
    if ! command -v service >/dev/null 2>&1 || ! service_script_exists "${script_name}"; then
        return 1
    fi
    service "${script_name}" status >/dev/null 2>&1
}

start_service() {
    local service="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl start "${service}" >/dev/null 2>&1 || true
        return
    fi

    script_name="$(service_script_name "${service}")"
    if command -v service >/dev/null 2>&1 && service_script_exists "${script_name}"; then
        service "${script_name}" start >/dev/null 2>&1 || true
    fi
}

restart_service() {
    local service="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl restart "${service}" >/dev/null 2>&1 || true
        return
    fi

    script_name="$(service_script_name "${service}")"
    if command -v service >/dev/null 2>&1 && service_script_exists "${script_name}"; then
        service "${script_name}" restart >/dev/null 2>&1 || true
    fi
}

reload_service() {
    local service="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl reload "${service}" >/dev/null 2>&1 || systemctl restart "${service}" >/dev/null 2>&1 || true
        return
    fi

    script_name="$(service_script_name "${service}")"
    if command -v service >/dev/null 2>&1 && service_script_exists "${script_name}"; then
        service "${script_name}" reload >/dev/null 2>&1 || service "${script_name}" restart >/dev/null 2>&1 || true
    fi
}

stop_service() {
    local service="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl stop "${service}" >/dev/null 2>&1 || true
        return
    fi

    script_name="$(service_script_name "${service}")"
    if command -v service >/dev/null 2>&1 && service_script_exists "${script_name}"; then
        service "${script_name}" stop >/dev/null 2>&1 || true
    fi
}

enable_service_if_exists() {
    local service="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        if systemctl list-unit-files | grep -q "^${service}\.service"; then
            systemctl enable --now "${service}" >/dev/null 2>&1 || true
        fi
        return
    fi

    script_name="$(service_script_name "${service}")"
    if command -v service >/dev/null 2>&1 && service_script_exists "${script_name}"; then
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "${script_name}" defaults >/dev/null 2>&1 || true
        fi
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --add "${script_name}" >/dev/null 2>&1 || true
            chkconfig "${script_name}" on >/dev/null 2>&1 || true
        fi
        service "${script_name}" start >/dev/null 2>&1 || true
    fi
}

get_debian_main_cluster_version() {
    if ! command -v pg_lsclusters >/dev/null 2>&1; then
        return 0
    fi
    pg_lsclusters --no-header 2>/dev/null | awk '$2=="main" {print $1; exit}'
}

get_debian_main_cluster_port() {
    if ! command -v pg_lsclusters >/dev/null 2>&1; then
        return 0
    fi
    pg_lsclusters --no-header 2>/dev/null | awk '$2=="main" && $3 ~ /^[0-9]+$/ {print $3; exit}'
}

debian_cluster_exists() {
    local cluster_version="$1"
    local cluster_name="${2:-main}"
    command -v pg_lsclusters >/dev/null 2>&1 || return 1
    pg_lsclusters --no-header 2>/dev/null | awk -v ver="${cluster_version}" -v name="${cluster_name}" '$1==ver && $2==name {found=1} END {exit(found ? 0 : 1)}'
}

postgres_service_unit() {
    local cluster_version
    cluster_version="$(get_debian_main_cluster_version || true)"
    if [ -n "${cluster_version}" ]; then
        echo "postgresql@${cluster_version}-main"
        return
    fi
    echo "postgresql"
}

show_postgres_diagnostics() {
    local unit cluster_version pg_log pg_hba pg_conf
    unit="$(postgres_service_unit)"
    cluster_version="$(get_debian_main_cluster_version || true)"

    if [ "${SERVICE_MANAGER}" = "systemd" ] && is_systemd_available; then
        echo "--- systemctl status ${unit} ---"
        systemctl status "${unit}" --no-pager -l 2>/dev/null || true
        echo "--- journalctl -xeu ${unit} (last 100) ---"
        journalctl -xeu "${unit}" --no-pager -n 100 2>/dev/null || true
    elif [ "${SERVICE_MANAGER}" = "service" ] && command -v service >/dev/null 2>&1; then
        echo "--- service postgresql status ---"
        service postgresql status 2>/dev/null || true
    fi

    if command -v pg_lsclusters >/dev/null 2>&1; then
        echo "[pg_lsclusters]"
        pg_lsclusters || true
    fi

    if [ -n "${cluster_version}" ]; then
        pg_log="/var/log/postgresql/postgresql-${cluster_version}-main.log"
        if [ -f "${pg_log}" ]; then
            echo "--- ${pg_log} (last 200) ---"
            tail -n 200 "${pg_log}" || true
        fi
    fi

    echo "[Network ports]"
    ss -tlnp 2>/dev/null | grep -E "5432|${POSTGRES_INTERNAL_PORT}|${PGBOUNCER_INTERNAL_PORT}|${BACKEND_BIND_PORT}" || true

    pg_hba="$(find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1 || true)"
    pg_conf="$(find /etc/postgresql /var/lib/pgsql -name postgresql.conf 2>/dev/null | head -1 || true)"
    if [ -n "${pg_hba}" ] && [ -f "${pg_hba}" ]; then
        echo "--- ${pg_hba} ---"
        cat "${pg_hba}" || true
    fi
    if [ -n "${pg_conf}" ] && [ -f "${pg_conf}" ]; then
        echo "--- ${pg_conf} ---"
        cat "${pg_conf}" || true
    fi
}

wait_for_tcp_port() {
    local port="$1"
    local retries="${2:-90}"
    local i

    for i in $(seq 1 "${retries}"); do
        if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|\\]|:)${port}$"; then
            return 0
        fi
        sleep 1
    done

    return 1
}

wait_for_service_active() {
    local unit="$1"
    local retries="${2:-60}"
    local i

    for i in $(seq 1 "${retries}"); do
        if service_is_active "${unit}"; then
            return 0
        fi
        sleep 1
    done

    return 1
}

show_systemd_unit_logs() {
    local unit="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ] && is_systemd_available; then
        echo "--- systemctl status ${unit} ---"
        systemctl status "${unit}" --no-pager -l 2>/dev/null || true
        echo "--- journalctl -u ${unit} (last 120) ---"
        journalctl -u "${unit}" --no-pager -n 120 2>/dev/null || true
        return 0
    fi

    if ! command -v service >/dev/null 2>&1; then
        return 0
    fi

    script_name="$(service_script_name "${unit}")"
    echo "--- service ${script_name} status ---"
    service "${script_name}" status 2>/dev/null || true

    case "${script_name}" in
        pg_manager)
            if [ -f "${PG_MANAGER_LOG_FILE}" ]; then
                echo "--- ${PG_MANAGER_LOG_FILE} (last 120) ---"
                tail -n 120 "${PG_MANAGER_LOG_FILE}" || true
            fi
            ;;
        pgbouncer)
            if [ -f /var/log/pgbouncer/pgbouncer.log ]; then
                echo "--- /var/log/pgbouncer/pgbouncer.log (last 120) ---"
                tail -n 120 /var/log/pgbouncer/pgbouncer.log || true
            fi
            ;;
    esac
}

reload_or_restart_postgres_runtime() {
    local cluster_version

    cluster_version="$(get_debian_main_cluster_version || true)"
    if [ -n "${cluster_version}" ] && command -v pg_ctlcluster >/dev/null 2>&1; then
        pg_ctlcluster "${cluster_version}" main reload >/dev/null 2>&1 || \
            pg_ctlcluster "${cluster_version}" main restart >/dev/null 2>&1 || true
        return
    fi

    reload_service "$(postgres_service_unit)"
}

extract_pg_hba_managed_rules() {
    local source_file="$1"
    local target_file="$2"

    : > "${target_file}"
    [ -f "${source_file}" ] || return 0

    awk -v start="${PG_HBA_MANAGED_START}" -v end="${PG_HBA_MANAGED_END}" '
        $0 == start {capture=1; next}
        $0 == end {capture=0; next}
        capture {print}
    ' "${source_file}" > "${target_file}" 2>/dev/null || true
}

rewrite_pg_hba_managed_block() {
    local pg_hba_path="$1"
    local managed_rules_file="$2"
    local tmp_file

    tmp_file="$(mktemp /tmp/thl-sql-pg-hba.XXXXXX)"
    awk -v start="${PG_HBA_MANAGED_START}" -v end="${PG_HBA_MANAGED_END}" -v rules="${managed_rules_file}" '
        BEGIN { inside=0; replaced=0 }
        $0 == start {
            print start
            while ((getline line < rules) > 0) {
                print line
            }
            close(rules)
            print end
            inside=1
            replaced=1
            next
        }
        $0 == end {
            inside=0
            next
        }
        inside { next }
        { print }
        END {
            if (!replaced) {
                if (NR > 0) {
                    print ""
                }
                print start
                while ((getline line < rules) > 0) {
                    print line
                }
                close(rules)
                print end
            }
        }
    ' "${pg_hba_path}" > "${tmp_file}"
    cat "${tmp_file}" > "${pg_hba_path}"
    rm -f "${tmp_file}"
}

prepare_pg_hba_managed_rules() {
    local pg_hba_path="$1"
    local legacy_include_path="$2"
    local include_line="include_if_exists ${legacy_include_path}"
    local quoted_include_line="include_if_exists '${legacy_include_path}'"
    local tmp_clean rules_file current_rules_file

    tmp_clean="$(mktemp /tmp/thl-sql-pg-hba-clean.XXXXXX)"
    rules_file="$(mktemp /tmp/thl-sql-pg-hba-rules.XXXXXX)"
    current_rules_file="$(mktemp /tmp/thl-sql-pg-hba-current.XXXXXX)"

    extract_pg_hba_managed_rules "${pg_hba_path}" "${current_rules_file}"
    if [ -s "${current_rules_file}" ]; then
        cat "${current_rules_file}" > "${rules_file}"
    elif [ -f "${legacy_include_path}" ]; then
        cat "${legacy_include_path}" > "${rules_file}"
    else
        : > "${rules_file}"
    fi

    grep -Fvx "${include_line}" "${pg_hba_path}" | grep -Fvx "${quoted_include_line}" > "${tmp_clean}" || true
    cat "${tmp_clean}" > "${pg_hba_path}"

    rewrite_pg_hba_managed_block "${pg_hba_path}" "${rules_file}"

    rm -f "${tmp_clean}" "${rules_file}" "${current_rules_file}"
}

select_python_for_venv() {
    local candidate py_version

    if [ -n "${THL_PYTHON_BIN}" ]; then
        if ! command -v "${THL_PYTHON_BIN}" >/dev/null 2>&1; then
            die "THL_PYTHON_BIN=${THL_PYTHON_BIN} no existe en PATH."
        fi
        PYTHON_VENV_BIN="${THL_PYTHON_BIN}"
        return
    fi

    for candidate in python3.12 python3.11 python3; do
        if ! command -v "${candidate}" >/dev/null 2>&1; then
            continue
        fi
        if ! "${candidate}" -m venv --help >/dev/null 2>&1; then
            continue
        fi
        py_version="$("${candidate}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
        case "${py_version}" in
            3.10|3.11|3.12|3.13)
                PYTHON_VENV_BIN="${candidate}"
                log "Python seleccionado para venv: ${candidate} (${py_version})"
                return
                ;;
        esac
    done

    die "No se encontro un interprete Python compatible para crear el venv."
}

collect_failure_diagnostics() {
    local exit_code="${1:-1}"
    local line_no="${2:-unknown}"
    local failed_command="${3:-unknown}"
    local ts
    local postgres_unit

    postgres_unit="$(postgres_service_unit)"

    ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
    FAILURE_REPORT_FILE="/var/log/thl-sql-failure-${ts}.log"

    mkdir -p /var/log >/dev/null 2>&1 || true

    {
        echo "=== THL SQL Failure Diagnostics ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
        echo "Step: ${CURRENT_STEP_INDEX} - ${CURRENT_STEP_NAME}"
        echo "Line: ${line_no}"
        echo "Exit code: ${exit_code}"
        echo "Failed command: ${failed_command}"
        echo ""
        echo "[System]"
        uname -a || true
        [ -f /etc/os-release ] && cat /etc/os-release || true
        echo ""
        echo "[Resources]"
        df -h || true
        free -m || true
        echo ""
        echo "[Service State]"
        if [ "${SERVICE_MANAGER}" = "systemd" ] && is_systemd_available; then
            systemctl is-active "${postgres_unit}" pgbouncer haproxy pg_manager nginx 2>/dev/null || true
            for svc in "${postgres_unit}" pgbouncer haproxy pg_manager nginx; do
                echo ""
                echo "--- systemctl status ${svc} ---"
                systemctl status "${svc}" --no-pager -l 2>/dev/null || true
                echo "--- journalctl -u ${svc} (last 120) ---"
                journalctl -u "${svc}" --no-pager -n 120 2>/dev/null || true
            done
        elif [ "${SERVICE_MANAGER}" = "service" ] && command -v service >/dev/null 2>&1; then
            for svc in postgresql pgbouncer haproxy pg_manager nginx; do
                echo ""
                echo "--- service ${svc} status ---"
                service "${svc}" status 2>/dev/null || true
            done
        else
            echo "No hay gestor de servicios disponible para diagnostico detallado."
        fi
        echo ""
        echo "[PostgreSQL diagnostics]"
        show_postgres_diagnostics
    } > "${FAILURE_REPORT_FILE}" 2>&1

    warn "Diagnostico de fallo generado: ${FAILURE_REPORT_FILE}"
}

on_error() {
    local exit_code="$?"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local failed_command="${BASH_COMMAND:-unknown}"

    trap - ERR
    set +e
    collect_failure_diagnostics "${exit_code}" "${line_no}" "${failed_command}"

    echo -e "${RED}Error: fallo en linea ${line_no} (exit ${exit_code}): ${failed_command}${NC}" >&2
    echo -e "${YELLOW}Paso actual: ${CURRENT_STEP_INDEX} - ${CURRENT_STEP_NAME}${NC}" >&2
    if [ -n "${THL_INSTALL_LOG_FILE:-}" ]; then
        echo -e "${YELLOW}Log principal: ${THL_INSTALL_LOG_FILE}${NC}" >&2
    fi
    if [ -n "${FAILURE_REPORT_FILE:-}" ]; then
        echo -e "${YELLOW}Diagnostico: ${FAILURE_REPORT_FILE}${NC}" >&2
    fi
    exit "${exit_code}"
}

trap 'on_error' ERR

run_install_step() {
    local step_index="$1"
    local step_name="$2"
    local step_fn="$3"
    local start_ts end_ts elapsed

    CURRENT_STEP_INDEX="${step_index}"
    CURRENT_STEP_NAME="${step_name}"
    start_ts="$(date +%s)"

    log "[STEP ${step_index}] ${step_name}"
    "${step_fn}"

    end_ts="$(date +%s)"
    elapsed=$((end_ts - start_ts))
    echo -e "${GREEN}[OK] Paso ${step_index}: ${step_name} (${elapsed}s)${NC}"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Error: ejecuta este script como root."
    fi
}

require_systemd() {
    require_runtime_support
}

validate_install_settings() {
    case "${THL_INSTALL_DEBUG}" in
        0|1) ;;
        *)
            die "Valor invalido THL_INSTALL_DEBUG=${THL_INSTALL_DEBUG}. Usa 0 o 1."
            ;;
    esac

    case "${THL_SYSTEM_UPGRADE_POLICY}" in
        none|upgrade|full) ;;
        *)
            die "Valor invalido THL_SYSTEM_UPGRADE_POLICY=${THL_SYSTEM_UPGRADE_POLICY}. Usa none, upgrade o full."
            ;;
    esac

    case "${THL_UX_MODE}" in
        0|1) ;;
        *)
            die "Valor invalido THL_UX_MODE=${THL_UX_MODE}. Usa 0 o 1."
            ;;
    esac

    case "${THL_PRESERVE_EXISTING}" in
        0|1) ;;
        *)
            die "Valor invalido THL_PRESERVE_EXISTING=${THL_PRESERVE_EXISTING}. Usa 0 o 1."
            ;;
    esac

    case "${THL_FORCE}" in
        0|1) ;;
        *)
            die "Valor invalido THL_FORCE=${THL_FORCE}. Usa 0 o 1."
            ;;
    esac

    case "${THL_AUTO_CACHE_CLEAN}" in
        0|1) ;;
        *)
            die "Valor invalido THL_AUTO_CACHE_CLEAN=${THL_AUTO_CACHE_CLEAN}. Usa 0 o 1."
            ;;
    esac

    case "${THL_NO_SYSTEMD}" in
        0|1) ;;
        *)
            die "Valor invalido THL_NO_SYSTEMD=${THL_NO_SYSTEMD}. Usa 0 o 1."
            ;;
    esac

    if [ -n "${THL_ACTION}" ]; then
        case "${THL_ACTION}" in
            reinstall|upgrade|uninstall) ;;
            *)
                die "Valor invalido THL_ACTION=${THL_ACTION}. Usa reinstall, upgrade o uninstall."
                ;;
        esac
    fi
}

init_install_logging() {
    if [ "${THL_INSTALL_LOG_INITIALIZED}" = "1" ]; then
        if [ "${THL_INSTALL_DEBUG}" = "1" ]; then
            set -x
        fi
        return
    fi

    mkdir -p "$(dirname "${THL_INSTALL_LOG_FILE}")"
    touch "${THL_INSTALL_LOG_FILE}"
    chmod 600 "${THL_INSTALL_LOG_FILE}" || true

    exec > >(tee -a "${THL_INSTALL_LOG_FILE}") 2>&1
    export THL_INSTALL_LOG_INITIALIZED=1

    log "Log de instalacion: ${THL_INSTALL_LOG_FILE}"
    if [ "${THL_INSTALL_DEBUG}" = "1" ]; then
        log "Modo debug habilitado (THL_INSTALL_DEBUG=1)."
        set -x
    fi
}

has_tty() {
    [ -r /dev/tty ] && [ -w /dev/tty ]
}

get_existing_env_source() {
    if [ -n "${EXISTING_ENV_BACKUP}" ] && [ -f "${EXISTING_ENV_BACKUP}" ]; then
        echo "${EXISTING_ENV_BACKUP}"
        return
    fi
    if [ -f "${EXISTING_ENV_FILE}" ]; then
        echo "${EXISTING_ENV_FILE}"
        return
    fi
    echo ""
}

existing_env_value() {
    local key="$1"
    local source_file
    source_file="$(get_existing_env_source)"
    if [ -z "${source_file}" ] || [ ! -f "${source_file}" ]; then
        return 0
    fi
    grep -m1 "^${key}=" "${source_file}" | cut -d'=' -f2- || true
}

set_env_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp_file
    if grep -q "^${key}=" "${file}" 2>/dev/null; then
        tmp_file="$(mktemp "${file}.XXXXXX")"
        awk -v k="${key}" -v v="${value}" '{
            pos = index($0, "=")
            if (pos > 0 && substr($0, 1, pos - 1) == k) {
                print k "=" v
            } else {
                print
            }
        }' "${file}" > "${tmp_file}"
        mv "${tmp_file}" "${file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    fi
}

ensure_env_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    if ! grep -q "^${key}=" "${file}"; then
        printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    fi
}

managed_allowed_ports_value() {
    local current_value="$1"
    case "${current_value}" in
        ""|"22,80,443,5432")
            echo "*"
            ;;
        *)
            echo "${current_value}"
            ;;
    esac
}

managed_protected_ports_value() {
    printf '22,80,443,%s,5432\n' "${WEB_PORT}"
}

detect_firewalld_zone() {
    if [ -n "${THL_FIREWALLD_ZONE:-}" ]; then
        echo "${THL_FIREWALLD_ZONE}"
        return
    fi
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "public"
        return
    fi
    firewall-cmd --get-default-zone 2>/dev/null || echo "public"
}

extract_http_port_from_origins() {
    local origins="$1"
    printf '%s\n' "${origins}" | tr ',' '\n' | sed -n 's#^http://[^:]\+:\([0-9][0-9]*\).*$#\1#p' | head -1
}

detect_existing_installation() {
    if [ ! -f "${EXISTING_ENV_FILE}" ]; then
        return
    fi

    EXISTING_INSTALL="1"
    if [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
        EXISTING_ENV_BACKUP="$(mktemp /tmp/thl-sql-existing-env.XXXXXX)"
        cp "${EXISTING_ENV_FILE}" "${EXISTING_ENV_BACKUP}"
        chmod 600 "${EXISTING_ENV_BACKUP}" || true
        log "Instalacion existente detectada. Se preservaran credenciales/configuracion."
    else
        warn "Instalacion existente detectada. THL_PRESERVE_EXISTING=0, se aplicara reconfiguracion completa."
    fi
}

auto_cleanup_cache() {
    if [ "${THL_AUTO_CACHE_CLEAN}" != "1" ]; then
        return
    fi

    log "Limpieza automatica de cache/temporales..."
    rm -rf /tmp/thl-sql-bootstrap.* /tmp/thl-sql-existing-env.* 2>/dev/null || true

    if [ "${PKG_TOOL}" = "apt" ]; then
        apt-get clean >/dev/null 2>&1 || true
        rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    elif [ "${PKG_TOOL}" = "dnf" ]; then
        dnf clean all >/dev/null 2>&1 || true
    else
        yum clean all >/dev/null 2>&1 || true
    fi

    if command -v pip3 >/dev/null 2>&1; then
        pip3 cache purge >/dev/null 2>&1 || true
    fi
    rm -rf /root/.cache/pip 2>/dev/null || true
}

run_as_postgres() {
    local cmd="$1"
    local postgres_cwd="/tmp"
    if command -v getent >/dev/null 2>&1; then
        postgres_cwd="$(getent passwd postgres | cut -d: -f6 || true)"
    fi
    if [ -z "${postgres_cwd}" ] || [ ! -d "${postgres_cwd}" ]; then
        postgres_cwd="/tmp"
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- sh -c "cd \"${postgres_cwd}\" && ${cmd}"
        return
    fi
    su -s /bin/sh postgres -c "cd \"${postgres_cwd}\" && ${cmd}"
}

detect_active_postgres_port() {
    local retries="${1:-12}"
    local sleep_sec="${2:-1}"
    local attempt candidate cluster_port
    local -a candidates=("${POSTGRES_INTERNAL_PORT}" 5432 5433 5434 5435)

    for attempt in $(seq 1 "${retries}"); do
        if [ "${OS_FAMILY}" = "debian" ] && command -v pg_lsclusters >/dev/null 2>&1; then
            cluster_port="$(pg_lsclusters --no-header 2>/dev/null | awk '$2=="main" && $4=="online" && $3 ~ /^[0-9]+$/ {print $3; exit}')"
            if [ -n "${cluster_port}" ]; then
                echo "${cluster_port}"
                return 0
            fi

            cluster_port="$(pg_lsclusters --no-header 2>/dev/null | awk '$4=="online" && $3 ~ /^[0-9]+$/ {print $3; exit}')"
            if [ -n "${cluster_port}" ]; then
                echo "${cluster_port}"
                return 0
            fi
        fi

        for candidate in "${candidates[@]}"; do
            if run_as_postgres "psql -p \"${candidate}\" -Atqc \"select 1\"" >/dev/null 2>&1; then
                echo "${candidate}"
                return 0
            fi
        done

        if run_as_postgres "psql -Atqc \"show port\"" >/dev/null 2>&1; then
            run_as_postgres "psql -Atqc \"show port\"" | head -1
            return 0
        fi

        sleep "${sleep_sec}"
    done

    return 1
}

wait_for_postgres_access() {
    local port="$1"
    local retries="${2:-90}"
    local i
    for i in $(seq 1 "${retries}"); do
        # Preferir socket local (peer/postgres) para evitar falsos negativos por TCP temporal.
        if run_as_postgres "psql -d postgres -p \"${port}\" -Atqc \"select 1\"" >/dev/null 2>&1; then
            return 0
        fi

        if command -v pg_isready >/dev/null 2>&1; then
            if pg_isready -q -h 127.0.0.1 -p "${port}" >/dev/null 2>&1; then
                return 0
            fi

            if run_as_postgres "pg_isready -q -p \"${port}\"" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

ensure_debian_postgres_cluster() {
    if [ "${OS_FAMILY}" != "debian" ]; then
        return
    fi

    if ! command -v pg_lsclusters >/dev/null 2>&1 || ! command -v pg_createcluster >/dev/null 2>&1; then
        return
    fi

    local cluster_count
    local pg_major=""
    cluster_count="$(pg_lsclusters --no-header 2>/dev/null | wc -l | tr -d ' ')"
    if ! pg_lsclusters --no-header 2>/dev/null | awk '$2=="main" {found=1} END {exit(found ? 0 : 1)}'; then
        pg_major="$(psql --version 2>/dev/null | sed -n 's/^psql (PostgreSQL) \([0-9][0-9]*\).*/\1/p' | head -1 || true)"
        if [ -z "${pg_major}" ] && [ -d /usr/lib/postgresql ]; then
            pg_major="$(ls -1 /usr/lib/postgresql | sort -V | tail -1 || true)"
        fi
        if [ -n "${pg_major}" ] && ! debian_cluster_exists "${pg_major}" main; then
            if [ "${cluster_count}" = "0" ]; then
                log "No hay cluster PostgreSQL en Debian. Creando cluster ${pg_major}/main..."
            else
                log "No existe cluster Debian main. Creando cluster ${pg_major}/main..."
            fi
            pg_createcluster "${pg_major}" main --port="${POSTGRES_INTERNAL_PORT}" --start
            wait_for_postgres_access "${POSTGRES_INTERNAL_PORT}" 60 || true
        fi
    fi

    while read -r ver name port status owner data logf; do
        if [ "${status}" != "online" ] && [ -n "${ver}" ] && [ -n "${name}" ]; then
            pg_ctlcluster "${ver}" "${name}" start || true
        fi
    done < <(pg_lsclusters --no-header 2>/dev/null || true)

    if [ -n "$(get_debian_main_cluster_port || true)" ]; then
        wait_for_postgres_access "$(get_debian_main_cluster_port || true)" 60 || true
    fi
}

cleanup_stale_postmaster_pid() {
    local data_dir="$1"
    local pid_file="${data_dir}/postmaster.pid"
    local stale_pid=""

    [ -n "${data_dir}" ] || return
    [ -f "${pid_file}" ] || return

    stale_pid="$(sed -n '1p' "${pid_file}" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "${stale_pid}" ] && kill -0 "${stale_pid}" >/dev/null 2>&1; then
        return
    fi

    warn "Detectado postmaster.pid huerfano en ${data_dir}. Limpiando..."
    rm -f "${pid_file}" >/dev/null 2>&1 || true
}

debian_recover_postgres_cluster() {
    if [ "${OS_FAMILY}" != "debian" ] || ! command -v pg_lsclusters >/dev/null 2>&1; then
        return 1
    fi

    local attempt
    local healed_port=""
    local ver name port status owner data logf

    for attempt in $(seq 1 3); do
        warn "Recuperacion PostgreSQL Debian (${attempt}/3)..."
        if [ "${SERVICE_MANAGER}" = "systemd" ]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        restart_service postgresql

        while read -r ver name port status owner data logf; do
            [ -n "${ver}" ] || continue
            [ -n "${name}" ] || continue
            [ -n "${data}" ] || continue

            cleanup_stale_postmaster_pid "${data}"

            if [ "${status}" != "online" ]; then
                pg_ctlcluster --skip-systemctl-redirect "${ver}" "${name}" start >/dev/null 2>&1 || \
                    pg_ctlcluster "${ver}" "${name}" start >/dev/null 2>&1 || true
            fi
        done < <(pg_lsclusters --no-header 2>/dev/null || true)

        sleep 2
        healed_port="$(detect_active_postgres_port 20 1 || true)"
        if [ -n "${healed_port}" ] && wait_for_postgres_access "${healed_port}" 30; then
            echo "${healed_port}"
            return 0
        fi
    done

    return 1
}

resolve_postgres_port_with_recovery() {
    local attempt
    local detected_port=""

    for attempt in $(seq 1 4); do
        detected_port="$(detect_active_postgres_port 20 1 || true)"
        if [ -n "${detected_port}" ] && wait_for_postgres_access "${detected_port}" 90; then
            echo "${detected_port}"
            return 0
        fi

        if [ "${OS_FAMILY}" = "debian" ]; then
            detected_port="$(debian_recover_postgres_cluster || true)"
            if [ -n "${detected_port}" ] && wait_for_postgres_access "${detected_port}" 45; then
                echo "${detected_port}"
                return 0
            fi
        else
            restart_service postgresql
            sleep 2
        fi
    done

    if [ "${OS_FAMILY}" = "debian" ] && command -v pg_lsclusters >/dev/null 2>&1; then
        detected_port="$(pg_lsclusters --no-header 2>/dev/null | awk '$4=="online" && $3 ~ /^[0-9]+$/ {print $3; exit}')"
        if [ -n "${detected_port}" ] && wait_for_postgres_access "${detected_port}" 90; then
            echo "${detected_port}"
            return 0
        fi
    fi

    return 1
}

disable_service_if_exists() {
    local svc="$1"
    local script_name

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        if systemctl list-unit-files | grep -q "^${svc}\.service"; then
            systemctl disable --now "${svc}" >/dev/null 2>&1 || true
        fi
        return
    fi

    script_name="$(service_script_name "${svc}")"
    if command -v service >/dev/null 2>&1 && service_script_exists "${script_name}"; then
        service "${script_name}" stop >/dev/null 2>&1 || true
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d -f "${script_name}" remove >/dev/null 2>&1 || true
        fi
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --del "${script_name}" >/dev/null 2>&1 || true
        fi
    fi
}

remove_watchdog_cron() {
    remove_file_if_exists "${CRON_WATCHDOG_FILE}"
    # Cleanup legacy user-crontab entry when crontab is parseable.
    local current
    current="$(crontab -l 2>/dev/null || true)"
    if [ -n "${current}" ] && printf '%s\n' "${current}" | grep -q "pg_manager_watchdog.sh"; then
        printf '%s\n' "${current}" | grep -v "pg_manager_watchdog.sh" | crontab - || true
    fi
}

remove_file_if_exists() {
    local file="$1"
    if [ -f "${file}" ]; then
        rm -f "${file}"
    fi
}

validate_safe_delete_target() {
    local target="$1"
    [ -n "${target}" ] || die "Ruta vacia para borrado."
    [[ "${target}" = /* ]] || die "Ruta no absoluta para borrado: ${target}"
    case "${target}" in
        "/"|"/root"|"/home"|"/opt"|"/tmp"|"/var"|"/usr"|"/etc")
            die "Ruta insegura para borrado: ${target}"
            ;;
    esac
}

remove_dir_if_exists_safe() {
    local target="$1"
    if [ -d "${target}" ]; then
        validate_safe_delete_target "${target}"
        rm -rf "${target}"
    fi
}

package_remove_stack() {
    if [ "${PKG_TOOL}" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y postgresql postgresql-contrib pgbouncer haproxy nginx certbot python3-certbot-nginx || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
        return
    fi
    if [ "${PKG_TOOL}" = "dnf" ]; then
        dnf remove -y postgresql-server postgresql-contrib pgbouncer haproxy nginx certbot python3-certbot-nginx || true
        dnf autoremove -y || true
        return
    fi
    yum remove -y postgresql-server postgresql-contrib pgbouncer haproxy nginx certbot python3-certbot-nginx || true
}

perform_destructive_cleanup() {
    log "Iniciando limpieza completa de instalacion previa..."

    disable_service_if_exists pg_manager
    disable_service_if_exists pgbouncer
    disable_service_if_exists haproxy
    disable_service_if_exists nginx
    disable_service_if_exists postgresql

    remove_watchdog_cron
    remove_file_if_exists /usr/local/bin/pg_manager_watchdog.sh
    remove_file_if_exists /usr/local/bin/configure_postgres_timeouts.sh
    remove_file_if_exists /etc/systemd/system/pg_manager.service
    remove_file_if_exists "${NGINX_CONF_FILE}"
    remove_file_if_exists /etc/haproxy/haproxy.cfg

    remove_dir_if_exists_safe "${APP_DIR}"
    remove_dir_if_exists_safe /etc/pgbouncer
    remove_dir_if_exists_safe /etc/postgresql
    remove_dir_if_exists_safe /var/lib/postgresql
    remove_dir_if_exists_safe /var/lib/pgsql

    package_remove_stack
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl daemon-reload || true
    fi

    if [ -n "${EXISTING_ENV_BACKUP}" ] && [ -f "${EXISTING_ENV_BACKUP}" ]; then
        rm -f "${EXISTING_ENV_BACKUP}" || true
        EXISTING_ENV_BACKUP=""
    fi
}

confirm_destructive_action() {
    local action="$1"
    if [ "${THL_FORCE}" = "1" ]; then
        return
    fi

    if ! has_tty; then
        die "Accion ${action} requiere confirmacion. Reintenta con THL_FORCE=1."
    fi

    echo ""
    echo -e "${YELLOW}ADVERTENCIA:${NC} ${action} eliminara aplicacion y datos gestionados."
    read -r -p "Escribe ELIMINAR para continuar: " CONFIRM_DELETE < /dev/tty
    if [ "${CONFIRM_DELETE}" != "ELIMINAR" ]; then
        die "Operacion cancelada por usuario."
    fi
}

select_install_action() {
    if [ -n "${THL_ACTION}" ]; then
        INSTALL_ACTION="${THL_ACTION}"
        return
    fi

    if [ "${THL_NONINTERACTIVE:-0}" = "1" ] || ! has_tty; then
        if [ "${EXISTING_INSTALL}" = "1" ]; then
            INSTALL_ACTION="upgrade"
        else
            INSTALL_ACTION="reinstall"
        fi
        return
    fi

    echo ""
    echo "Selecciona modo de operacion:"
    echo "1) Borrado completo + instalacion nueva"
    echo "2) Actualizacion (preserva configuracion) [recomendado]"
    echo "3) Eliminar aplicacion y todos los datos"
    read -r -p "Opcion [2]: " ACTION_OPTION < /dev/tty
    ACTION_OPTION="${ACTION_OPTION:-2}"
    case "${ACTION_OPTION}" in
        1) INSTALL_ACTION="reinstall" ;;
        2) INSTALL_ACTION="upgrade" ;;
        3) INSTALL_ACTION="uninstall" ;;
        *)
            warn "Opcion invalida. Se usara actualizacion."
            INSTALL_ACTION="upgrade"
            ;;
    esac
}

handle_install_action() {
    case "${INSTALL_ACTION}" in
        reinstall)
            log "Modo seleccionado: borrado completo + instalacion."
            confirm_destructive_action "reinstall"
            perform_destructive_cleanup
            EXISTING_INSTALL="0"
            THL_PRESERVE_EXISTING=0
            ;;
        upgrade)
            log "Modo seleccionado: actualizacion."
            ;;
        uninstall)
            log "Modo seleccionado: eliminar aplicacion y datos."
            confirm_destructive_action "uninstall"
            perform_destructive_cleanup
            echo ""
            echo -e "${GREEN}THL SQL eliminado correctamente del servidor.${NC}"
            exit 0
            ;;
        *)
            die "Modo de accion no soportado: ${INSTALL_ACTION}"
            ;;
    esac
}

detect_os() {
    if [ ! -f /etc/os-release ]; then
        die "No se pudo detectar la distribucion (falta /etc/os-release)."
    fi
    # shellcheck disable=SC1091
    source /etc/os-release

    local os_name="${ID:-}"
    local os_like="${ID_LIKE:-}"

    if [[ "${os_name}" =~ (debian|ubuntu) ]] || [[ "${os_like}" =~ (debian|ubuntu) ]]; then
        OS_FAMILY="debian"
        PKG_TOOL="apt"
        if [ "${RUNTIME_ENV}" = "container" ]; then
            FIREWALL_BACKEND="none"
        else
            FIREWALL_BACKEND="ufw"
        fi
        return
    fi

    if [[ "${os_name}" =~ (rhel|rocky|almalinux|centos|fedora) ]] || [[ "${os_like}" =~ (rhel|fedora|centos) ]]; then
        OS_FAMILY="rhel"
        if command -v dnf >/dev/null 2>&1; then
            PKG_TOOL="dnf"
        else
            PKG_TOOL="yum"
        fi
        if [ "${RUNTIME_ENV}" = "container" ]; then
            FIREWALL_BACKEND="none"
        else
            FIREWALL_BACKEND="firewalld"
        fi
        return
    fi

    die "Distribucion no soportada: ID=${os_name} ID_LIKE=${os_like}"
}

run_with_retry() {
    local retries="$1"
    shift

    local attempt=1
    local rc=0
    while true; do
        if "$@"; then
            return 0
        fi

        rc=$?
        if [ "${attempt}" -ge "${retries}" ]; then
            return "${rc}"
        fi

        warn "Intento ${attempt}/${retries} fallo (rc=${rc}). Reintentando..."
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done
}

apt_recover() {
    warn "Intentando recuperar estado de APT/DPKG..."
    dpkg --configure -a || true
    apt-get install -f -y || true
    apt --fix-broken install -y || true
}

pkg_update() {
    if [ "${PKG_TOOL}" = "apt" ]; then
        run_with_retry 3 apt-get update
        return
    fi
    if [ "${PKG_TOOL}" = "dnf" ]; then
        run_with_retry 2 dnf -y makecache
        return
    fi
    run_with_retry 2 yum -y makecache
}

pkg_upgrade_system() {
    if [ "${THL_SYSTEM_UPGRADE_POLICY}" = "none" ]; then
        log "Politica de upgrade del sistema: none (omitido)."
        return
    fi

    if [ "${PKG_TOOL}" = "apt" ]; then
        local apt_upgrade_cmd="upgrade"
        if [ "${THL_SYSTEM_UPGRADE_POLICY}" = "full" ]; then
            apt_upgrade_cmd="full-upgrade"
        fi
        log "Aplicando ${apt_upgrade_cmd} del sistema..."
        run_with_retry 2 env DEBIAN_FRONTEND=noninteractive apt-get "${apt_upgrade_cmd}" -y
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        log "Aplicando upgrade del sistema con dnf..."
        run_with_retry 2 dnf upgrade -y
        return
    fi

    log "Aplicando upgrade del sistema con yum..."
    run_with_retry 2 yum update -y
}

pkg_install_critical() {
    if [ "$#" -eq 0 ]; then
        return
    fi

    if [ "${PKG_TOOL}" = "apt" ]; then
        if run_with_retry 2 env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
            return
        fi

        warn "Fallo instalacion critica con APT. Ejecutando recuperacion..."
        apt_recover
        if run_with_retry 1 env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
            return
        fi

        die "No se pudieron instalar paquetes criticos: $*"
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        run_with_retry 2 dnf install -y "$@" || die "No se pudieron instalar paquetes criticos: $*"
        return
    fi

    run_with_retry 2 yum install -y "$@" || die "No se pudieron instalar paquetes criticos: $*"
}

pkg_install_optional() {
    if [ "$#" -eq 0 ]; then
        return
    fi

    if [ "${PKG_TOOL}" = "apt" ]; then
        run_with_retry 2 env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || {
            warn "No se pudieron instalar paquetes opcionales: $*"
            return 1
        }
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        run_with_retry 2 dnf install -y "$@" || {
            warn "No se pudieron instalar paquetes opcionales: $*"
            return 1
        }
        return
    fi

    run_with_retry 2 yum install -y "$@" || {
        warn "No se pudieron instalar paquetes opcionales: $*"
        return 1
    }
}

install_prerequisites() {
    log "[1/11] Instalando dependencias del sistema..."
    local debian_packages
    local rhel_packages

    pkg_update
    pkg_upgrade_system

    if [ "${OS_FAMILY}" = "debian" ]; then
        debian_packages=(
            bash ca-certificates curl git tar sudo openssl python3 python3-venv python3-pip
            nginx postgresql postgresql-contrib pgbouncer haproxy
        )
        if [ "${RUNTIME_ENV}" != "container" ]; then
            debian_packages+=(ufw cron)
        fi
        pkg_install_critical "${debian_packages[@]}"

        pkg_install_optional gnupg lsb-release software-properties-common || true
    else
        if [ "${PKG_TOOL}" = "dnf" ]; then
            dnf install -y epel-release >/dev/null 2>&1 || true
        fi
        rhel_packages=(
            bash ca-certificates curl git tar sudo openssl python3 python3-pip python3-virtualenv
            nginx postgresql-server postgresql-contrib pgbouncer haproxy
        )
        if [ "${RUNTIME_ENV}" != "container" ]; then
            rhel_packages+=(firewalld cronie)
        fi
        pkg_install_critical "${rhel_packages[@]}"
    fi

    enable_service_if_exists nginx
    if [ "${RUNTIME_ENV}" != "container" ]; then
        enable_service_if_exists crond
        enable_service_if_exists cron
    fi
}

install_bootstrap_tools() {
    log "[bootstrap] Instalando herramientas base para one-link..."
    pkg_update

    if [ "${OS_FAMILY}" = "debian" ]; then
        pkg_install_critical bash ca-certificates curl git tar sudo
        return
    fi

    if [ "${PKG_TOOL}" = "dnf" ]; then
        dnf install -y epel-release >/dev/null 2>&1 || true
    fi
    pkg_install_critical bash ca-certificates curl git tar sudo
}

validate_safe_bootstrap_dir() {
    local target="$1"

    [ -n "${target}" ] || die "BOOTSTRAP_DIR no puede ser vacio."
    [[ "${target}" = /* ]] || die "BOOTSTRAP_DIR debe ser ruta absoluta: ${target}"

    case "${target}" in
        "/"|"/root"|"/home"|"/opt"|"/tmp"|"/var"|"/usr"|"/etc")
            die "BOOTSTRAP_DIR inseguro para operaciones destructivas: ${target}"
            ;;
    esac

    if [[ "${target}" != *thl-sql* ]]; then
        die "BOOTSTRAP_DIR debe contener 'thl-sql' por seguridad: ${target}"
    fi
}

safe_reset_bootstrap_dir() {
    validate_safe_bootstrap_dir "${BOOTSTRAP_DIR}"
    if [ -e "${BOOTSTRAP_DIR}" ]; then
        rm -rf "${BOOTSTRAP_DIR}"
    fi
}

repo_slug_from_url() {
    local repo_url="$1"
    repo_url="${repo_url%.git}"

    if [[ "${repo_url}" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

download_repo_tarball_fallback() {
    local repo_slug
    repo_slug="$(repo_slug_from_url "${THL_REPO_URL}")" || return 1

    local tarball_url="https://codeload.github.com/${repo_slug}/tar.gz/refs/heads/main"
    local tmp_tar tmp_dir extracted_dir
    tmp_tar="$(mktemp /tmp/thl-sql-bootstrap.XXXXXX.tar.gz)"
    tmp_dir="$(mktemp -d /tmp/thl-sql-bootstrap.XXXXXX)"

    if ! run_with_retry 2 curl -fL --connect-timeout 10 "${tarball_url}" -o "${tmp_tar}"; then
        rm -f "${tmp_tar}" || true
        rm -rf "${tmp_dir}" || true
        return 1
    fi

    tar -xzf "${tmp_tar}" -C "${tmp_dir}"
    extracted_dir="$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
    [ -n "${extracted_dir}" ] || die "No se pudo extraer el tarball del repositorio."

    mv "${extracted_dir}" "${BOOTSTRAP_DIR}"
    rm -f "${tmp_tar}" || true
    rm -rf "${tmp_dir}" || true
}

sync_bootstrap_repo() {
    validate_safe_bootstrap_dir "${BOOTSTRAP_DIR}"
    mkdir -p "$(dirname "${BOOTSTRAP_DIR}")"

    if [ "${THL_AUTO_CACHE_CLEAN}" = "1" ]; then
        safe_reset_bootstrap_dir
    fi

    if [ -d "${BOOTSTRAP_DIR}/.git" ]; then
        if run_with_retry 2 git -C "${BOOTSTRAP_DIR}" fetch --depth 1 origin main && \
            git -C "${BOOTSTRAP_DIR}" checkout -f main && \
            git -C "${BOOTSTRAP_DIR}" reset --hard origin/main; then
            return
        fi

        warn "No se pudo actualizar bootstrap por git fetch. Se intentara descarga limpia."
        safe_reset_bootstrap_dir
    else
        safe_reset_bootstrap_dir
    fi

    if run_with_retry 2 git clone --depth 1 "${THL_REPO_URL}" "${BOOTSTRAP_DIR}"; then
        return
    fi

    warn "git clone fallo. Intentando fallback por tarball de GitHub..."
    safe_reset_bootstrap_dir
    if download_repo_tarball_fallback; then
        return
    fi

    die "No se pudo descargar el repositorio (${THL_REPO_URL}) por git ni por tarball."
}

ensure_repo_source() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${script_dir}/backend/main.py" ] && [ -f "${script_dir}/server/configure_sql_proxy.sh" ]; then
        SCRIPT_DIR="${script_dir}"
        return
    fi

    log "Instalacion en modo one-link detectada. Descargando repo ${THL_REPO_URL}..."
    install_bootstrap_tools
    sync_bootstrap_repo

    [ -f "${BOOTSTRAP_DIR}/install.sh" ] || die "No se encontro install.sh en ${BOOTSTRAP_DIR}."

    export THL_REPO_URL
    export THL_DOMAIN="${THL_DOMAIN:-}"
    export THL_BIND_IP="${THL_BIND_IP:-}"
    export THL_PORT="${THL_PORT:-}"
    export THL_ADMIN_USER="${THL_ADMIN_USER:-}"
    export THL_ADMIN_PASS="${THL_ADMIN_PASS:-}"
    export THL_PG_PASSWORD="${THL_PG_PASSWORD:-}"
    export THL_NONINTERACTIVE="${THL_NONINTERACTIVE:-}"
    export THL_INSTALL_DEBUG
    export THL_INSTALL_LOG_FILE
    export THL_SYSTEM_UPGRADE_POLICY
    export THL_INSTALL_LOG_INITIALIZED
    export THL_UX_MODE
    export THL_INSTALL_SUMMARY_FILE
    export THL_PRESERVE_EXISTING
    export THL_ACTION
    export THL_FORCE
    export THL_AUTO_CACHE_CLEAN
    export THL_NO_SYSTEMD
    export THL_PYTHON_BIN
    export THL_INSTALL_TAILSCALE
    export PUBLIC_HOST="${PUBLIC_HOST:-}"
    export PUBLIC_PORT="${PUBLIC_PORT:-}"
    export PUBLIC_SCHEME="${PUBLIC_SCHEME:-}"
    export PANEL_URL="${PANEL_URL:-}"
    export PUBLIC_DB_HOST="${PUBLIC_DB_HOST:-}"
    export PUBLIC_DB_PORT="${PUBLIC_DB_PORT:-}"

    exec bash "${BOOTSTRAP_DIR}/install.sh"
}

ask_tailscale() {
    if [ -n "${THL_INSTALL_TAILSCALE}" ]; then
        return
    fi

    if [ "${THL_NONINTERACTIVE:-0}" = "1" ] || [ "${THL_UX_MODE}" = "1" ] || ! has_tty; then
        THL_INSTALL_TAILSCALE="0"
        return
    fi

    echo ""
    echo "Deseas instalar Tailscale para acceso VPN privado?"
    echo "Esto permite conectarse al panel y bases de datos via IP privada de Tailscale."
    read -r -p "Instalar Tailscale? [s/N]: " TS_ANSWER < /dev/tty
    case "${TS_ANSWER}" in
        [SsYy]) THL_INSTALL_TAILSCALE="1" ;;
        *)      THL_INSTALL_TAILSCALE="0" ;;
    esac
}

install_tailscale() {
    if [ "${THL_INSTALL_TAILSCALE}" != "1" ]; then
        log "Tailscale omitido por configuracion del usuario."
        return
    fi

    log "Instalando Tailscale..."
    if command -v tailscale >/dev/null 2>&1; then
        log "Tailscale ya esta instalado."
    else
        curl -fsSL https://tailscale.com/install.sh | bash
    fi

    if ! command -v tailscale >/dev/null 2>&1; then
        warn "No se pudo instalar Tailscale. Se continuara sin VPN privada."
        THL_INSTALL_TAILSCALE="0"
        return
    fi

    # Start the tailscaled daemon.
    if [ "${RUNTIME_ENV}" = "container" ]; then
        # In containers without systemd, start tailscaled in userspace mode.
        if ! pgrep -x tailscaled >/dev/null 2>&1; then
            log "Iniciando tailscaled en modo contenedor (userspace)..."
            tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state &
            disown
            sleep 3
        fi
    elif [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl enable --now tailscaled >/dev/null 2>&1 || true
    elif [ "${SERVICE_MANAGER}" = "service" ]; then
        service tailscaled start >/dev/null 2>&1 || true
    else
        # Fallback: start tailscaled manually if no service manager is available.
        if ! pgrep -x tailscaled >/dev/null 2>&1; then
            tailscaled --state=/var/lib/tailscale/tailscaled.state &
            disown
            sleep 3
        fi
    fi

    sleep 2

    local ts_status
    ts_status="$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | head -1 || true)"
    if echo "${ts_status}" | grep -q '"Running"'; then
        log "Tailscale ya esta autenticado."
    else
        echo ""
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}  Tailscale - Autenticacion requerida${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo -e "${YELLOW}Se ejecutara 'tailscale up'.${NC}"
        echo -e "${YELLOW}Abre la URL que aparece a continuacion en tu navegador para vincular este nodo.${NC}"
        echo -e "${YELLOW}La instalacion continuara automaticamente una vez autenticado.${NC}"
        echo ""
        tailscale up
        echo ""
        echo -e "${GREEN}[OK] Tailscale autenticado exitosamente.${NC}"
    fi

    # Poll for the Tailscale IPv4 address.
    local ts_ip_attempt
    for ts_ip_attempt in $(seq 1 30); do
        TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
        if [ -n "${TAILSCALE_IP}" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "${TAILSCALE_IP}" ]; then
        warn "No se pudo obtener la IP de Tailscale. Se continuara sin VPN privada."
        THL_INSTALL_TAILSCALE="0"
        return
    fi

    echo -e "${GREEN}[OK] IP de Tailscale asignada: ${TAILSCALE_IP}${NC}"
}

apply_tailscale_config() {
    if [ "${THL_INSTALL_TAILSCALE}" != "1" ] || [ -z "${TAILSCALE_IP}" ]; then
        return
    fi

    log "Aplicando IP de Tailscale (${TAILSCALE_IP}) como PUBLIC_DB_HOST..."
    PUBLIC_DB_HOST="${TAILSCALE_IP}"
    PUBLIC_DB_HOST_SOURCE="tailscale"

    local env_file_path="${APP_DIR}/backend/.env"
    if [ -f "${env_file_path}" ]; then
        set_env_key "${env_file_path}" "PUBLIC_DB_HOST" "${TAILSCALE_IP}"
        set_env_key "${env_file_path}" "PUBLIC_DB_HOST_SOURCE" "tailscale"
        set_env_key "${env_file_path}" "TAILSCALE_IP" "${TAILSCALE_IP}"

        # Update ALLOWED_ORIGINS to include the Tailscale IP so the panel
        # accepts requests via the VPN.  Preserve existing origins.
        local current_origins
        current_origins="$(grep -oP '(?<=^ALLOWED_ORIGINS=).*' "${env_file_path}" 2>/dev/null || true)"
        local ts_origin_http="http://${TAILSCALE_IP}:${WEB_PORT:-80}"
        local ts_origin_base="http://${TAILSCALE_IP}"
        if ! echo "${current_origins}" | grep -qF "${ts_origin_http}"; then
            local new_origins="${current_origins:+${current_origins},}${ts_origin_http},${ts_origin_base}"
            set_env_key "${env_file_path}" "ALLOWED_ORIGINS" "${new_origins}"
        fi
    fi

    # Update the PANEL_URL to reflect the Tailscale IP for the final report.
    PANEL_URL="http://${TAILSCALE_IP}:${WEB_PORT:-80}"

    # Allow Tailscale interface traffic through the firewall.
    local ts_iface
    ts_iface="$(ip -o link show | grep -oP 'tailscale\d+' | head -1 || true)"
    if [ -n "${ts_iface}" ]; then
        if [ "${FIREWALL_BACKEND}" = "ufw" ] && command -v ufw >/dev/null 2>&1; then
            ufw allow in on "${ts_iface}" >/dev/null 2>&1 || true
            log "Firewall: permitido trafico en interfaz ${ts_iface} (ufw)."
        elif [ "${FIREWALL_BACKEND}" = "firewalld" ] && command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --zone=trusted --add-interface="${ts_iface}" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            log "Firewall: interfaz ${ts_iface} agregada a zona trusted (firewalld)."
        elif [ "${FIREWALL_BACKEND}" = "iptables" ] && command -v iptables >/dev/null 2>&1; then
            iptables -A INPUT -i "${ts_iface}" -j ACCEPT 2>/dev/null || true
            log "Firewall: permitido trafico en interfaz ${ts_iface} (iptables)."
        fi
    fi

    # Restart pg_manager so it picks up the new PUBLIC_DB_HOST from .env.
    log "Reiniciando pg_manager para aplicar configuracion de Tailscale..."
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl restart pg_manager >/dev/null 2>&1 || true
    elif [ "${SERVICE_MANAGER}" = "service" ]; then
        service pg_manager restart >/dev/null 2>&1 || true
    fi

    log "Tailscale configurado. La IP ${TAILSCALE_IP} es ahora el host publico de conexion."
}

collect_input() {
    local interactive_mode=1
    local existing_admin_username=""
    local existing_admin_password=""
    local existing_db_password=""
    local existing_public_db_host=""
    local existing_public_db_port=""
    local existing_cookie_secure=""
    local existing_allowed_origins=""
    local existing_http_port=""
    local requested_public_db_host="${PUBLIC_DB_HOST:-}"
    local requested_public_db_port="${PUBLIC_DB_PORT:-}"
    SERVER_IP="$(curl -fsS --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')"
    if [ -z "${SERVER_IP}" ]; then
        SERVER_IP="127.0.0.1"
    fi

    if [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
        existing_admin_username="$(existing_env_value ADMIN_USERNAME)"
        existing_admin_password="$(existing_env_value ADMIN_PASSWORD)"
        existing_db_password="$(existing_env_value DB_PASSWORD)"
        existing_public_db_host="$(existing_env_value PUBLIC_DB_HOST)"
        existing_public_db_port="$(existing_env_value PUBLIC_DB_PORT)"
        existing_cookie_secure="$(existing_env_value COOKIE_SECURE)"
        existing_allowed_origins="$(existing_env_value ALLOWED_ORIGINS)"
        existing_http_port="$(extract_http_port_from_origins "${existing_allowed_origins}")"
    fi

    if [ "${THL_UX_MODE}" = "1" ]; then
        UX_MODE_ACTIVE="1"
        THL_NONINTERACTIVE=1
        interactive_mode=0
    elif [ "${THL_NONINTERACTIVE:-0}" = "1" ]; then
        interactive_mode=0
    elif ! has_tty; then
        warn "No hay TTY disponible para prompts. Se activa THL_NONINTERACTIVE=1."
        THL_NONINTERACTIVE=1
        interactive_mode=0
    fi

    ADMIN_USERNAME="${THL_ADMIN_USER:-${existing_admin_username:-}}"
    if [ -z "${ADMIN_USERNAME}" ]; then
        if [ "${interactive_mode}" = "1" ]; then
            read -r -p "Usuario administrador [admin]: " ADMIN_USERNAME < /dev/tty
        else
            warn "THL_ADMIN_USER no definido. Se usara 'admin'."
        fi
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    fi

    ADMIN_PASSWORD="${THL_ADMIN_PASS:-${existing_admin_password:-}}"
    if [ -n "${THL_ADMIN_PASS:-}" ]; then
        ADMIN_PASSWORD_SOURCE="provided"
    elif [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ] && [ -n "${existing_admin_password}" ]; then
        ADMIN_PASSWORD_SOURCE="preserved"
    else
        ADMIN_PASSWORD_SOURCE="prompted"
    fi
    if [ -z "${ADMIN_PASSWORD}" ]; then
        if [ "${interactive_mode}" = "1" ]; then
            while true; do
                read -r -s -p "Contrasena administrador: " ADMIN_PASSWORD < /dev/tty
                echo ""
                [ -n "${ADMIN_PASSWORD}" ] || { warn "La contrasena no puede estar vacia."; continue; }
                read -r -s -p "Confirmar contrasena: " ADMIN_PASSWORD_CONFIRM < /dev/tty
                echo ""
                if [ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]; then
                    warn "Las contrasenas no coinciden."
                    continue
                fi
                break
            done
        else
            ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
            warn "THL_ADMIN_PASS no definido en modo no interactivo. Se genero password admin aleatorio."
            ADMIN_PASSWORD_GENERATED="1"
            ADMIN_PASSWORD_SOURCE="generated"
        fi
    fi

    DOMAIN="${THL_DOMAIN:-}"
    if [ -z "${DOMAIN}" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ] && [ "${EXISTING_INSTALL}" = "1" ] && [ "${existing_cookie_secure}" = "true" ]; then
        DOMAIN="${existing_public_db_host}"
    fi
    if [ -z "${DOMAIN}" ] && [ "${interactive_mode}" = "1" ]; then
        echo ""
        echo "Si tienes dominio, ingresalo. Si no, deja vacio y se usa IP:puerto."
        read -r -p "Dominio (ej: sql.midominio.com) [vacio para IP]: " DOMAIN < /dev/tty
    fi

    WEB_PORT="${THL_PORT:-}"
    if [ -n "${DOMAIN}" ]; then
        log "Dominio detectado: ${DOMAIN}. Se habilitara flujo HTTPS con certbot."
        USE_DOMAIN="true"
        WEB_PORT="443"
        APP_URL="https://${DOMAIN}"
        ALLOWED_ORIGINS="https://${DOMAIN}"
        COOKIE_SECURE="true"
        PUBLIC_DB_HOST="${requested_public_db_host:-${DOMAIN}}"
        PUBLIC_DB_PORT="${requested_public_db_port:-${existing_public_db_port:-5432}}"
        PUBLIC_DB_HOST_SOURCE="${requested_public_db_host:+override}"
        PUBLIC_DB_HOST_SOURCE="${PUBLIC_DB_HOST_SOURCE:-domain}"
    else
        if [ "${UX_MODE_ACTIVE}" = "1" ]; then
            warn "THL_DOMAIN no definido en modo UX. Se usara modo IP:puerto (sin TLS automatico)."
        fi
        USE_DOMAIN="false"
        if [ -z "${WEB_PORT}" ]; then
            if [ "${interactive_mode}" = "0" ]; then
                WEB_PORT="${existing_http_port:-80}"
            else
                read -r -p "Puerto para panel web [80]: " WEB_PORT < /dev/tty
                WEB_PORT="${WEB_PORT:-80}"
            fi
        fi
        BIND_IP="${THL_BIND_IP:-${existing_public_db_host:-${SERVER_IP}}}"
        APP_URL="http://${BIND_IP}:${WEB_PORT}"
        ALLOWED_ORIGINS="http://${BIND_IP}:${WEB_PORT},http://${BIND_IP}"
        COOKIE_SECURE="false"
        if [ "${RUNTIME_ENV}" = "container" ]; then
            PUBLIC_DB_HOST="${requested_public_db_host:-${PUBLIC_HOST:-localhost}}"
            PUBLIC_DB_PORT="${requested_public_db_port:-${existing_public_db_port:-5432}}"
            PUBLIC_DB_HOST_SOURCE="${requested_public_db_host:+override}"
            PUBLIC_DB_HOST_SOURCE="${PUBLIC_DB_HOST_SOURCE:-container_auto}"
        else
            PUBLIC_DB_HOST="${requested_public_db_host:-${BIND_IP}}"
            PUBLIC_DB_PORT="${requested_public_db_port:-${existing_public_db_port:-5432}}"
            PUBLIC_DB_HOST_SOURCE="${requested_public_db_host:+override}"
            PUBLIC_DB_HOST_SOURCE="${PUBLIC_DB_HOST_SOURCE:-host_auto}"
        fi
    fi

    resolve_panel_url

    PG_PASSWORD="${THL_PG_PASSWORD:-${existing_db_password:-}}"
    if [ -z "${PG_PASSWORD}" ]; then
        PG_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
    fi
}

show_summary() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  Resumen de instalacion${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "  OS family:       ${OS_FAMILY}"
    echo "  Runtime env:     ${RUNTIME_ENV}"
    echo "  Service mgr:     ${SERVICE_MANAGER}"
    echo "  Firewall:        ${FIREWALL_BACKEND}"
    echo "  Admin user:      ${ADMIN_USERNAME}"
    echo "  Panel URL:       ${PANEL_URL}"
    echo "  Public DB host:  ${PUBLIC_DB_HOST}"
    echo "  Public DB port:  ${PUBLIC_DB_PORT}"
    echo "  PostgreSQL pass: ${PG_PASSWORD:0:5}..."
    if [ "${THL_INSTALL_TAILSCALE}" = "1" ]; then
        echo "  Tailscale:       se instalara"
    else
        echo "  Tailscale:       omitido"
    fi
    print_container_panel_url_warning
    echo -e "${CYAN}========================================${NC}"
    echo ""

    if [ "${THL_NONINTERACTIVE:-0}" = "1" ] || [ "${THL_UX_MODE}" = "1" ] || ! has_tty; then
        return
    fi

    read -r -p "Continuar con la instalacion? [S/n]: " CONFIRM < /dev/tty
    CONFIRM="${CONFIRM:-S}"
    if [[ ! "${CONFIRM}" =~ ^[SsYy]$ ]]; then
        die "Instalacion cancelada."
    fi
}

write_install_summary_file() {
    mkdir -p "$(dirname "${THL_INSTALL_SUMMARY_FILE}")"
    {
        echo "THL SQL - Resumen de instalacion"
        echo "Modo: ${INSTALL_ACTION}"
        echo "Entorno: ${RUNTIME_ENV}"
        echo "Gestor de servicios: ${SERVICE_MANAGER}"
        echo "Panel URL: ${PANEL_URL}"
        echo "Public DB host: ${PUBLIC_DB_HOST}"
        echo "Public DB port: ${PUBLIC_DB_PORT}"
        echo "Admin user: ${ADMIN_USERNAME}"
        if [ "${THL_INSTALL_TAILSCALE}" = "1" ] && [ -n "${TAILSCALE_IP}" ]; then
            echo "Tailscale IP: ${TAILSCALE_IP}"
            echo "Panel (VPN): http://${TAILSCALE_IP}:${WEB_PORT}"
        fi
        write_container_panel_url_warning
        if [ "${EXISTING_INSTALL}" = "1" ]; then
            echo "Upgrade: instalacion previa detectada"
            if [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
                echo "Preservacion: credenciales/configuracion conservadas"
            fi
        fi
        if [ "${ADMIN_PASSWORD_GENERATED}" = "1" ]; then
            echo "Admin password temporal: ${ADMIN_PASSWORD}"
            echo "Accion requerida: cambiar password en el primer ingreso."
        fi
        echo "Credenciales completas: ${APP_DIR}/backend/.env"
        echo "Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${THL_INSTALL_SUMMARY_FILE}"
    chmod 600 "${THL_INSTALL_SUMMARY_FILE}" || true
}

configure_dns() {
    log "[2/11] Ajustando DNS del sistema..."
    if [ "${RUNTIME_ENV}" = "container" ]; then
        log "Entorno contenedor detectado: se omite ajuste de DNS del host."
        return
    fi
    if is_systemd_available && systemctl is-active --quiet systemd-resolved; then
        if ! grep -q "^DNS=8.8.8.8 8.8.4.4" /etc/systemd/resolved.conf 2>/dev/null; then
            if grep -q "^#DNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^#DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
            elif grep -q "^DNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
            else
                echo "DNS=8.8.8.8 8.8.4.4" >> /etc/systemd/resolved.conf
            fi
        fi
        if ! grep -q "^FallbackDNS=1.1.1.1 1.0.0.1" /etc/systemd/resolved.conf 2>/dev/null; then
            if grep -q "^#FallbackDNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^#FallbackDNS=.*/FallbackDNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
            elif grep -q "^FallbackDNS=" /etc/systemd/resolved.conf; then
                sed -i 's/^FallbackDNS=.*/FallbackDNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
            else
                echo "FallbackDNS=1.1.1.1 1.0.0.1" >> /etc/systemd/resolved.conf
            fi
        fi
        systemctl restart systemd-resolved || true
    fi
}

configure_postgres_service() {
    log "[3/11] Configurando PostgreSQL..."
    local pg_port=""
    local pg_password_sql
    local cluster_version
    local pg_conf
    local pg_hba
    local pg_hba_include
    local i

    if [ "${OS_FAMILY}" = "rhel" ] && [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
        if command -v postgresql-setup >/dev/null 2>&1; then
            postgresql-setup --initdb >/dev/null 2>&1 || true
        fi
    fi

    ensure_debian_postgres_cluster
    enable_service_if_exists postgresql
    start_service postgresql
    ensure_debian_postgres_cluster

    pg_port="$(resolve_postgres_port_with_recovery || true)"
    if [ -z "${pg_port}" ]; then
        show_postgres_diagnostics
        die "PostgreSQL no quedo accesible tras el arranque inicial."
    fi

    pg_password_sql="${PG_PASSWORD//\'/\'\'}"
    for i in $(seq 1 30); do
        if run_as_postgres "psql -d postgres -p \"${pg_port}\" -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD '${pg_password_sql}';\"" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if [ "${i}" -ge 30 ]; then
        show_postgres_diagnostics
        die "No se pudo actualizar password de postgres en puerto ${pg_port}."
    fi

    pg_conf="$(find /etc/postgresql /var/lib/pgsql -name postgresql.conf 2>/dev/null | head -1 || true)"
    pg_hba="$(find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1 || true)"

    if [ -z "${pg_conf}" ] || [ -z "${pg_hba}" ]; then
        die "No se pudo localizar postgresql.conf o pg_hba.conf."
    fi

    if ! grep -q "^host all postgres 127.0.0.1/32 scram-sha-256$" "${pg_hba}"; then
        echo "host all postgres 127.0.0.1/32 scram-sha-256" >> "${pg_hba}"
    fi

    pg_hba_include="$(dirname "${pg_hba}")/pg_hba_sql_manager.conf"
    prepare_pg_hba_managed_rules "${pg_hba}" "${pg_hba_include}"
    touch "${pg_hba_include}" 2>/dev/null || true
    chown postgres:postgres "${pg_hba}" "${pg_hba_include}" >/dev/null 2>&1 || true
    chmod 640 "${pg_hba}" "${pg_hba_include}" >/dev/null 2>&1 || true

    reload_or_restart_postgres_runtime
    wait_for_postgres_access "${pg_port}" 60 || true

    cp "${SCRIPT_DIR}/server/configure_postgres_timeouts.sh" /usr/local/bin/configure_postgres_timeouts.sh
    chmod +x /usr/local/bin/configure_postgres_timeouts.sh
    if ! /usr/local/bin/configure_postgres_timeouts.sh; then
        warn "configure_postgres_timeouts.sh fallo. Reintentando una vez..."
        cluster_version="$(get_debian_main_cluster_version || true)"
        if [ -n "${cluster_version}" ] && command -v pg_ctlcluster >/dev/null 2>&1; then
            pg_ctlcluster "${cluster_version}" main reload >/dev/null 2>&1 || \
                pg_ctlcluster "${cluster_version}" main restart >/dev/null 2>&1 || true
        else
            reload_or_restart_postgres_runtime
        fi
        wait_for_postgres_access "${POSTGRES_INTERNAL_PORT}" 60 || wait_for_postgres_access "${pg_port}" 60 || true
        sleep 3
        /usr/local/bin/configure_postgres_timeouts.sh || {
            show_postgres_diagnostics
            die "No se pudo completar la configuracion final de PostgreSQL."
        }
    fi
}

deploy_app() {
    log "[4/11] Desplegando aplicacion..."
    mkdir -p "${APP_DIR}"

    [ -f "${SCRIPT_DIR}/backend/main.py" ] || die "No se encontro backend/main.py en ${SCRIPT_DIR}."
    [ -f "${SCRIPT_DIR}/server/configure_sql_proxy.sh" ] || die "No se encontro server/configure_sql_proxy.sh en ${SCRIPT_DIR}."

    rm -rf "${APP_DIR}/backend" "${APP_DIR}/server"
    cp -r "${SCRIPT_DIR}/backend" "${APP_DIR}/backend"
    cp -r "${SCRIPT_DIR}/server" "${APP_DIR}/server"

    if [ -f "${SCRIPT_DIR}/verify_deployment.py" ]; then
        cp "${SCRIPT_DIR}/verify_deployment.py" "${APP_DIR}/verify_deployment.py"
    fi
    if [ -f "${SCRIPT_DIR}/verify_remote.py" ]; then
        cp "${SCRIPT_DIR}/verify_remote.py" "${APP_DIR}/verify_remote.py"
    fi
}

setup_python_env() {
    log "[5/11] Instalando dependencias Python..."
    select_python_for_venv
    "${PYTHON_VENV_BIN}" -m venv "${APP_DIR}/venv"
    "${APP_DIR}/venv/bin/pip" install --upgrade pip
    "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/backend/requirements.txt"
}

write_env_file() {
    log "[6/11] Generando backend/.env..."
    local encryption_key
    local env_file_path="${APP_DIR}/backend/.env"
    local allowed_ports_value
    local allowed_ports_source=""
    local protected_ports_value
    encryption_key="$(existing_env_value ENCRYPTION_KEY)"
    if [ -z "${encryption_key}" ]; then
        encryption_key="$("${APP_DIR}/venv/bin/python3" -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")"
    fi
    if [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
        allowed_ports_source="$(existing_env_value ALLOWED_PORTS)"
    fi
    allowed_ports_value="$(managed_allowed_ports_value "${allowed_ports_source}")"
    protected_ports_value="$(managed_protected_ports_value)"

    if [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ] && [ -n "${EXISTING_ENV_BACKUP}" ] && [ -f "${EXISTING_ENV_BACKUP}" ]; then
        cp "${EXISTING_ENV_BACKUP}" "${env_file_path}"
        log "Se preserva configuracion existente de ${env_file_path}."
    else
        : > "${env_file_path}"
    fi

    set_env_key "${env_file_path}" "DB_HOST" "127.0.0.1"
    set_env_key "${env_file_path}" "DB_PORT" "${POSTGRES_INTERNAL_PORT}"
    set_env_key "${env_file_path}" "DB_NAME" "postgres"
    set_env_key "${env_file_path}" "DB_USER" "postgres"
    set_env_key "${env_file_path}" "DB_PASSWORD" "${PG_PASSWORD}"
    set_env_key "${env_file_path}" "ADMIN_USERNAME" "${ADMIN_USERNAME}"
    set_env_key "${env_file_path}" "ADMIN_PASSWORD" "${ADMIN_PASSWORD}"
    set_env_key "${env_file_path}" "PUBLIC_DB_HOST" "${PUBLIC_DB_HOST}"
    set_env_key "${env_file_path}" "PUBLIC_DB_PORT" "${PUBLIC_DB_PORT}"
    set_env_key "${env_file_path}" "PUBLIC_DB_HOST_SOURCE" "${PUBLIC_DB_HOST_SOURCE:-configured}"
    set_env_key "${env_file_path}" "ALLOWED_ORIGINS" "${ALLOWED_ORIGINS}"
    set_env_key "${env_file_path}" "COOKIE_SECURE" "${COOKIE_SECURE}"
    set_env_key "${env_file_path}" "RUNTIME_ENV" "${RUNTIME_ENV}"
    set_env_key "${env_file_path}" "SERVICE_MANAGER" "${SERVICE_MANAGER}"
    set_env_key "${env_file_path}" "APP_WEB_PORT" "${WEB_PORT}"
    set_env_key "${env_file_path}" "PROTECTED_PORTS" "${protected_ports_value}"

    if [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
        ensure_env_key "${env_file_path}" "COOKIE_NAME" "access_token"
        ensure_env_key "${env_file_path}" "POOLING_ENABLED" "true"
        ensure_env_key "${env_file_path}" "PGBOUNCER_HOST" "127.0.0.1"
        ensure_env_key "${env_file_path}" "PGBOUNCER_PORT" "${PGBOUNCER_INTERNAL_PORT}"
        ensure_env_key "${env_file_path}" "POOL_MODE" "transaction"
        ensure_env_key "${env_file_path}" "PGBOUNCER_MAX_CLIENT_CONN" "2000"
        ensure_env_key "${env_file_path}" "PGBOUNCER_DEFAULT_POOL_SIZE" "80"
        ensure_env_key "${env_file_path}" "PGBOUNCER_MIN_POOL_SIZE" "20"
        ensure_env_key "${env_file_path}" "PGBOUNCER_RESERVE_POOL_SIZE" "40"
        ensure_env_key "${env_file_path}" "PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC" "5"
        ensure_env_key "${env_file_path}" "SQL_PROXY_LISTEN_BACKLOG" "4096"
        ensure_env_key "${env_file_path}" "PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC" "120"
        ensure_env_key "${env_file_path}" "PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC" "120"
        ensure_env_key "${env_file_path}" "PGBOUNCER_SERVER_LOGIN_RETRY_SEC" "15"
        ensure_env_key "${env_file_path}" "HAPROXY_MAXCONN" "4000"
        ensure_env_key "${env_file_path}" "HAPROXY_TIMEOUT_CONNECT" "15s"
        ensure_env_key "${env_file_path}" "HAPROXY_TIMEOUT_CLIENT" "5m"
        ensure_env_key "${env_file_path}" "HAPROXY_TIMEOUT_SERVER" "5m"
        ensure_env_key "${env_file_path}" "HAPROXY_TIMEOUT_QUEUE" "90s"
        ensure_env_key "${env_file_path}" "CSRF_COOKIE_NAME" "csrf_token"
        ensure_env_key "${env_file_path}" "CSRF_HEADER_NAME" "x-csrf-token"
        ensure_env_key "${env_file_path}" "LOGIN_RATE_LIMIT" "8"
        ensure_env_key "${env_file_path}" "LOGIN_RATE_WINDOW_SEC" "300"
        ensure_env_key "${env_file_path}" "SESSION_TTL_SEC" "86400"
        ensure_env_key "${env_file_path}" "TRUSTED_PROXY" "true"
        set_env_key "${env_file_path}" "ALLOWED_PORTS" "${allowed_ports_value}"
        set_env_key "${env_file_path}" "FIREWALL_BACKEND" "${FIREWALL_BACKEND}"
        ensure_env_key "${env_file_path}" "ENCRYPTION_KEY" "${encryption_key}"
    else
        set_env_key "${env_file_path}" "COOKIE_NAME" "access_token"
        set_env_key "${env_file_path}" "POOLING_ENABLED" "true"
        set_env_key "${env_file_path}" "PGBOUNCER_HOST" "127.0.0.1"
        set_env_key "${env_file_path}" "PGBOUNCER_PORT" "${PGBOUNCER_INTERNAL_PORT}"
        set_env_key "${env_file_path}" "POOL_MODE" "transaction"
        set_env_key "${env_file_path}" "PGBOUNCER_MAX_CLIENT_CONN" "2000"
        set_env_key "${env_file_path}" "PGBOUNCER_DEFAULT_POOL_SIZE" "80"
        set_env_key "${env_file_path}" "PGBOUNCER_MIN_POOL_SIZE" "20"
        set_env_key "${env_file_path}" "PGBOUNCER_RESERVE_POOL_SIZE" "40"
        set_env_key "${env_file_path}" "PGBOUNCER_RESERVE_POOL_TIMEOUT_SEC" "5"
        set_env_key "${env_file_path}" "SQL_PROXY_LISTEN_BACKLOG" "4096"
        set_env_key "${env_file_path}" "PGBOUNCER_CLIENT_LOGIN_TIMEOUT_SEC" "120"
        set_env_key "${env_file_path}" "PGBOUNCER_QUERY_WAIT_TIMEOUT_SEC" "120"
        set_env_key "${env_file_path}" "PGBOUNCER_SERVER_LOGIN_RETRY_SEC" "15"
        set_env_key "${env_file_path}" "HAPROXY_MAXCONN" "4000"
        set_env_key "${env_file_path}" "HAPROXY_TIMEOUT_CONNECT" "15s"
        set_env_key "${env_file_path}" "HAPROXY_TIMEOUT_CLIENT" "5m"
        set_env_key "${env_file_path}" "HAPROXY_TIMEOUT_SERVER" "5m"
        set_env_key "${env_file_path}" "HAPROXY_TIMEOUT_QUEUE" "90s"
        set_env_key "${env_file_path}" "CSRF_COOKIE_NAME" "csrf_token"
        set_env_key "${env_file_path}" "CSRF_HEADER_NAME" "x-csrf-token"
        set_env_key "${env_file_path}" "LOGIN_RATE_LIMIT" "8"
        set_env_key "${env_file_path}" "LOGIN_RATE_WINDOW_SEC" "300"
        set_env_key "${env_file_path}" "SESSION_TTL_SEC" "86400"
        set_env_key "${env_file_path}" "TRUSTED_PROXY" "true"
        set_env_key "${env_file_path}" "ALLOWED_PORTS" "${allowed_ports_value}"
        set_env_key "${env_file_path}" "FIREWALL_BACKEND" "${FIREWALL_BACKEND}"
        set_env_key "${env_file_path}" "ENCRYPTION_KEY" "${encryption_key}"
    fi

    chmod 600 "${env_file_path}"
    if [ -n "${EXISTING_ENV_BACKUP}" ] && [ -f "${EXISTING_ENV_BACKUP}" ]; then
        rm -f "${EXISTING_ENV_BACKUP}" || true
        EXISTING_ENV_BACKUP=""
    fi
}

configure_sql_stack() {
    log "[7/11] Configurando HAProxy + PgBouncer..."
    chmod +x "${APP_DIR}/server/configure_sql_proxy.sh"
    bash "${APP_DIR}/server/configure_sql_proxy.sh" "${APP_DIR}/backend/.env"
    "${APP_DIR}/venv/bin/python3" "${APP_DIR}/server/sync_pgbouncer_auth.py" --env-file "${APP_DIR}/backend/.env"
}

configure_systemd_service() {
    log "[8/11] Configurando servicio de la aplicacion..."

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        cat > /etc/systemd/system/pg_manager.service <<SVCEOF
[Unit]
Description=THL SQL Manager Web App
After=network.target postgresql.service

[Service]
User=root
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${APP_DIR}/backend/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port ${BACKEND_BIND_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

        systemctl daemon-reload
        systemctl enable --now pg_manager
        systemctl restart pg_manager
        return
    fi

    cat > /etc/init.d/pg_manager <<SVCEOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          pg_manager
# Required-Start:    \$network \$local_fs postgresql
# Required-Stop:     \$network \$local_fs postgresql
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: THL SQL Manager Web App
### END INIT INFO

APP_DIR="${APP_DIR}"
BACKEND_DIR="${APP_DIR}/backend"
ENV_FILE="${APP_DIR}/backend/.env"
PID_FILE="${PG_MANAGER_PID_FILE}"
LOG_FILE="${PG_MANAGER_LOG_FILE}"
UVICORN_BIN="${APP_DIR}/venv/bin/uvicorn"
PYTHON_BIN="${APP_DIR}/venv/bin/python3"
PORT="${BACKEND_BIND_PORT}"

is_running() {
    if [ ! -f "\${PID_FILE}" ]; then
        return 1
    fi
    PID="\$(cat "\${PID_FILE}" 2>/dev/null || true)"
    [ -n "\${PID}" ] || return 1
    kill -0 "\${PID}" >/dev/null 2>&1
}

start_service() {
    if is_running; then
        echo "pg_manager ya esta en ejecucion"
        return 0
    fi
    mkdir -p "\$(dirname "\${PID_FILE}")" "\$(dirname "\${LOG_FILE}")"
    cd "\${BACKEND_DIR}" || exit 1
    THL_ENV_FILE="\${ENV_FILE}" THL_BACKEND_DIR="\${BACKEND_DIR}" THL_UVICORN_BIN="\${UVICORN_BIN}" THL_PORT="\${PORT}" \
        nohup "\${PYTHON_BIN}" - >> "\${LOG_FILE}" 2>&1 <<'PY' &
import os
from dotenv import dotenv_values

env = os.environ.copy()
env_path = env.get("THL_ENV_FILE")
backend_dir = env.get("THL_BACKEND_DIR")
uvicorn_bin = env.get("THL_UVICORN_BIN")
port = env.get("THL_PORT", "8000")

if env_path:
    for key, value in dotenv_values(env_path).items():
        if value is not None:
            env[key] = value

if backend_dir:
    os.chdir(backend_dir)

os.execve(uvicorn_bin, [uvicorn_bin, "main:app", "--host", "127.0.0.1", "--port", port], env)
PY
    echo \$! > "\${PID_FILE}"
    sleep 1
    is_running
}

stop_service() {
    if ! is_running; then
        rm -f "\${PID_FILE}" >/dev/null 2>&1 || true
        return 0
    fi
    PID="\$(cat "\${PID_FILE}" 2>/dev/null || true)"
    kill "\${PID}" >/dev/null 2>&1 || true
    sleep 1
    if kill -0 "\${PID}" >/dev/null 2>&1; then
        kill -9 "\${PID}" >/dev/null 2>&1 || true
    fi
    rm -f "\${PID_FILE}" >/dev/null 2>&1 || true
}

case "\${1:-}" in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        start_service
        ;;
    status)
        if is_running; then
            echo "pg_manager is running"
            exit 0
        fi
        echo "pg_manager is stopped"
        exit 3
        ;;
    *)
        echo "Uso: /etc/init.d/pg_manager {start|stop|restart|status}"
        exit 1
        ;;
esac
SVCEOF

    chmod 755 /etc/init.d/pg_manager
    enable_service_if_exists pg_manager
    restart_service pg_manager
}

wait_for_http_endpoint() {
    local url="$1"
    local retries="${2:-45}"
    local i
    for i in $(seq 1 "${retries}"); do
        if curl -fsS -o /dev/null "${url}"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

verify_admin_login() {
    local env_file="${APP_DIR}/backend/.env"
    local admin_user admin_pass payload http_code
    local tmp_resp

    [ -f "${env_file}" ] || die "No existe ${env_file} para verificar login admin."
    admin_user="$(grep -m1 '^ADMIN_USERNAME=' "${env_file}" | cut -d'=' -f2- || true)"
    admin_pass="$(grep -m1 '^ADMIN_PASSWORD=' "${env_file}" | cut -d'=' -f2- || true)"
    [ -n "${admin_user}" ] || die "ADMIN_USERNAME vacio en ${env_file}."
    [ -n "${admin_pass}" ] || die "ADMIN_PASSWORD vacio en ${env_file}."

    if ! wait_for_http_endpoint "http://127.0.0.1:${BACKEND_BIND_PORT}/login" 45; then
        show_systemd_unit_logs pg_manager
        die "pg_manager no responde en /login tras iniciar servicio."
    fi

    payload="$("${APP_DIR}/venv/bin/python3" -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "${admin_user}" "${admin_pass}")"
    tmp_resp="$(mktemp /tmp/thl-sql-login-check.XXXXXX)"

    http_code="$(curl -sS -o "${tmp_resp}" -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "http://127.0.0.1:${BACKEND_BIND_PORT}/login" || true)"

    if [ "${http_code}" != "200" ]; then
        warn "Verificacion login admin fallo (HTTP ${http_code}). Reintentando tras reinicio de pg_manager..."
        restart_service pg_manager
        sleep 2
        http_code="$(curl -sS -o "${tmp_resp}" -w "%{http_code}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "http://127.0.0.1:${BACKEND_BIND_PORT}/login" || true)"
    fi

    if [ "${http_code}" != "200" ]; then
        cat "${tmp_resp}" >&2 || true
        rm -f "${tmp_resp}" || true
        show_systemd_unit_logs pg_manager
        die "Credencial admin no valida en la app (HTTP ${http_code})."
    fi

    rm -f "${tmp_resp}" || true
    echo -e "${GREEN}[OK] Credencial admin validada en /login${NC}"
}

configure_nginx() {
    log "[9/11] Configurando Nginx..."
    local nginx_local_url="http://127.0.0.1/"
    mkdir -p /etc/nginx/conf.d

    if [ -d /etc/nginx/sites-enabled ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    rm -f "${NGINX_CONF_FILE}"

    if [ "${USE_DOMAIN}" = "true" ]; then
        cat > "${NGINX_CONF_FILE}" <<NGEOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${BACKEND_BIND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
NGEOF
        nginx -t
        reload_service nginx

        pkg_install_optional certbot python3-certbot-nginx || true

        if command -v certbot >/dev/null 2>&1; then
            certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos \
                --register-unsafely-without-email --redirect || {
                warn "Certbot fallo. Verifica DNS de ${DOMAIN} y reintenta manualmente."
            }
        else
            warn "Certbot no esta disponible. Se omite TLS automatico."
        fi
    else
        nginx_local_url="http://127.0.0.1:${WEB_PORT}/"
        cat > "${NGINX_CONF_FILE}" <<NGEOF
server {
    listen ${WEB_PORT};
    server_name _;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()";

    location / {
        proxy_pass http://127.0.0.1:${BACKEND_BIND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
NGEOF
        nginx -t
        reload_service nginx
    fi

    if ! wait_for_http_endpoint "${nginx_local_url}" 60; then
        show_systemd_unit_logs nginx
        die "Nginx no quedo respondiendo en ${nginx_local_url}."
    fi
}

configure_firewall() {
    log "[10/11] Configurando firewall (${FIREWALL_BACKEND})..."
    local firewalld_zone=""
    if [ "${FIREWALL_BACKEND}" = "none" ]; then
        log "Firewall omitido para este entorno (${RUNTIME_ENV})."
        return
    fi
    if [ "${FIREWALL_BACKEND}" = "ufw" ]; then
        ufw allow 22/tcp >/dev/null 2>&1 || true
        if [ "${USE_DOMAIN}" = "true" ]; then
            ufw allow 80/tcp >/dev/null 2>&1 || true
            ufw allow 443/tcp >/dev/null 2>&1 || true
        else
            ufw allow "${WEB_PORT}/tcp" >/dev/null 2>&1 || true
        fi
        if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
            ufw --force enable >/dev/null 2>&1 || true
        fi
        return
    fi

    enable_service_if_exists firewalld
    start_service firewalld
    firewalld_zone="$(detect_firewalld_zone)"
    firewall-cmd --permanent --zone="${firewalld_zone}" --add-service=ssh >/dev/null 2>&1 || true
    if [ "${USE_DOMAIN}" = "true" ]; then
        firewall-cmd --permanent --zone="${firewalld_zone}" --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone="${firewalld_zone}" --add-port=443/tcp >/dev/null 2>&1 || true
    else
        firewall-cmd --permanent --zone="${firewalld_zone}" --add-port="${WEB_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    firewall-cmd --reload >/dev/null 2>&1 || true
}

configure_watchdog() {
    log "[11/11] Configurando watchdog..."
    if [ "${RUNTIME_ENV}" = "container" ]; then
        log "Entorno contenedor detectado: se omite watchdog basado en cron."
        remove_watchdog_cron
        remove_file_if_exists /usr/local/bin/pg_manager_watchdog.sh
        return
    fi
    cp "${APP_DIR}/server/pg_manager_watchdog.sh" /usr/local/bin/pg_manager_watchdog.sh
    chmod +x /usr/local/bin/pg_manager_watchdog.sh

    cat > "${CRON_WATCHDOG_FILE}" <<CRONEOF
* * * * * root /usr/local/bin/pg_manager_watchdog.sh
CRONEOF
    chmod 644 "${CRON_WATCHDOG_FILE}"
}

verify_stack_health() {
    local nginx_local_url="http://127.0.0.1/"

    if [ "${USE_DOMAIN}" != "true" ]; then
        nginx_local_url="http://127.0.0.1:${WEB_PORT}/"
    fi

    log "[health] Verificando servicios finales..."

    if command -v pg_isready >/dev/null 2>&1; then
        if ! pg_isready -q -h 127.0.0.1 -p "${POSTGRES_INTERNAL_PORT}" >/dev/null 2>&1; then
            show_postgres_diagnostics
            die "Health check fallo: PostgreSQL no responde en ${POSTGRES_INTERNAL_PORT}."
        fi
    elif ! wait_for_postgres_access "${POSTGRES_INTERNAL_PORT}" 90; then
        show_postgres_diagnostics
        die "Health check fallo: PostgreSQL no responde en ${POSTGRES_INTERNAL_PORT}."
    fi
    echo -e "${GREEN}[OK] PostgreSQL responde en ${POSTGRES_INTERNAL_PORT}${NC}"

    if ! wait_for_tcp_port "${PGBOUNCER_INTERNAL_PORT}" 90; then
        show_systemd_unit_logs pgbouncer
        die "Health check fallo: PgBouncer no esta escuchando en ${PGBOUNCER_INTERNAL_PORT}."
    fi
    if command -v pg_isready >/dev/null 2>&1 && ! pg_isready -q -h 127.0.0.1 -p "${PGBOUNCER_INTERNAL_PORT}" >/dev/null 2>&1; then
        show_systemd_unit_logs pgbouncer
        die "Health check fallo: PgBouncer no responde en ${PGBOUNCER_INTERNAL_PORT}."
    fi
    echo -e "${GREEN}[OK] PgBouncer responde en ${PGBOUNCER_INTERNAL_PORT}${NC}"

    if ! wait_for_http_endpoint "http://127.0.0.1:${BACKEND_BIND_PORT}/health" 60; then
        show_systemd_unit_logs pg_manager
        die "Health check fallo: pg_manager no responde en /health."
    fi
    echo -e "${GREEN}[OK] Backend responde en http://127.0.0.1:${BACKEND_BIND_PORT}/health${NC}"

    if ! wait_for_http_endpoint "${nginx_local_url}" 60; then
        show_systemd_unit_logs nginx
        die "Health check fallo: Nginx no responde en ${nginx_local_url}."
    fi
    echo -e "${GREEN}[OK] Nginx responde en ${nginx_local_url}${NC}"

    if [ -n "${SERVICE_MANAGER}" ]; then
        if ! wait_for_service_active haproxy 60; then
            show_systemd_unit_logs haproxy
            die "Health check fallo: HAProxy no esta activo."
        fi
    fi
    if ! wait_for_tcp_port 5432 90; then
        show_systemd_unit_logs haproxy
        die "Health check fallo: HAProxy no esta escuchando en 5432."
    fi
    echo -e "${GREEN}[OK] HAProxy activo y escuchando en 5432${NC}"
}

final_report() {
    local services="n/a"
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        services="$(systemctl is-active "$(postgres_service_unit)" pgbouncer haproxy pg_manager nginx 2>/dev/null || true)"
    elif [ "${SERVICE_MANAGER}" = "service" ]; then
        services="service-mode"
    fi
    write_install_summary_file

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Instalacion completada${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "Modo:           ${INSTALL_ACTION}"
    echo "Panel:          ${PANEL_URL}"
    echo "Usuario admin:  ${ADMIN_USERNAME}"
    echo "Fuente clave:   ${ADMIN_PASSWORD_SOURCE}"
    if [ "${EXISTING_INSTALL}" = "1" ]; then
        echo "Upgrade:        instalacion previa detectada."
        if [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
            echo "Preservacion:   credenciales/configuracion conservadas."
        fi
    fi
    if [ "${ADMIN_PASSWORD_GENERATED}" = "1" ]; then
        echo "Clave temporal: ${ADMIN_PASSWORD}"
        echo "Accion:         cambiar password en primer ingreso."
    fi
    if [ "${UX_MODE_ACTIVE}" = "1" ]; then
        echo "Modo UX:        habilitado (sin prompts)."
    fi
    if [ "${THL_INSTALL_TAILSCALE}" = "1" ] && [ -n "${TAILSCALE_IP}" ]; then
        echo "Tailscale IP:   ${TAILSCALE_IP}"
        echo "Panel (VPN):    http://${TAILSCALE_IP}:${WEB_PORT}"
        echo "DB host (VPN):  ${TAILSCALE_IP}"
    fi
    echo "Firewall:       ${FIREWALL_BACKEND}"
    echo "Entorno:        ${RUNTIME_ENV}"
    echo "Servicios via:  ${SERVICE_MANAGER}"
    echo "Servicios:      ${services}"
    echo "Credenciales:   ${APP_DIR}/backend/.env"
    echo "Resumen UX:     ${THL_INSTALL_SUMMARY_FILE}"
    print_container_panel_url_warning
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        echo "Logs app:       journalctl -u pg_manager -f"
    else
        echo "Logs app:       tail -f ${PG_MANAGER_LOG_FILE}"
    fi
    echo "Health SQL:     ss -ltn '( sport = :5432 or sport = :${PGBOUNCER_INTERNAL_PORT} or sport = :${POSTGRES_INTERNAL_PORT} )'"
    echo -e "${GREEN}========================================${NC}"
}

main() {
    parse_cli_args "$@"

    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  THL SQL - Instalador Multi-Distro${NC}"
    echo -e "${CYAN}========================================${NC}"

    run_install_step "P1" "Validando configuracion del instalador" validate_install_settings
    run_install_step "P2" "Validando permisos root" require_root
    run_install_step "P3" "Inicializando logging" init_install_logging
    run_install_step "P4" "Detectando entorno de ejecucion" detect_runtime_context
    run_install_step "P5" "Validando gestor de servicios" require_runtime_support
    run_install_step "P6" "Detectando sistema operativo" detect_os
    run_install_step "P7" "Limpieza automatica de cache" auto_cleanup_cache
    run_install_step "P8" "Preparando fuente del repositorio" ensure_repo_source
    run_install_step "P9" "Detectando instalacion existente" detect_existing_installation
    run_install_step "P10" "Seleccionando modo de instalacion" select_install_action
    run_install_step "P11" "Aplicando accion de instalacion" handle_install_action
    run_install_step "1/11" "Instalando dependencias del sistema" install_prerequisites
    run_install_step "INPUT" "Recolectando parametros de instalacion" collect_input
    run_install_step "TAILSCALE_ASK" "Preguntando sobre Tailscale" ask_tailscale
    run_install_step "RESUMEN" "Mostrando resumen de instalacion" show_summary
    run_install_step "2/11" "Ajustando DNS del sistema" configure_dns
    run_install_step "3/11" "Configurando PostgreSQL" configure_postgres_service
    run_install_step "4/11" "Desplegando aplicacion" deploy_app
    run_install_step "5/11" "Instalando dependencias Python" setup_python_env
    run_install_step "6/11" "Generando archivo .env" write_env_file
    run_install_step "7/11" "Configurando stack SQL" configure_sql_stack
    run_install_step "8/11" "Configurando servicio de la aplicacion" configure_systemd_service
    run_install_step "8b/11" "Validando login admin" verify_admin_login
    run_install_step "9/11" "Configurando Nginx" configure_nginx
    run_install_step "10/11" "Configurando firewall" configure_firewall
    run_install_step "TS_INSTALL" "Instalando Tailscale" install_tailscale
    run_install_step "TS_CONFIG" "Aplicando configuracion Tailscale" apply_tailscale_config
    run_install_step "11/11" "Configurando watchdog" configure_watchdog
    run_install_step "11b/11" "Validando servicios finales" verify_stack_health
    run_install_step "FINAL" "Generando reporte final" final_report
}

main "$@"
