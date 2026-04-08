#!/usr/bin/env bash
set -Eeuo pipefail

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
FIREWALL_BACKEND=""
OS_FAMILY=""
PKG_TOOL=""
NGINX_CONF_FILE="/etc/nginx/conf.d/pg_manager.conf"
CRON_WATCHDOG_FILE="/etc/cron.d/thl_sql_watchdog"
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

collect_failure_diagnostics() {
    local exit_code="${1:-1}"
    local line_no="${2:-unknown}"
    local failed_command="${3:-unknown}"
    local ts

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
        systemctl is-active postgresql pgbouncer haproxy pg_manager nginx 2>/dev/null || true
        for svc in postgresql pgbouncer haproxy pg_manager nginx; do
            echo ""
            echo "--- systemctl status ${svc} ---"
            systemctl status "${svc}" --no-pager -l 2>/dev/null || true
            echo "--- journalctl -u ${svc} (last 120) ---"
            journalctl -u "${svc}" --no-pager -n 120 2>/dev/null || true
        done
        echo ""
        echo "[Network]"
        ss -ltn || true
        if command -v pg_lsclusters >/dev/null 2>&1; then
            echo ""
            echo "[pg_lsclusters]"
            pg_lsclusters || true
        fi
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
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        die "Error: este instalador requiere systemd."
    fi
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
    local escaped
    escaped="$(printf '%s' "${value}" | sed -e 's/[\/&]/\\&/g')"
    if grep -q "^${key}=" "${file}"; then
        sed -i "s|^${key}=.*|${key}=${escaped}|" "${file}"
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
    if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- sh -c "${cmd}"
        return
    fi
    su -s /bin/sh postgres -c "${cmd}"
}

detect_active_postgres_port() {
    local candidate
    local -a candidates=()

    if [ "${OS_FAMILY}" = "debian" ] && command -v pg_lsclusters >/dev/null 2>&1; then
        while read -r ver name port status owner data logf; do
            if [ "${status}" = "online" ] && [ -n "${port}" ]; then
                echo "${port}"
                return 0
            fi
        done < <(pg_lsclusters --no-header 2>/dev/null || true)
    fi

    candidates+=(5432 5433 5434 5435)
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
    cluster_count="$(pg_lsclusters --no-header 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${cluster_count}" = "0" ]; then
        local pg_major
        pg_major="$(psql --version 2>/dev/null | sed -n 's/^psql (PostgreSQL) \([0-9][0-9]*\).*/\1/p' | head -1 || true)"
        if [ -z "${pg_major}" ] && [ -d /usr/lib/postgresql ]; then
            pg_major="$(ls -1 /usr/lib/postgresql | sort -V | tail -1 || true)"
        fi
        if [ -n "${pg_major}" ]; then
            log "No hay cluster PostgreSQL en Debian. Creando cluster ${pg_major}/main..."
            pg_createcluster "${pg_major}" main --start || true
        fi
    fi

    while read -r ver name port status owner data logf; do
        if [ "${status}" != "online" ] && [ -n "${ver}" ] && [ -n "${name}" ]; then
            pg_ctlcluster "${ver}" "${name}" start || true
        fi
    done < <(pg_lsclusters --no-header 2>/dev/null || true)
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
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart postgresql >/dev/null 2>&1 || true

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
        healed_port="$(detect_active_postgres_port || true)"
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
        detected_port="$(detect_active_postgres_port || true)"
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
            systemctl restart postgresql >/dev/null 2>&1 || true
            sleep 2
        fi
    done

    if [ "${OS_FAMILY}" = "debian" ] && command -v pg_lsclusters >/dev/null 2>&1; then
        detected_port="$(pg_lsclusters --no-header 2>/dev/null | awk '$4=="online" && $3 ~ /^[0-9]+$/ {print $3; exit}')"
        if [ -n "${detected_port}" ] && wait_for_postgres_access "${detected_port}" 45; then
            echo "${detected_port}"
            return 0
        fi
    fi

    return 1
}

disable_service_if_exists() {
    local svc="$1"
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
        systemctl disable --now "${svc}" >/dev/null 2>&1 || true
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
    systemctl daemon-reload || true

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
        FIREWALL_BACKEND="ufw"
        return
    fi

    if [[ "${os_name}" =~ (rhel|rocky|almalinux|centos|fedora) ]] || [[ "${os_like}" =~ (rhel|fedora|centos) ]]; then
        OS_FAMILY="rhel"
        if command -v dnf >/dev/null 2>&1; then
            PKG_TOOL="dnf"
        else
            PKG_TOOL="yum"
        fi
        FIREWALL_BACKEND="firewalld"
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

enable_service_if_exists() {
    local service="$1"
    if systemctl list-unit-files | grep -q "^${service}\.service"; then
        systemctl enable --now "${service}" >/dev/null 2>&1 || true
    fi
}

install_prerequisites() {
    log "[1/11] Instalando dependencias del sistema..."
    pkg_update
    pkg_upgrade_system

    if [ "${OS_FAMILY}" = "debian" ]; then
        pkg_install_critical bash ca-certificates curl git tar sudo openssl python3 python3-venv python3-pip \
            nginx postgresql postgresql-contrib pgbouncer haproxy ufw cron

        pkg_install_optional gnupg lsb-release software-properties-common || true
    else
        if [ "${PKG_TOOL}" = "dnf" ]; then
            dnf install -y epel-release >/dev/null 2>&1 || true
        fi
        pkg_install_critical bash ca-certificates curl git tar sudo openssl python3 python3-pip python3-virtualenv \
            nginx postgresql-server postgresql-contrib pgbouncer haproxy firewalld \
            cronie
    fi

    enable_service_if_exists nginx
    enable_service_if_exists crond
    enable_service_if_exists cron
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

    exec bash "${BOOTSTRAP_DIR}/install.sh"
}

collect_input() {
    local interactive_mode=1
    local existing_admin_username=""
    local existing_admin_password=""
    local existing_db_password=""
    local existing_public_db_host=""
    local existing_cookie_secure=""
    local existing_allowed_origins=""
    local existing_http_port=""
    SERVER_IP="$(curl -fsS --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')"
    if [ -z "${SERVER_IP}" ]; then
        SERVER_IP="127.0.0.1"
    fi

    if [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
        existing_admin_username="$(existing_env_value ADMIN_USERNAME)"
        existing_admin_password="$(existing_env_value ADMIN_PASSWORD)"
        existing_db_password="$(existing_env_value DB_PASSWORD)"
        existing_public_db_host="$(existing_env_value PUBLIC_DB_HOST)"
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
        PUBLIC_DB_HOST="${DOMAIN}"
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
        PUBLIC_DB_HOST="${BIND_IP}"
    fi

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
    echo "  Firewall:        ${FIREWALL_BACKEND}"
    echo "  Admin user:      ${ADMIN_USERNAME}"
    echo "  Panel URL:       ${APP_URL}"
    echo "  Public DB host:  ${PUBLIC_DB_HOST}"
    echo "  PostgreSQL pass: ${PG_PASSWORD:0:5}..."
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
        echo "Panel URL: ${APP_URL}"
        echo "Admin user: ${ADMIN_USERNAME}"
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
    if systemctl is-active --quiet systemd-resolved; then
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
    local i

    if [ "${OS_FAMILY}" = "rhel" ] && [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
        if command -v postgresql-setup >/dev/null 2>&1; then
            postgresql-setup --initdb >/dev/null 2>&1 || true
        fi
    fi

    ensure_debian_postgres_cluster
    systemctl enable --now postgresql >/dev/null 2>&1 || systemctl restart postgresql
    ensure_debian_postgres_cluster

    pg_port="$(resolve_postgres_port_with_recovery || true)"
    if [ -z "${pg_port}" ]; then
        if [ "${OS_FAMILY}" = "debian" ] && command -v pg_lsclusters >/dev/null 2>&1; then
            pg_lsclusters || true
        fi
        journalctl -u postgresql --no-pager -n 80 || true
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
        if [ "${OS_FAMILY}" = "debian" ] && command -v pg_lsclusters >/dev/null 2>&1; then
            pg_lsclusters || true
        fi
        journalctl -u postgresql --no-pager -n 120 || true
        die "No se pudo actualizar password de postgres en puerto ${pg_port}."
    fi

    local pg_conf pg_hba pg_hba_include
    pg_conf="$(find /etc/postgresql /var/lib/pgsql -name postgresql.conf 2>/dev/null | head -1 || true)"
    pg_hba="$(find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1 || true)"

    if [ -z "${pg_conf}" ] || [ -z "${pg_hba}" ]; then
        die "No se pudo localizar postgresql.conf o pg_hba.conf."
    fi

    if ! grep -q "^host all postgres 127.0.0.1/32 scram-sha-256$" "${pg_hba}"; then
        echo "host all postgres 127.0.0.1/32 scram-sha-256" >> "${pg_hba}"
    fi

    pg_hba_include="$(dirname "${pg_hba}")/pg_hba_sql_manager.conf"
    touch "${pg_hba_include}"
    chown postgres:postgres "${pg_hba_include}"
    chmod 640 "${pg_hba_include}"

    if ! grep -q "include_if_exists ${pg_hba_include}" "${pg_hba}"; then
        echo "include_if_exists ${pg_hba_include}" >> "${pg_hba}"
    fi

    systemctl restart postgresql

    cp "${SCRIPT_DIR}/server/configure_postgres_timeouts.sh" /usr/local/bin/configure_postgres_timeouts.sh
    chmod +x /usr/local/bin/configure_postgres_timeouts.sh
    if ! /usr/local/bin/configure_postgres_timeouts.sh; then
        warn "configure_postgres_timeouts.sh fallo. Reintentando una vez..."
        sleep 3
        /usr/local/bin/configure_postgres_timeouts.sh || {
            journalctl -u postgresql --no-pager -n 80 || true
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
    python3 -m venv "${APP_DIR}/venv"
    "${APP_DIR}/venv/bin/pip" install --upgrade pip
    "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/backend/requirements.txt"
}

write_env_file() {
    log "[6/11] Generando backend/.env..."
    local encryption_key
    local env_file_path="${APP_DIR}/backend/.env"
    encryption_key="$(existing_env_value ENCRYPTION_KEY)"
    if [ -z "${encryption_key}" ]; then
        encryption_key="$("${APP_DIR}/venv/bin/python3" -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")"
    fi

    if [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ] && [ -n "${EXISTING_ENV_BACKUP}" ] && [ -f "${EXISTING_ENV_BACKUP}" ]; then
        cp "${EXISTING_ENV_BACKUP}" "${env_file_path}"
        log "Se preserva configuracion existente de ${env_file_path}."
    else
        : > "${env_file_path}"
    fi

    set_env_key "${env_file_path}" "DB_HOST" "127.0.0.1"
    set_env_key "${env_file_path}" "DB_PORT" "5433"
    set_env_key "${env_file_path}" "DB_NAME" "postgres"
    set_env_key "${env_file_path}" "DB_USER" "postgres"
    set_env_key "${env_file_path}" "DB_PASSWORD" "${PG_PASSWORD}"
    set_env_key "${env_file_path}" "ADMIN_USERNAME" "${ADMIN_USERNAME}"
    set_env_key "${env_file_path}" "ADMIN_PASSWORD" "${ADMIN_PASSWORD}"
    set_env_key "${env_file_path}" "PUBLIC_DB_HOST" "${PUBLIC_DB_HOST}"
    set_env_key "${env_file_path}" "ALLOWED_ORIGINS" "${ALLOWED_ORIGINS}"
    set_env_key "${env_file_path}" "COOKIE_SECURE" "${COOKIE_SECURE}"

    if [ "${EXISTING_INSTALL}" = "1" ] && [ "${THL_PRESERVE_EXISTING}" = "1" ]; then
        ensure_env_key "${env_file_path}" "COOKIE_NAME" "access_token"
        ensure_env_key "${env_file_path}" "PUBLIC_DB_PORT" "5432"
        ensure_env_key "${env_file_path}" "POOLING_ENABLED" "true"
        ensure_env_key "${env_file_path}" "PGBOUNCER_HOST" "127.0.0.1"
        ensure_env_key "${env_file_path}" "PGBOUNCER_PORT" "6432"
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
        ensure_env_key "${env_file_path}" "ALLOWED_PORTS" "22,80,443,5432"
        ensure_env_key "${env_file_path}" "FIREWALL_BACKEND" "auto"
        ensure_env_key "${env_file_path}" "ENCRYPTION_KEY" "${encryption_key}"
    else
        set_env_key "${env_file_path}" "COOKIE_NAME" "access_token"
        set_env_key "${env_file_path}" "PUBLIC_DB_PORT" "5432"
        set_env_key "${env_file_path}" "POOLING_ENABLED" "true"
        set_env_key "${env_file_path}" "PGBOUNCER_HOST" "127.0.0.1"
        set_env_key "${env_file_path}" "PGBOUNCER_PORT" "6432"
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
        set_env_key "${env_file_path}" "ALLOWED_PORTS" "22,80,443,5432"
        set_env_key "${env_file_path}" "FIREWALL_BACKEND" "auto"
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
    log "[8/11] Configurando servicio systemd..."
    cat > /etc/systemd/system/pg_manager.service <<SVCEOF
[Unit]
Description=THL SQL Manager Web App
After=network.target postgresql.service

[Service]
User=root
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${APP_DIR}/backend/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable --now pg_manager
    systemctl restart pg_manager
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

    if ! wait_for_http_endpoint "http://127.0.0.1:8000/login" 45; then
        journalctl -u pg_manager --no-pager -n 120 || true
        die "pg_manager no responde en /login tras iniciar servicio."
    fi

    payload="$("${APP_DIR}/venv/bin/python3" -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "${admin_user}" "${admin_pass}")"
    tmp_resp="$(mktemp /tmp/thl-sql-login-check.XXXXXX)"

    http_code="$(curl -sS -o "${tmp_resp}" -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "http://127.0.0.1:8000/login" || true)"

    if [ "${http_code}" != "200" ]; then
        warn "Verificacion login admin fallo (HTTP ${http_code}). Reintentando tras reinicio de pg_manager..."
        systemctl restart pg_manager || true
        sleep 2
        http_code="$(curl -sS -o "${tmp_resp}" -w "%{http_code}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "http://127.0.0.1:8000/login" || true)"
    fi

    if [ "${http_code}" != "200" ]; then
        cat "${tmp_resp}" >&2 || true
        rm -f "${tmp_resp}" || true
        journalctl -u pg_manager --no-pager -n 120 || true
        die "Credencial admin no valida en la app (HTTP ${http_code})."
    fi

    rm -f "${tmp_resp}" || true
    echo -e "${GREEN}[OK] Credencial admin validada en /login${NC}"
}

configure_nginx() {
    log "[9/11] Configurando Nginx..."
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
        proxy_pass http://127.0.0.1:8000;
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
        systemctl reload nginx

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
        cat > "${NGINX_CONF_FILE}" <<NGEOF
server {
    listen ${WEB_PORT};
    server_name _;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()";

    location / {
        proxy_pass http://127.0.0.1:8000;
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
        systemctl reload nginx
    fi
}

configure_firewall() {
    log "[10/11] Configurando firewall (${FIREWALL_BACKEND})..."
    if [ "${FIREWALL_BACKEND}" = "ufw" ]; then
        ufw allow 22/tcp >/dev/null 2>&1 || true
        if [ "${USE_DOMAIN}" = "true" ]; then
            ufw allow 80/tcp >/dev/null 2>&1 || true
            ufw allow 443/tcp >/dev/null 2>&1 || true
        else
            ufw allow "${WEB_PORT}/tcp" >/dev/null 2>&1 || true
        fi
        printf "y\n" | ufw enable >/dev/null 2>&1 || true
        return
    fi

    systemctl enable --now firewalld >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
    if [ "${USE_DOMAIN}" = "true" ]; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
    else
        firewall-cmd --permanent --add-port="${WEB_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    firewall-cmd --reload >/dev/null 2>&1 || true
}

configure_watchdog() {
    log "[11/11] Configurando watchdog..."
    cp "${APP_DIR}/server/pg_manager_watchdog.sh" /usr/local/bin/pg_manager_watchdog.sh
    chmod +x /usr/local/bin/pg_manager_watchdog.sh

    cat > "${CRON_WATCHDOG_FILE}" <<CRONEOF
* * * * * root /usr/local/bin/pg_manager_watchdog.sh
CRONEOF
    chmod 644 "${CRON_WATCHDOG_FILE}"
}

final_report() {
    local services
    services="$(systemctl is-active postgresql pgbouncer haproxy pg_manager nginx 2>/dev/null || true)"
    write_install_summary_file

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Instalacion completada${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "Modo:           ${INSTALL_ACTION}"
    echo "Panel:          ${APP_URL}"
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
    echo "Firewall:       ${FIREWALL_BACKEND}"
    echo "Servicios:      ${services}"
    echo "Credenciales:   ${APP_DIR}/backend/.env"
    echo "Resumen UX:     ${THL_INSTALL_SUMMARY_FILE}"
    echo "Logs app:       journalctl -u pg_manager -f"
    echo "Health SQL:     ss -ltn '( sport = :5432 or sport = :6432 or sport = :5433 )'"
    echo -e "${GREEN}========================================${NC}"
}

main() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  THL SQL - Instalador Multi-Distro${NC}"
    echo -e "${CYAN}========================================${NC}"

    run_install_step "P1" "Validando configuracion del instalador" validate_install_settings
    run_install_step "P2" "Validando permisos root" require_root
    run_install_step "P3" "Inicializando logging" init_install_logging
    run_install_step "P4" "Validando systemd" require_systemd
    run_install_step "P5" "Detectando sistema operativo" detect_os
    run_install_step "P6" "Limpieza automatica de cache" auto_cleanup_cache
    run_install_step "P7" "Preparando fuente del repositorio" ensure_repo_source
    run_install_step "P8" "Detectando instalacion existente" detect_existing_installation
    run_install_step "P9" "Seleccionando modo de instalacion" select_install_action
    run_install_step "P10" "Aplicando accion de instalacion" handle_install_action
    run_install_step "1/11" "Instalando dependencias del sistema" install_prerequisites
    run_install_step "INPUT" "Recolectando parametros de instalacion" collect_input
    run_install_step "RESUMEN" "Mostrando resumen de instalacion" show_summary
    run_install_step "2/11" "Ajustando DNS del sistema" configure_dns
    run_install_step "3/11" "Configurando PostgreSQL" configure_postgres_service
    run_install_step "4/11" "Desplegando aplicacion" deploy_app
    run_install_step "5/11" "Instalando dependencias Python" setup_python_env
    run_install_step "6/11" "Generando archivo .env" write_env_file
    run_install_step "7/11" "Configurando stack SQL" configure_sql_stack
    run_install_step "8/11" "Configurando servicio systemd" configure_systemd_service
    run_install_step "8b/11" "Validando login admin" verify_admin_login
    run_install_step "9/11" "Configurando Nginx" configure_nginx
    run_install_step "10/11" "Configurando firewall" configure_firewall
    run_install_step "11/11" "Configurando watchdog" configure_watchdog
    run_install_step "FINAL" "Generando reporte final" final_report
}

main "$@"
