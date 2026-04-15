from fastapi import FastAPI, HTTPException, Depends, status, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from pydantic import BaseModel, Field
from typing import Literal
import psycopg2
from psycopg2 import sql
import secrets
import string
import os
import ipaddress
import shutil
import psutil
import subprocess
import re
import time
import tempfile
from dotenv import load_dotenv
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from cryptography.fernet import Fernet
import sys

# Load environment variables
load_dotenv()

app = FastAPI(title="PostgreSQL Manager", version="1.0.0")

allowed_origins_env = os.getenv("ALLOWED_ORIGINS", "")
if allowed_origins_env:
    allowed_origins = [o.strip() for o in allowed_origins_env.split(",") if o.strip()]
else:
    allowed_origins = ["http://localhost:8000", "http://127.0.0.1:8000"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, "static")
PROJECT_ROOT = os.path.dirname(BASE_DIR)
ENV_FILE_PATH = os.path.join(BASE_DIR, ".env")
APP_DEFAULT_NAME = "THL SQL Manager"
MAX_LOGO_DATA_LENGTH = 512000

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", None)
PUBLIC_DB_HOST = os.getenv("PUBLIC_DB_HOST", DB_HOST)
PUBLIC_DB_PORT = int(os.getenv("PUBLIC_DB_PORT", "5432"))
PUBLIC_DB_HOST_SOURCE = os.getenv("PUBLIC_DB_HOST_SOURCE", "")
POOLING_ENABLED = os.getenv("POOLING_ENABLED", "false").lower() in ("1", "true", "yes")
PGBOUNCER_HOST = os.getenv("PGBOUNCER_HOST", "127.0.0.1")
PGBOUNCER_PORT = int(os.getenv("PGBOUNCER_PORT", "6432"))
POOL_MODE = os.getenv("POOL_MODE", "transaction")
APP_WEB_PORT = int(os.getenv("APP_WEB_PORT", "80"))


def detect_pg_hba_path():
    env_value = os.getenv("PG_HBA_PATH")
    if env_value:
        return env_value
    candidates = [
        "/etc/postgresql/16/main/pg_hba.conf",
        "/etc/postgresql/15/main/pg_hba.conf",
        "/var/lib/pgsql/data/pg_hba.conf",
    ]
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate
    return candidates[0]


PG_HBA_PATH = detect_pg_hba_path()
PG_HBA_MANAGED_START = os.getenv("PG_HBA_MANAGED_START", "# BEGIN THL SQL MANAGED RULES")
PG_HBA_MANAGED_END = os.getenv("PG_HBA_MANAGED_END", "# END THL SQL MANAGED RULES")


def is_container_environment():
    if os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv"):
        return True
    for candidate in ("/proc/1/cgroup", "/proc/1/environ"):
        try:
            with open(candidate, "rb") as handle:
                content = handle.read().decode("utf-8", errors="ignore")
        except OSError:
            continue
        if re.search(r"(docker|containerd|kubepods|podman|lxc)", content):
            return True
    return False


def is_systemd_available():
    return os.path.isdir("/run/systemd/system") and shutil.which("systemctl") is not None


def detect_runtime_environment():
    configured = os.getenv("RUNTIME_ENV", "").strip().lower()
    if configured in ("container", "host"):
        return configured
    return "container" if is_container_environment() else "host"


def detect_service_manager():
    configured = os.getenv("SERVICE_MANAGER", "").strip().lower()
    if configured in ("systemd", "service"):
        return configured
    if is_systemd_available():
        return "systemd"
    if shutil.which("service"):
        return "service"
    return "unknown"


RUNTIME_ENV = detect_runtime_environment()
SERVICE_MANAGER = detect_service_manager()
CGROUP_CPU_SAMPLE = {"usage_seconds": None, "timestamp": None}
HOST_CPU_SAMPLE = {"percent": 0.0, "timestamp": None}

# Auth Configuration
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD")
if not ADMIN_PASSWORD:
    raise ValueError("ADMIN_PASSWORD env var is required")
COOKIE_NAME = os.getenv("COOKIE_NAME", "access_token")
ROOT_PASSWORD = os.getenv("ROOT_PASSWORD", None)
CSRF_COOKIE_NAME = os.getenv("CSRF_COOKIE_NAME", "csrf_token")
CSRF_HEADER_NAME = os.getenv("CSRF_HEADER_NAME", "x-csrf-token")
COOKIE_SECURE = os.getenv("COOKIE_SECURE", "false").lower() in ("1", "true", "yes")
ENCRYPTION_KEY = os.getenv("ENCRYPTION_KEY")
if not ENCRYPTION_KEY:
    raise ValueError("ENCRYPTION_KEY env var is required")
try:
    fernet = Fernet(ENCRYPTION_KEY.encode())
except Exception as e:
    raise ValueError("ENCRYPTION_KEY env var is invalid") from e
LOGIN_RATE_LIMIT = int(os.getenv("LOGIN_RATE_LIMIT", "8"))
LOGIN_RATE_WINDOW_SEC = int(os.getenv("LOGIN_RATE_WINDOW_SEC", "300"))
SESSION_TTL_SEC = int(os.getenv("SESSION_TTL_SEC", "86400"))
TRUSTED_PROXY = os.getenv("TRUSTED_PROXY", "false").lower() in ("1", "true", "yes")
ALLOWED_PORTS_ENV = os.getenv("ALLOWED_PORTS", "*")
PROTECTED_PORTS_ENV = os.getenv("PROTECTED_PORTS", f"22,80,443,{APP_WEB_PORT},{PUBLIC_DB_PORT}")
LEGACY_ALLOWED_PORTS_ENV = "22,80,443,5432"
login_attempts = {}
session_store = {}

@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
    if COOKIE_SECURE:
        response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains; preload"
    return response

def run_sudo_command(cmd_args):
    """
    Run a command with sudo. 
    If ROOT_PASSWORD is set, try using sudo -S with password.
    Otherwise, try sudo or direct execution.
    """
    # 1. Try running directly (if already root)
    try:
        # Use full path for ufw if possible, or assume it's in PATH
        # Common paths: /usr/sbin/ufw, /sbin/ufw
        # We'll just use the command name and rely on PATH first
        result = subprocess.run(cmd_args, capture_output=True, text=True)
        if result.returncode == 0:
            return result
    except Exception:
        pass

    # 2. Try sudo without password (if nopasswd configured)
    try:
        sudo_cmd = ["sudo", "-n"] + cmd_args
        result = subprocess.run(sudo_cmd, capture_output=True, text=True)
        if result.returncode == 0:
            return result
    except Exception:
        pass

    # 3. Try sudo with password if available
    if ROOT_PASSWORD:
        try:
            sudo_cmd = ["sudo", "-S"] + cmd_args
            # Pass password to stdin
            result = subprocess.run(
                sudo_cmd, 
                input=ROOT_PASSWORD + "\n", 
                capture_output=True, 
                text=True
            )
            return result
        except Exception as e:
            print(f"Sudo with password failed: {e}")
            
    # Return the last result (likely failed) or a dummy failed result
    return subprocess.CompletedProcess(cmd_args, 1, stdout="", stderr="Command failed and no sudo method worked")

def get_python_executable():
    deployed_python = os.path.join(PROJECT_ROOT, "venv", "bin", "python3")
    if os.path.exists(deployed_python):
        return deployed_python
    return sys.executable


def service_script_name(service_name: str):
    if service_name.startswith("postgresql@"):
        return "postgresql"
    return service_name


def is_process_running(process_names: set[str]):
    normalized = {name.lower() for name in process_names}
    for proc in psutil.process_iter(["name", "cmdline"]):
        try:
            name = (proc.info.get("name") or "").lower()
            if name in normalized:
                return True
            cmdline = " ".join(proc.info.get("cmdline") or []).lower()
            if any(token in cmdline for token in normalized):
                return True
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
    return False


def read_text_if_exists(path: str):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return None


def read_first_int(paths: list[str]):
    for path in paths:
        raw_value = read_text_if_exists(path)
        if raw_value in (None, "", "max"):
            continue
        try:
            return int(raw_value)
        except ValueError:
            continue
    return None


def read_first_text(paths: list[str]):
    for path in paths:
        raw_value = read_text_if_exists(path)
        if raw_value not in (None, ""):
            return raw_value
    return None


def parse_cpu_set_count(raw_value: str | None):
    if not raw_value:
        return None
    count = 0
    for chunk in raw_value.split(","):
        entry = chunk.strip()
        if not entry:
            continue
        if "-" in entry:
            start_str, end_str = entry.split("-", 1)
            try:
                start = int(start_str)
                end = int(end_str)
            except ValueError:
                return None
            if end < start:
                return None
            count += (end - start + 1)
        else:
            try:
                int(entry)
            except ValueError:
                return None
            count += 1
    return count or None


def get_proc_self_cgroup_paths():
    mapping = {}
    try:
        with open("/proc/self/cgroup", "r", encoding="utf-8") as handle:
            for line in handle:
                parts = line.strip().split(":", 2)
                if len(parts) != 3:
                    continue
                _, controllers, path = parts
                if not controllers:
                    mapping["unified"] = path
                    continue
                for controller in controllers.split(","):
                    mapping[controller] = path
    except OSError:
        return {}
    return mapping


def cgroup_join(base_path: str, cgroup_path: str | None, file_name: str):
    candidates = []
    if cgroup_path:
        relative = cgroup_path.lstrip("/")
        if relative:
            candidates.append(os.path.join(base_path, relative, file_name))
    candidates.append(os.path.join(base_path, file_name))
    deduped = []
    for candidate in candidates:
        if candidate not in deduped:
            deduped.append(candidate)
    return deduped


def cgroup_v2_candidates(file_name: str):
    proc_paths = get_proc_self_cgroup_paths()
    return cgroup_join("/sys/fs/cgroup", proc_paths.get("unified"), file_name)


def cgroup_v1_candidates(controller: str, file_name: str):
    proc_paths = get_proc_self_cgroup_paths()
    controller_paths = {
        "cpu": [
            ("/sys/fs/cgroup/cpu", proc_paths.get("cpu")),
            ("/sys/fs/cgroup/cpu,cpuacct", proc_paths.get("cpu") or proc_paths.get("cpuacct")),
        ],
        "cpuacct": [
            ("/sys/fs/cgroup/cpuacct", proc_paths.get("cpuacct")),
            ("/sys/fs/cgroup/cpu,cpuacct", proc_paths.get("cpuacct") or proc_paths.get("cpu")),
        ],
        "memory": [
            ("/sys/fs/cgroup/memory", proc_paths.get("memory")),
        ],
        "cpuset": [
            ("/sys/fs/cgroup/cpuset", proc_paths.get("cpuset")),
        ],
    }
    candidates = []
    for base_path, cgroup_path in controller_paths.get(controller, []):
        for candidate in cgroup_join(base_path, cgroup_path, file_name):
            if candidate not in candidates:
                candidates.append(candidate)
    return candidates


def detect_cgroup_version():
    if os.path.exists("/sys/fs/cgroup/cgroup.controllers"):
        return 2
    if (
        os.path.exists("/sys/fs/cgroup/memory/memory.usage_in_bytes")
        or os.path.exists("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
        or os.path.exists("/sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us")
    ):
        return 1
    return None


def normalize_cpu_core_value(value: float | int | None):
    if value is None:
        return None
    normalized = round(float(value), 2)
    if normalized.is_integer():
        return int(normalized)
    return normalized


def get_container_cpu_limit_details():
    cgroup_version = detect_cgroup_version()
    quota_cores = None

    if cgroup_version == 2:
        cpu_max = read_first_text(cgroup_v2_candidates("cpu.max"))
        if cpu_max:
            parts = cpu_max.split()
            if len(parts) == 2 and parts[0] != "max":
                try:
                    quota = int(parts[0])
                    period = int(parts[1])
                    if quota > 0 and period > 0:
                        quota_cores = quota / period
                except ValueError:
                    quota_cores = None
    elif cgroup_version == 1:
        quota = read_first_int(cgroup_v1_candidates("cpu", "cpu.cfs_quota_us"))
        period = read_first_int(cgroup_v1_candidates("cpu", "cpu.cfs_period_us"))
        if quota is not None and period and quota > 0 and period > 0:
            quota_cores = quota / period

    cpuset_count = parse_cpu_set_count(
        read_first_text(cgroup_v2_candidates("cpuset.cpus.effective"))
        or read_first_text(cgroup_v1_candidates("cpuset", "cpuset.cpus.effective"))
        or read_first_text(cgroup_v1_candidates("cpuset", "cpuset.cpus"))
        or read_text_if_exists("/sys/fs/cgroup/cpuset.cpus")
    )

    host_cores = psutil.cpu_count() or 1
    assigned_cores = None
    limit_source = "host"

    if quota_cores and cpuset_count:
        assigned_cores = max(min(quota_cores, cpuset_count), 0.001)
        limit_source = "quota+cpuset"
    elif quota_cores:
        assigned_cores = max(quota_cores, 0.001)
        limit_source = "quota"
    elif cpuset_count:
        assigned_cores = cpuset_count
        limit_source = "cpuset"
    else:
        assigned_cores = host_cores

    return {
        "assigned_cores": normalize_cpu_core_value(assigned_cores),
        "host_cores": host_cores,
        "limit_source": limit_source,
        "limited": limit_source != "host",
    }


def read_container_cpu_usage_seconds():
    cgroup_version = detect_cgroup_version()

    if cgroup_version == 2:
        cpu_stat = read_first_text(cgroup_v2_candidates("cpu.stat"))
        if not cpu_stat:
            return None
        for line in cpu_stat.splitlines():
            key, _, value = line.partition(" ")
            if key != "usage_usec":
                continue
            try:
                return int(value.strip()) / 1_000_000
            except ValueError:
                return None
        return None

    if cgroup_version == 1:
        usage_ns = read_first_int(cgroup_v1_candidates("cpuacct", "cpuacct.usage"))
        if usage_ns is None:
            return None
        return usage_ns / 1_000_000_000

    return None


def get_container_cpu_stats():
    global CGROUP_CPU_SAMPLE

    usage_seconds = read_container_cpu_usage_seconds()
    if usage_seconds is None:
        return None

    now = time.monotonic()
    previous_usage = CGROUP_CPU_SAMPLE["usage_seconds"]
    previous_timestamp = CGROUP_CPU_SAMPLE["timestamp"]
    CGROUP_CPU_SAMPLE = {"usage_seconds": usage_seconds, "timestamp": now}

    cpu_limit = get_container_cpu_limit_details()
    assigned_cores = float(cpu_limit["assigned_cores"] or 1)

    if previous_usage is None or previous_timestamp is None or now <= previous_timestamp:
        return {
            "percent": 0.0,
            "usage_seconds": round(usage_seconds, 4),
            "scope": "container",
            "source": "cgroup",
            **cpu_limit,
        }

    elapsed = now - previous_timestamp
    if elapsed <= 0 or assigned_cores <= 0:
        cpu_percent = 0.0
    else:
        cpu_percent = ((usage_seconds - previous_usage) / (elapsed * assigned_cores)) * 100

    return {
        "percent": round(max(0.0, min(cpu_percent, 100.0)), 2),
        "usage_seconds": round(usage_seconds, 4),
        "scope": "container",
        "source": "cgroup",
        **cpu_limit,
    }


def get_container_memory_stats():
    cgroup_version = detect_cgroup_version()
    host_total = psutil.virtual_memory().total

    if cgroup_version == 2:
        used = read_first_int(cgroup_v2_candidates("memory.current"))
        total = read_first_int(cgroup_v2_candidates("memory.max"))
        high = read_first_int(cgroup_v2_candidates("memory.high"))
    elif cgroup_version == 1:
        used = read_first_int(cgroup_v1_candidates("memory", "memory.usage_in_bytes")) or read_first_int(cgroup_v1_candidates("memory", "memory.memsw.usage_in_bytes"))
        total = read_first_int(cgroup_v1_candidates("memory", "memory.limit_in_bytes"))
        high = read_first_int(cgroup_v1_candidates("memory", "memory.soft_limit_in_bytes"))
    else:
        return None

    if used is None:
        return None

    # cgroup v1 commonly reports an effectively unlimited sentinel value.
    if total is not None and host_total and total > host_total * 16:
        total = None

    if high is not None and high <= 0:
        high = None
    if high is not None and host_total and high > host_total * 16:
        high = None

    limit_bytes = total if total and total > 0 else None
    limit_source = "cgroup_limit"
    if limit_bytes is None and high is not None:
        limit_bytes = high
        limit_source = "cgroup_high"
    if limit_bytes is None:
        limit_bytes = host_total
        limit_source = "host_total"

    memory_percent = round((used / limit_bytes) * 100, 2) if limit_bytes else 0.0
    return {
        "total": limit_bytes,
        "percent": max(0.0, min(memory_percent, 100.0)),
        "used": used,
        "assigned_bytes": limit_bytes,
        "host_total": host_total,
        "limit_source": limit_source,
        "limited": limit_source != "host_total",
        "scope": "container",
        "source": "cgroup",
    }


def get_host_cpu_stats():
    global HOST_CPU_SAMPLE
    host_cores = psutil.cpu_count() or 1
    # Use non-blocking call; psutil tracks internally between calls.
    raw_percent = psutil.cpu_percent(interval=None)
    now = time.monotonic()
    prev_ts = HOST_CPU_SAMPLE["timestamp"]
    # On the very first call (or if called too quickly after startup),
    # psutil returns 0.0 because there is no previous sample.  In that
    # case we do a short blocking measurement so the dashboard never
    # shows a stale zero.
    if prev_ts is None or raw_percent == 0.0 and (now - prev_ts) < 1.0:
        raw_percent = psutil.cpu_percent(interval=0.1)
    HOST_CPU_SAMPLE = {"percent": raw_percent, "timestamp": now}
    return {
        "percent": round(raw_percent, 2),
        "assigned_cores": host_cores,
        "host_cores": host_cores,
        "limit_source": "host",
        "limited": False,
        "scope": "host",
        "source": "psutil",
    }


def get_host_memory_stats():
    host_memory = psutil.virtual_memory()
    return {
        "total": host_memory.total,
        "percent": host_memory.percent,
        "used": host_memory.used,
        "assigned_bytes": host_memory.total,
        "host_total": host_memory.total,
        "limit_source": "host",
        "limited": False,
        "scope": "host",
        "source": "psutil",
    }


def get_runtime_stats():
    cpu_stats = None
    memory_stats = None

    if RUNTIME_ENV == "container":
        cpu_stats = get_container_cpu_stats()
        memory_stats = get_container_memory_stats()

    if cpu_stats is None:
        cpu_stats = get_host_cpu_stats()
    if memory_stats is None:
        memory_stats = get_host_memory_stats()

    return {
        "cpu": cpu_stats,
        "memory": memory_stats,
        "runtime_env": RUNTIME_ENV,
    }


def normalize_public_db_host(host_value: str):
    cleaned = (host_value or "").strip()
    if cleaned in ("", "0.0.0.0", "::", "[::]"):
        return "localhost" if RUNTIME_ENV == "container" else "127.0.0.1"
    if cleaned in ("127.0.0.1", "::1"):
        return "localhost"
    return cleaned


def get_public_db_endpoint():
    return {
        "host": normalize_public_db_host(PUBLIC_DB_HOST),
        "port": PUBLIC_DB_PORT,
        "runtime_env": RUNTIME_ENV,
        "host_source": PUBLIC_DB_HOST_SOURCE or ("configured" if PUBLIC_DB_HOST else "derived"),
    }


def get_debian_cluster_version():
    match = re.search(r"/etc/postgresql/(\d+)/main/pg_hba\.conf$", PG_HBA_PATH)
    if match:
        return match.group(1)
    if not shutil.which("pg_lsclusters"):
        return None
    result = subprocess.run(["pg_lsclusters", "--no-header"], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "main":
            return fields[0]
    return None


def postgres_systemd_unit():
    cluster_version = get_debian_cluster_version()
    if cluster_version:
        return f"postgresql@{cluster_version}-main"
    return "postgresql"


def reload_postgres_runtime():
    cluster_version = get_debian_cluster_version()
    if cluster_version and shutil.which("pg_ctlcluster"):
        result = run_sudo_command(["pg_ctlcluster", cluster_version, "main", "reload"])
        if result.returncode == 0:
            return
        run_sudo_command(["pg_ctlcluster", cluster_version, "main", "restart"])
        return

    if SERVICE_MANAGER == "systemd":
        unit = postgres_systemd_unit()
        result = run_sudo_command(["systemctl", "reload", unit])
        if result.returncode != 0:
            restart_result = run_sudo_command(["systemctl", "restart", unit])
            if restart_result.returncode != 0 and unit != "postgresql":
                run_sudo_command(["systemctl", "restart", "postgresql"])
        return

    if SERVICE_MANAGER == "service":
        result = run_sudo_command(["service", "postgresql", "reload"])
        if result.returncode != 0:
            run_sudo_command(["service", "postgresql", "restart"])

def sync_pgbouncer_auth():
    if not POOLING_ENABLED:
        return True
    script_path = os.path.join(PROJECT_ROOT, "server", "sync_pgbouncer_auth.py")
    env_file = os.path.join(BASE_DIR, ".env")
    if not os.path.exists(script_path):
        print(f"PgBouncer sync script not found: {script_path}")
        return False
    cmd = [get_python_executable(), script_path, "--env-file", env_file]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"PgBouncer auth sync failed: {result.stderr or result.stdout}")
        return False
    return True

def get_pgbouncer_connection():
    conn = psycopg2.connect(
        database="pgbouncer",
        user=DB_USER,
        host=PGBOUNCER_HOST,
        port=PGBOUNCER_PORT,
        password=DB_PASSWORD
    )
    conn.autocommit = True
    return conn

def get_service_status(service_name: str):
    if SERVICE_MANAGER == "systemd":
        result = run_sudo_command(["systemctl", "is-active", service_name])
        if result.returncode != 0:
            return "unknown"
        return result.stdout.strip() or "unknown"

    if SERVICE_MANAGER == "service":
        result = run_sudo_command(["service", service_script_name(service_name), "status"])
        output = f"{result.stdout}\n{result.stderr}".strip().lower()
        if result.returncode == 0:
            return "active"
        if any(token in output for token in ("inactive", "stopped", "not running", "failed")):
            return "inactive"
        if "running" in output or "started" in output:
            return "active"

    process_map = {
        "haproxy": {"haproxy"},
        "pgbouncer": {"pgbouncer"},
        "pg_manager": {"uvicorn"},
        "postgresql": {"postgres"},
    }
    process_names = process_map.get(service_name, {service_name})
    if is_process_running(process_names):
        return "active"
    return "unknown"

def get_pooling_snapshot():
    summary = {
        "cl_active": 0,
        "cl_waiting": 0,
        "sv_active": 0,
        "sv_idle": 0,
        "pools": []
    }
    conn = get_pgbouncer_connection()
    cur = conn.cursor()
    try:
        cur.execute("SHOW POOLS")
        columns = [desc[0] for desc in cur.description]
        for row in cur.fetchall():
            pool = dict(zip(columns, row))
            summary["pools"].append(pool)
            summary["cl_active"] += int(pool.get("cl_active", 0))
            summary["cl_waiting"] += int(pool.get("cl_waiting", 0))
            summary["sv_active"] += int(pool.get("sv_active", 0))
            summary["sv_idle"] += int(pool.get("sv_idle", 0))
        cur.execute("SHOW VERSION")
        version_row = cur.fetchone()
        summary["version"] = version_row[0] if version_row else None
        return summary
    finally:
        cur.close()
        conn.close()

def parse_allowed_ports(value: str):
    raw = value.strip().lower()
    if raw in ("", "*", "any"):
        return None
    ports = set()
    for part in value.split(","):
        chunk = part.strip()
        if not chunk:
            continue
        if "-" in chunk:
            start_str, end_str = chunk.split("-", 1)
            if start_str.isdigit() and end_str.isdigit():
                start = int(start_str)
                end = int(end_str)
                for p in range(min(start, end), max(start, end) + 1):
                    if 1 <= p <= 65535:
                        ports.add(p)
            continue
        if chunk.isdigit():
            p = int(chunk)
            if 1 <= p <= 65535:
                ports.add(p)
    return ports

def resolve_allowed_ports(value: str):
    if value.strip() == LEGACY_ALLOWED_PORTS_ENV:
        return None
    return parse_allowed_ports(value)


ALLOWED_PORTS = resolve_allowed_ports(ALLOWED_PORTS_ENV)
PROTECTED_PORTS = parse_allowed_ports(PROTECTED_PORTS_ENV) or set()

def is_port_allowed(port: int):
    return ALLOWED_PORTS is None or port in ALLOWED_PORTS


def is_port_protected(port: int):
    return port in PROTECTED_PORTS


def protected_port_detail(port: int):
    if port == PUBLIC_DB_PORT:
        return f"Puerto SQL {PUBLIC_DB_PORT} se gestiona por IP"
    if port == 22:
        return "Puerto SSH 22 protegido"
    if port in (80, 443, APP_WEB_PORT):
        return f"Puerto web {port} protegido"
    if is_port_protected(port):
        return f"Puerto {port} protegido por la plataforma"
    return None

def get_session(request: Request):
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    session = session_store.get(token)
    if not session:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    if session["expires_at"] < time.time():
        del session_store[token]
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    return session

class ClientRequest(BaseModel):
    client_name: str = Field(..., min_length=1, max_length=80)
    db_name: str = Field(..., min_length=1, max_length=63)

class UpdateClientRequest(BaseModel):
    client_name: str | None = Field(None, min_length=1, max_length=80)
    new_password: str | None = None

class LoginRequest(BaseModel):
    username: str
    password: str

class PortRequest(BaseModel):
    port: int = Field(..., ge=1, le=65535)
    protocol: Literal["tcp", "udp"] = "tcp"

class SqlAccessRequest(BaseModel):
    ip: str

class SqlAccessAssignRequest(BaseModel):
    ip: str
    databases: list[str] = Field(default_factory=list, min_length=1)

class ProfileUpdateRequest(BaseModel):
    app_name: str = Field(..., min_length=2, max_length=80)
    logo_data: str | None = Field(default=None, max_length=MAX_LOGO_DATA_LENGTH)

class PasswordUpdateRequest(BaseModel):
    current_password: str | None = None
    new_password: str = Field(..., min_length=10, max_length=128)

def get_current_username(request: Request):
    session = get_session(request)
    return session["username"]

def get_client_ip(request: Request):
    if TRUSTED_PROXY:
        forwarded_for = request.headers.get("x-forwarded-for")
        if forwarded_for:
            return forwarded_for.split(",")[0].strip()
        real_ip = request.headers.get("x-real-ip")
        if real_ip:
            return real_ip.strip()
    return request.client.host if request.client else "unknown"

def enforce_login_rate_limit(request: Request):
    ip = get_client_ip(request)
    now = time.time()
    entries = login_attempts.get(ip, [])
    entries = [ts for ts in entries if now - ts < LOGIN_RATE_WINDOW_SEC]
    if len(entries) >= LOGIN_RATE_LIMIT:
        raise HTTPException(status_code=429, detail="Demasiados intentos, intenta más tarde")
    entries.append(now)
    login_attempts[ip] = entries

def reset_login_rate_limit(request: Request):
    ip = get_client_ip(request)
    if ip in login_attempts:
        del login_attempts[ip]

def require_csrf(request: Request):
    if request.method in ("GET", "HEAD", "OPTIONS"):
        return True
    session = get_session(request)
    csrf_cookie = request.cookies.get(CSRF_COOKIE_NAME)
    csrf_header = request.headers.get(CSRF_HEADER_NAME)
    if not csrf_cookie or not csrf_header:
        raise HTTPException(status_code=403, detail="CSRF token missing or invalid")
    if not secrets.compare_digest(csrf_cookie, csrf_header):
        raise HTTPException(status_code=403, detail="CSRF token missing or invalid")
    if not secrets.compare_digest(csrf_cookie, session["csrf"]):
        raise HTTPException(status_code=403, detail="CSRF token missing or invalid")
    return True

def normalize_identifier(value: str, label: str):
    cleaned = value.strip().lower().replace(" ", "_")
    if not re.fullmatch(r"[a-z0-9_]{1,63}", cleaned):
        raise HTTPException(status_code=400, detail=f"{label} inválido")
    return cleaned

def normalize_client_name(value: str, label: str):
    cleaned = value.strip()
    if not re.fullmatch(r"[A-Za-z0-9 _-]{1,80}", cleaned):
        raise HTTPException(status_code=400, detail=f"{label} inválido")
    return cleaned

def normalize_brand_name(value: str):
    cleaned = value.strip()
    if not re.fullmatch(r"[A-Za-z0-9 _-]{2,80}", cleaned):
        raise HTTPException(status_code=400, detail="Nombre de marca inválido")
    return cleaned

def normalize_logo_data(value: str | None):
    if value is None:
        return None
    cleaned = value.strip()
    if cleaned == "":
        return None
    if len(cleaned) > MAX_LOGO_DATA_LENGTH:
        raise HTTPException(status_code=400, detail="Logo demasiado grande")
    if not cleaned.startswith("data:image/"):
        raise HTTPException(status_code=400, detail="Formato de logo inválido")
    return cleaned

def validate_admin_password_policy(new_password: str):
    if len(new_password) < 10:
        raise HTTPException(status_code=400, detail="La nueva contraseña debe tener al menos 10 caracteres")
    if new_password.strip() != new_password:
        raise HTTPException(status_code=400, detail="La nueva contraseña no debe iniciar ni terminar con espacios")

def normalize_user_slug(value: str, label: str):
    cleaned = value.strip().lower().replace(" ", "_").replace("-", "_")
    cleaned = re.sub(r"[^a-z0-9_]", "", cleaned)
    if not re.fullmatch(r"[a-z0-9_]{1,63}", cleaned):
        raise HTTPException(status_code=400, detail=f"{label} inválido")
    return cleaned

def normalize_sql_ip(value: str):
    cleaned = value.strip()
    try:
        net = ipaddress.ip_network(cleaned, strict=False)
    except Exception:
        raise HTTPException(status_code=400, detail="IP/CIDR inválido")
    if str(net) == "::/0":
        raise HTTPException(status_code=400, detail="Usa 0.0.0.0/0 para acceso público")
    return str(net)

def parse_sql_access_rules(output: str, sql_port: int):
    allowed = []
    public_access = False
    for line in output.splitlines():
        if "ALLOW" not in line:
            continue
        parts = line.split()
        if "ALLOW" not in parts:
            continue
        allow_index = parts.index("ALLOW")
        source_start = allow_index + 1
        if source_start < len(parts) and parts[source_start] == "IN":
            source_start += 1
        if source_start >= len(parts):
            continue
        if not any(p.startswith(f"{sql_port}/") for p in parts):
            continue
        source = " ".join(parts[source_start:])
        if source.startswith("Anywhere"):
            public_access = True
            continue
        if source not in allowed:
            allowed.append(source)
    return allowed, public_access


def parse_firewalld_sql_access(output: str, sql_port: int):
    allowed = []
    for line in output.splitlines():
        if f'port port="{sql_port}"' not in line:
            continue
        match = re.search(r"source address=\"([^\"]+)\"", line)
        if match:
            cidr = match.group(1)
            if cidr not in allowed:
                allowed.append(cidr)
    return allowed


def detect_firewall_backend():
    preferred = os.getenv("FIREWALL_BACKEND", "").strip().lower()
    if preferred in ("ufw", "firewalld", "none"):
        return preferred
    if os.path.exists("/usr/sbin/ufw") or os.path.exists("/sbin/ufw") or shutil.which("ufw"):
        return "ufw"
    if shutil.which("firewall-cmd"):
        return "firewalld"
    return "none"


FIREWALL_BACKEND = detect_firewall_backend()


def detect_firewalld_zone():
    configured = os.getenv("FIREWALLD_ZONE", "").strip()
    if configured:
        return configured
    if FIREWALL_BACKEND != "firewalld":
        return "public"
    try:
        result = run_sudo_command(["firewall-cmd", "--get-default-zone"])
    except Exception:
        return "public"
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return "public"


FIREWALLD_ZONE = detect_firewalld_zone()


def run_firewall_command(cmd_args):
    if FIREWALL_BACKEND == "ufw":
        return run_sudo_command(["ufw"] + cmd_args)
    if FIREWALL_BACKEND == "firewalld":
        return run_sudo_command(["firewall-cmd"] + cmd_args)
    return subprocess.CompletedProcess(cmd_args, 1, stdout="", stderr="No firewall backend available")


def get_firewall_status_payload():
    if FIREWALL_BACKEND == "ufw":
        status_result = run_firewall_command(["status"])
        if status_result.returncode != 0:
            return {"backend": "ufw", "status": "error", "detail": status_result.stderr, "ports": [], "public_sql": False, "manageable": True}
        output = status_result.stdout
        lines = output.splitlines()
        ports = []
        for line in lines:
            if "ALLOW" not in line:
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            port_proto = parts[0]
            if "/" in port_proto:
                p, proto = port_proto.split("/", 1)
            else:
                p, proto = port_proto, "any"
            if str(p) == str(PUBLIC_DB_PORT):
                continue
            if not any(item["port"] == p and item["protocol"] == proto for item in ports):
                ports.append({"port": p, "protocol": proto})
        _, public_sql = parse_sql_access_rules(output, PUBLIC_DB_PORT)
        is_active = any("Status: active" in line for line in lines)
        return {
            "backend": "ufw",
            "status": "active" if is_active else "inactive",
            "detail": None,
            "ports": ports,
            "public_sql": public_sql,
            "manageable": True,
        }

    if FIREWALL_BACKEND == "firewalld":
        state_result = run_firewall_command(["--state"])
        if state_result.returncode != 0:
            return {
                "backend": "firewalld",
                "status": "error",
                "detail": state_result.stderr,
                "ports": [],
                "public_sql": False,
                "manageable": True,
            }
        ports_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--list-ports"])
        rich_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--list-rich-rules"])
        listed_ports = ports_result.stdout.strip().split()
        ports = []
        for token in listed_ports:
            if "/" not in token:
                continue
            p, proto = token.split("/", 1)
            if str(p) == str(PUBLIC_DB_PORT):
                continue
            ports.append({"port": p, "protocol": proto})
        public_sql = f"{PUBLIC_DB_PORT}/tcp" in listed_ports
        return {
            "backend": "firewalld",
            "status": "active",
            "detail": None,
            "ports": ports,
            "public_sql": public_sql,
            "rich_rules": rich_result.stdout if rich_result.returncode == 0 else "",
            "zone": FIREWALLD_ZONE,
            "manageable": True,
        }

    detail = (
        "Docker/Podman publica puertos fuera del contenedor; usa docker run -p o docker compose."
        if RUNTIME_ENV == "container"
        else "No hay un firewall compatible configurado en el host."
    )
    return {
        "backend": "none",
        "status": "unmanaged",
        "detail": detail,
        "ports": [],
        "public_sql": False,
        "manageable": False,
    }


def allow_port_rule(port: int, protocol: str):
    if FIREWALL_BACKEND == "ufw":
        return run_firewall_command(["allow", f"{port}/{protocol}"])
    if FIREWALL_BACKEND == "firewalld":
        add_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--add-port", f"{port}/{protocol}", "--permanent"])
        if add_result.returncode != 0:
            return add_result
        return run_firewall_command(["--reload"])
    return subprocess.CompletedProcess([], 1, "", "La publicacion de puertos depende del entorno y no puede gestionarse desde la aplicacion")


def revoke_port_rule(port: int, protocol: str):
    if FIREWALL_BACKEND == "ufw":
        return run_firewall_command(["delete", "allow", f"{port}/{protocol}"])
    if FIREWALL_BACKEND == "firewalld":
        del_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--remove-port", f"{port}/{protocol}", "--permanent"])
        if del_result.returncode != 0:
            return del_result
        return run_firewall_command(["--reload"])
    return subprocess.CompletedProcess([], 1, "", "La publicacion de puertos depende del entorno y no puede gestionarse desde la aplicacion")


def sql_rich_rule(ip_value: str):
    try:
        net = ipaddress.ip_network(ip_value, strict=False)
    except Exception:
        net = ipaddress.ip_network("0.0.0.0/0")
    family = "ipv6" if net.version == 6 else "ipv4"
    return f'rule family="{family}" source address="{ip_value}" port protocol="tcp" port="{PUBLIC_DB_PORT}" accept'


def allow_sql_firewall(ip_value: str):
    if ip_value == "0.0.0.0/0":
        if FIREWALL_BACKEND == "ufw":
            return run_firewall_command(["allow", f"{PUBLIC_DB_PORT}/tcp"])
        if FIREWALL_BACKEND == "firewalld":
            add_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--add-port", f"{PUBLIC_DB_PORT}/tcp", "--permanent"])
            if add_result.returncode != 0:
                return add_result
            return run_firewall_command(["--reload"])
        return subprocess.CompletedProcess([], 0, "", "")

    if FIREWALL_BACKEND == "ufw":
        return run_firewall_command(["allow", "from", ip_value, "to", "any", "port", str(PUBLIC_DB_PORT), "proto", "tcp"])
    if FIREWALL_BACKEND == "firewalld":
        add_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--add-rich-rule", sql_rich_rule(ip_value), "--permanent"])
        if add_result.returncode != 0:
            return add_result
        return run_firewall_command(["--reload"])
    return subprocess.CompletedProcess([], 0, "", "")


def revoke_sql_firewall(ip_value: str):
    if ip_value == "0.0.0.0/0":
        if FIREWALL_BACKEND == "ufw":
            return run_firewall_command(["delete", "allow", f"{PUBLIC_DB_PORT}/tcp"])
        if FIREWALL_BACKEND == "firewalld":
            del_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--remove-port", f"{PUBLIC_DB_PORT}/tcp", "--permanent"])
            if del_result.returncode != 0:
                return del_result
            return run_firewall_command(["--reload"])
        return subprocess.CompletedProcess([], 0, "", "")

    if FIREWALL_BACKEND == "ufw":
        return run_firewall_command(["delete", "allow", "from", ip_value, "to", "any", "port", str(PUBLIC_DB_PORT), "proto", "tcp"])
    if FIREWALL_BACKEND == "firewalld":
        del_result = run_firewall_command([f"--zone={FIREWALLD_ZONE}", "--remove-rich-rule", sql_rich_rule(ip_value), "--permanent"])
        if del_result.returncode != 0:
            return del_result
        return run_firewall_command(["--reload"])
    return subprocess.CompletedProcess([], 0, "", "")


def set_sql_public_access(enabled: bool):
    if enabled:
        allow_sql_firewall("0.0.0.0/0")
    else:
        revoke_sql_firewall("0.0.0.0/0")

def read_file_content(path: str):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        result = run_sudo_command(["cat", path])
        if result.returncode == 0:
            return result.stdout
    return ""

def write_file_content(path: str, content: str, owner: str = "postgres:postgres", mode: str = "640"):
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
            return True
    except Exception:
        tmp = tempfile.NamedTemporaryFile(delete=False)
        try:
            tmp.write(content.encode("utf-8"))
            tmp.flush()
            tmp.close()
            move_result = run_sudo_command(["mv", tmp.name, path])
            if move_result.returncode == 0:
                run_sudo_command(["chmod", mode, path])
                run_sudo_command(["chown", owner, path])
                return True
        finally:
            try:
                os.unlink(tmp.name)
            except Exception:
                pass
    return False

HAPROXY_CFG_PATH = os.getenv("HAPROXY_CFG_PATH", "/etc/haproxy/haproxy.cfg")
HAPROXY_SQL_ACL_START = os.getenv("HAPROXY_SQL_ACL_START", "    # BEGIN THL SQL ACLS")
HAPROXY_SQL_ACL_END = os.getenv("HAPROXY_SQL_ACL_END", "    # END THL SQL ACLS")


def replace_haproxy_sql_acl_block(content: str, managed_lines: list[str]):
    block_lines = [HAPROXY_SQL_ACL_START]
    block_lines.extend(managed_lines)
    block_lines.append(HAPROXY_SQL_ACL_END)
    managed_block = "\n".join(block_lines) + "\n"
    pattern = re.compile(
        rf"(?ms)^{re.escape(HAPROXY_SQL_ACL_START)}\n.*?^{re.escape(HAPROXY_SQL_ACL_END)}\n?",
        re.MULTILINE,
    )
    if pattern.search(content):
        return pattern.sub(managed_block, content, count=1)
    target_pattern = re.compile(r"(?m)^(\s*default_backend\s+pgbouncer_backend\s*)$")
    if target_pattern.search(content):
        return target_pattern.sub(managed_block + r"\1", content, count=1)
    return content


def build_haproxy_sql_acl_lines(ip_values: list[str]):
    if any(ip_value == "0.0.0.0/0" for ip_value in ip_values):
        return []
    unique_ips = []
    seen = set()
    for ip_value in ip_values:
        if ip_value in seen:
            continue
        seen.add(ip_value)
        unique_ips.append(ip_value)
    if not unique_ips:
        return ["    tcp-request connection reject"]
    lines = [f"    acl allowed_sql_clients src {ip_value}" for ip_value in unique_ips]
    lines.append("    tcp-request connection reject unless allowed_sql_clients")
    return lines


def should_manage_sql_via_haproxy():
    return POOLING_ENABLED and FIREWALL_BACKEND == "none"


def reload_haproxy_runtime():
    validate_result = run_sudo_command(["haproxy", "-c", "-f", HAPROXY_CFG_PATH])
    if validate_result.returncode != 0:
        return validate_result

    if SERVICE_MANAGER == "systemd":
        result = run_sudo_command(["systemctl", "reload", "haproxy"])
        if result.returncode != 0:
            return run_sudo_command(["systemctl", "restart", "haproxy"])
        return result

    if SERVICE_MANAGER == "service":
        result = run_sudo_command(["service", "haproxy", "reload"])
        if result.returncode != 0:
            return run_sudo_command(["service", "haproxy", "restart"])
        return result

    return subprocess.CompletedProcess([], 1, "", "No se pudo recargar HAProxy en este entorno")


def sync_haproxy_sql_acl(ip_values: list[str]):
    if not POOLING_ENABLED and not os.path.exists(HAPROXY_CFG_PATH):
        return subprocess.CompletedProcess([], 0, "", "")
    current_content = read_file_content(HAPROXY_CFG_PATH)
    if not current_content:
        return subprocess.CompletedProcess([], 0, "", "") if not should_manage_sql_via_haproxy() else subprocess.CompletedProcess([], 1, "", "No se encontro la configuracion de HAProxy")
    managed_lines = build_haproxy_sql_acl_lines(ip_values) if should_manage_sql_via_haproxy() else []
    updated_content = replace_haproxy_sql_acl_block(current_content, managed_lines)
    if updated_content == current_content:
        return subprocess.CompletedProcess([], 0, "", "")
    if not write_file_content(HAPROXY_CFG_PATH, updated_content, owner="root:root", mode="644"):
        return subprocess.CompletedProcess([], 1, "", "No se pudo actualizar la configuracion de HAProxy")
    return reload_haproxy_runtime()


def strip_legacy_pg_hba_include(content: str):
    return re.sub(
        r"(?m)^include_if_exists\s+'?[^'\n]*pg_hba_sql_manager\.conf'?\s*\n?",
        "",
        content,
    )


def replace_pg_hba_managed_block(content: str, managed_lines: list[str]):
    block_lines = [PG_HBA_MANAGED_START]
    block_lines.extend(managed_lines)
    block_lines.append(PG_HBA_MANAGED_END)
    managed_block = "\n".join(block_lines) + "\n"
    sanitized = strip_legacy_pg_hba_include(content).rstrip("\n")
    pattern = re.compile(
        rf"(?ms)^{re.escape(PG_HBA_MANAGED_START)}\n.*?^{re.escape(PG_HBA_MANAGED_END)}\n?",
        re.MULTILINE,
    )
    if pattern.search(sanitized):
        return pattern.sub(managed_block, sanitized, count=1)
    if not sanitized:
        return managed_block
    return sanitized + "\n\n" + managed_block

def rebuild_pg_hba_rules():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT ips.ip_cidr, map.db_name, mc.db_user
            FROM sql_access_ips ips
            JOIN sql_access_ip_databases map ON map.ip_id = ips.id
            JOIN managed_clients mc ON mc.db_name = map.db_name
            ORDER BY ips.ip_cidr, map.db_name
        """)
        all_rows = cur.fetchall()
    finally:
        cur.close()
        conn.close()

    has_public = any(row[0] == "0.0.0.0/0" for row in all_rows)
    ip_values = []
    seen_ips = set()
    for ip_cidr, _, _ in all_rows:
        if ip_cidr in seen_ips:
            continue
        seen_ips.add(ip_cidr)
        ip_values.append(ip_cidr)

    lines = []
    if POOLING_ENABLED:
        seen_pairs = set()
        for _, db_name, db_user in all_rows:
            key = (db_name, db_user)
            if key in seen_pairs:
                continue
            seen_pairs.add(key)
            lines.append(f"host {db_name} {db_user} 127.0.0.1/32 scram-sha-256")
    else:
        for ip_cidr, db_name, db_user in all_rows:
            lines.append(f"hostssl {db_name} {db_user} {ip_cidr} scram-sha-256")
            lines.append(f"hostnossl {db_name} {db_user} {ip_cidr} md5")
    current_content = read_file_content(PG_HBA_PATH)
    updated_content = replace_pg_hba_managed_block(current_content, lines)
    write_file_content(PG_HBA_PATH, updated_content)
    reload_postgres_runtime()
    haproxy_result = sync_haproxy_sql_acl(ip_values)
    if haproxy_result.returncode != 0:
        raise RuntimeError(haproxy_result.stderr or "No se pudo actualizar la politica SQL de HAProxy")

    # Keep SQL public exposure aligned with metadata.
    set_sql_public_access(has_public)

def encrypt_secret(value: str):
    return fernet.encrypt(value.encode()).decode()

def generate_password(length=24):
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for i in range(length))

def dotenv_escape(value: str):
    escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
    escaped = escaped.replace("\n", "\\n")
    return f"\"{escaped}\""

def persist_env_key(key: str, value: str):
    line_value = f"{key}={dotenv_escape(value)}"
    pattern = re.compile(rf"^{re.escape(key)}=")
    lines = []
    if os.path.exists(ENV_FILE_PATH):
        with open(ENV_FILE_PATH, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
    replaced = False
    updated = []
    for line in lines:
        if pattern.match(line):
            updated.append(line_value)
            replaced = True
        else:
            updated.append(line)
    if not replaced:
        updated.append(line_value)
    with open(ENV_FILE_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(updated).rstrip("\n") + "\n")

def get_profile_settings():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT app_name, logo_data, password_initialized FROM app_profile_settings WHERE id = 1")
        row = cur.fetchone()
        if row:
            return {
                "app_name": row[0] or APP_DEFAULT_NAME,
                "logo_data": row[1],
                "password_initialized": bool(row[2]),
            }
        return {"app_name": APP_DEFAULT_NAME, "logo_data": None, "password_initialized": False}
    finally:
        cur.close()
        conn.close()

def save_profile_settings(app_name: str, logo_data: str | None):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("""
            INSERT INTO app_profile_settings (id, app_name, logo_data, password_initialized, updated_at)
            VALUES (1, %s, %s, FALSE, NOW())
            ON CONFLICT (id) DO UPDATE
            SET app_name = EXCLUDED.app_name,
                logo_data = EXCLUDED.logo_data,
                updated_at = NOW()
        """, (app_name, logo_data))
    finally:
        cur.close()
        conn.close()

def mark_password_initialized():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("UPDATE app_profile_settings SET password_initialized = TRUE, updated_at = NOW() WHERE id = 1")
    finally:
        cur.close()
        conn.close()

def get_db_connection():
    try:
        conn = psycopg2.connect(
            database=DB_NAME,
            user=DB_USER,
            host=DB_HOST,
            port=DB_PORT,
            password=DB_PASSWORD
        )
        conn.autocommit = True
        return conn
    except Exception as e:
        print(f"Connection error: {e}")
        raise HTTPException(status_code=500, detail="Could not connect to database system")

def init_metadata_db():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS managed_clients (
                id SERIAL PRIMARY KEY,
                client_name TEXT NOT NULL,
                db_name TEXT NOT NULL,
                db_user TEXT NOT NULL,
                db_password TEXT NOT NULL,
                is_public BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        # Ensure 'is_public' exists if the table was already created
        cur.execute("""
            DO $$ 
            BEGIN 
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                               WHERE table_name='managed_clients' AND column_name='is_public') THEN
                    ALTER TABLE managed_clients ADD COLUMN is_public BOOLEAN DEFAULT FALSE;
                END IF;
            END $$;
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sql_access_ips (
                id SERIAL PRIMARY KEY,
                ip_cidr TEXT NOT NULL UNIQUE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sql_access_ip_databases (
                id SERIAL PRIMARY KEY,
                ip_id INTEGER NOT NULL REFERENCES sql_access_ips(id) ON DELETE CASCADE,
                db_name TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (ip_id, db_name)
            );
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS app_profile_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                app_name TEXT NOT NULL DEFAULT 'THL SQL Manager',
                logo_data TEXT NULL,
                password_initialized BOOLEAN NOT NULL DEFAULT FALSE,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        cur.execute("""
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_name='app_profile_settings' AND column_name='password_initialized'
                ) THEN
                    ALTER TABLE app_profile_settings
                    ADD COLUMN password_initialized BOOLEAN NOT NULL DEFAULT TRUE;
                END IF;
            END $$;
        """)
        cur.execute("""
            INSERT INTO app_profile_settings (id, app_name, logo_data, password_initialized, updated_at)
            VALUES (1, %s, NULL, FALSE, NOW())
            ON CONFLICT (id) DO NOTHING;
        """, (APP_DEFAULT_NAME,))
    except Exception as e:
        print(f"Error initializing metadata DB: {e}")
    finally:
        cur.close()
        conn.close()

# Initialize DB on startup
try:
    init_metadata_db()
    sync_pgbouncer_auth()
except Exception as e:
    print(f"Startup Warning: Could not initialize database: {e}")

# Pre-warm CPU metrics so the first dashboard call returns real data.
try:
    psutil.cpu_percent(interval=0.1)
    if RUNTIME_ENV == "container":
        _warmup_usage = read_container_cpu_usage_seconds()
        if _warmup_usage is not None:
            CGROUP_CPU_SAMPLE = {"usage_seconds": _warmup_usage, "timestamp": time.monotonic()}
except Exception:
    pass

@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    try:
        get_session(request)
        return RedirectResponse(url="/")
    except HTTPException:
        pass
    
    login_html_path = os.path.join(STATIC_DIR, "login.html")
    with open(login_html_path, "r", encoding="utf-8") as f:
        return f.read()

@app.post("/login")
def login(creds: LoginRequest, response: Response, request: Request):
    enforce_login_rate_limit(request)
    if not ADMIN_PASSWORD:
         raise HTTPException(status_code=500, detail="Server configuration error")

    correct_username = secrets.compare_digest(creds.username, ADMIN_USERNAME)
    correct_password = secrets.compare_digest(creds.password, ADMIN_PASSWORD)
    
    if not (correct_username and correct_password):
        raise HTTPException(status_code=400, detail="Usuario o contraseña incorrectos")
    reset_login_rate_limit(request)

    profile_settings = get_profile_settings()
    force_password_change = not profile_settings.get("password_initialized", False)

    session_token = "session_" + secrets.token_urlsafe(32)
    csrf_token = secrets.token_urlsafe(32)
    session_store[session_token] = {
        "username": ADMIN_USERNAME,
        "expires_at": time.time() + SESSION_TTL_SEC,
        "csrf": csrf_token,
        "force_password_change": force_password_change,
    }

    response.set_cookie(
        key=COOKIE_NAME,
        value=session_token,
        httponly=True,
        samesite="strict",
        secure=COOKIE_SECURE
    )
    response.set_cookie(
        key=CSRF_COOKIE_NAME,
        value=csrf_token,
        httponly=False,
        samesite="strict",
        secure=COOKIE_SECURE
    )
    return {"message": "Login successful", "force_password_change": force_password_change}

@app.post("/logout")
def logout(response: Response, request: Request, csrf_ok: bool = Depends(require_csrf)):
    token = request.cookies.get(COOKIE_NAME)
    if token and token in session_store:
        del session_store[token]
    response.delete_cookie(COOKIE_NAME)
    response.delete_cookie(CSRF_COOKIE_NAME)
    return {"message": "Logged out"}

@app.get("/api/profile")
def get_profile(request: Request, username: str = Depends(get_current_username)):
    profile = get_profile_settings()
    session = get_session(request)
    return {
        "app_name": profile["app_name"],
        "logo_data": profile["logo_data"],
        "admin_username": ADMIN_USERNAME,
        "force_password_change": bool(session.get("force_password_change", False)),
    }

@app.put("/api/profile")
def update_profile(req: ProfileUpdateRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    app_name = normalize_brand_name(req.app_name)
    logo_data = normalize_logo_data(req.logo_data)
    save_profile_settings(app_name, logo_data)
    return {"status": "success", "app_name": app_name, "logo_data": logo_data}

@app.put("/api/profile/password")
def update_profile_password(req: PasswordUpdateRequest, request: Request, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    global ADMIN_PASSWORD
    session = get_session(request)
    force_password_change = bool(session.get("force_password_change", False))
    current_password = req.current_password or ""

    if not force_password_change and not secrets.compare_digest(current_password, ADMIN_PASSWORD):
        raise HTTPException(status_code=400, detail="La contraseña actual es incorrecta")
    validate_admin_password_policy(req.new_password)
    if secrets.compare_digest(req.new_password, ADMIN_PASSWORD):
        raise HTTPException(status_code=400, detail="La nueva contraseña debe ser distinta")
    try:
        persist_env_key("ADMIN_PASSWORD", req.new_password)
    except Exception as e:
        print(f"Error persisting ADMIN_PASSWORD: {e}")
        raise HTTPException(status_code=500, detail="No se pudo persistir la contraseña")
    ADMIN_PASSWORD = req.new_password
    mark_password_initialized()

    current_token = request.cookies.get(COOKIE_NAME)
    for token in list(session_store.keys()):
        if token == current_token:
            session_store[token]["force_password_change"] = False
            continue
        if session_store[token].get("username") == ADMIN_USERNAME:
            del session_store[token]

    return {"status": "success", "message": "Contraseña actualizada correctamente."}

@app.get("/health")
def health():
    try:
        conn = get_db_connection()
        conn.close()
        return {"status": "ok", "database": "connected"}
    except Exception as e:
        print(f"Health check failed: {e}")
        return JSONResponse(
            status_code=503,
            content={"status": "error", "database": "disconnected"}
        )

@app.get("/", response_class=HTMLResponse)
def read_root(request: Request):
    try:
        get_session(request)
    except HTTPException:
        return RedirectResponse(url="/login")
        
    index_html_path = os.path.join(STATIC_DIR, "index.html")
    with open(index_html_path, "r", encoding="utf-8") as f:
        return f.read()

@app.post("/create-client")
def create_client(request: ClientRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    client_name = normalize_client_name(request.client_name, "Nombre de cliente")
    client_slug = normalize_user_slug(client_name, "Nombre de cliente")
    db_user = f"user_{client_slug}"
    db_pass = generate_password()
    db_name = normalize_identifier(request.db_name, "Nombre de base de datos")

    conn = get_db_connection()
    cur = conn.cursor()

    try:
        # 1. Create User
        cur.execute(sql.SQL("CREATE USER {} WITH PASSWORD %s").format(sql.Identifier(db_user)), [db_pass])
        
        # 2. Create Database
        cur.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(
            sql.Identifier(db_name),
            sql.Identifier(db_user)
        ))
        
        # 3. Revoke connect on database from public
        cur.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM public").format(sql.Identifier(db_name)))
        cur.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(db_name), sql.Identifier(db_user)))
        cur.execute(sql.SQL("REVOKE CONNECT ON DATABASE postgres FROM {}").format(sql.Identifier(db_user)))
        
        # 4. Save metadata
        cur.execute(
            "INSERT INTO managed_clients (client_name, db_name, db_user, db_password) VALUES (%s, %s, %s, %s)",
            (client_name, db_name, db_user, encrypt_secret(db_pass))
        )

        pool_sync_ok = sync_pgbouncer_auth()
        public_db_endpoint = get_public_db_endpoint()

        response = {
            "status": "success",
            "connection_info": {
                "host": public_db_endpoint["host"],
                "port": public_db_endpoint["port"],
                "database": db_name,
                "user": db_user,
                "password": db_pass,
                "connection_mode": "pooled" if POOLING_ENABLED else "direct",
                "pool_mode": POOL_MODE if POOLING_ENABLED else None,
                "runtime_env": public_db_endpoint["runtime_env"],
                "connection_string": f"postgresql://{db_user}:{db_pass}@{public_db_endpoint['host']}:{public_db_endpoint['port']}/{db_name}"
            }
        }
        if POOLING_ENABLED:
            response["pooling"] = {
                "enabled": True,
                "mode": POOL_MODE,
                "pgbouncer_port": PGBOUNCER_PORT
            }
            if not pool_sync_ok:
                response["warning"] = "PgBouncer auth sync failed. Run server/sync_pgbouncer_auth.py on the server."
        return response
    except Exception as e:
        print(f"Error creating client: {e}")
        raise HTTPException(status_code=400, detail="Error al crear cliente")
    finally:
        cur.close()
        conn.close()

@app.get("/clients")
def list_clients(username: str = Depends(get_current_username)):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT id, client_name, db_name, db_user, db_password, created_at FROM managed_clients ORDER BY created_at DESC")
        rows = cur.fetchall()
        db_names = [row[2] for row in rows]
        db_allow_map = {}
        if db_names:
            cur.execute("SELECT datname, datallowconn FROM pg_database WHERE datname = ANY(%s)", (db_names,))
            for name, allow in cur.fetchall():
                db_allow_map[name] = allow
        clients = []
        for row in rows:
            allow_conn = db_allow_map.get(row[2], True)
            clients.append({
                "id": row[0],
                "client_name": row[1],
                "db_name": row[2],
                "db_user": row[3],
                "created_at": row[5].isoformat() if row[5] else None,
                "paused": not allow_conn
            })
        return clients
    finally:
        cur.close()
        conn.close()

@app.put("/clients/{client_id}")
def update_client(client_id: int, request: UpdateClientRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    conn = get_db_connection()
    cur = conn.cursor()
    pool_sync_ok = True
    try:
        cur.execute("SELECT db_user, client_name FROM managed_clients WHERE id = %s", (client_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Client not found")
        
        db_user, current_client_name = row
        
        if request.new_password:
            # Update Postgres User Password
            cur.execute(sql.SQL("ALTER USER {} WITH PASSWORD %s").format(sql.Identifier(db_user)), [request.new_password])
            # Update Metadata
            cur.execute("UPDATE managed_clients SET db_password = %s WHERE id = %s", (encrypt_secret(request.new_password), client_id))
            pool_sync_ok = sync_pgbouncer_auth()
            
        if request.client_name and request.client_name != current_client_name:
            new_client_name = normalize_client_name(request.client_name, "Nombre de cliente")
            cur.execute("UPDATE managed_clients SET client_name = %s WHERE id = %s", (new_client_name, client_id))
            
        response = {"status": "success", "message": "Client updated successfully"}
        if POOLING_ENABLED and request.new_password and not pool_sync_ok:
            response["warning"] = "PgBouncer auth sync failed. Run server/sync_pgbouncer_auth.py on the server."
        return response
    except Exception as e:
        print(f"Error updating client: {e}")
        raise HTTPException(status_code=500, detail="Error al actualizar cliente")
    finally:
        cur.close()
        conn.close()

@app.delete("/clients/{client_id}")
def delete_client(client_id: int, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        # Get client details first
        cur.execute("SELECT db_name, db_user FROM managed_clients WHERE id = %s", (client_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Client not found")
        
        db_name, db_user = row

        # Drop Database
        # Force drop by terminating backends (Deep Clean Step 1)
        print(f"Terminating connections for {db_name}...")
        cur.execute(sql.SQL("""
            SELECT pg_terminate_backend(pg_stat_activity.pid)
            FROM pg_stat_activity
            WHERE pg_stat_activity.datname = {}
            AND pid <> pg_backend_pid();
        """).format(sql.Literal(db_name)))
        
        print(f"Dropping database {db_name}...")
        cur.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(sql.Identifier(db_name)))
        
        # Verify if database is really gone
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (db_name,))
        if cur.fetchone():
            raise Exception(f"Failed to drop database {db_name}. It still exists in PostgreSQL.")

        # Drop User (Deep Clean Step 2)
        print(f"Checking existence of user {db_user}...")
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (db_user,))
        if cur.fetchone():
            print(f"Cleaning up user {db_user}...")
            try:
                # Remove any objects owned by the user in the current database (postgres)
                # This ensures no 'zombie' objects are left behind in the main DB
                cur.execute(sql.SQL("DROP OWNED BY {}").format(sql.Identifier(db_user)))
            except Exception as e:
                print(f"Warning during DROP OWNED: {e}")

            print(f"Dropping user {db_user}...")
            cur.execute(sql.SQL("DROP USER IF EXISTS {}").format(sql.Identifier(db_user)))
        
        # Remove from metadata (Deep Clean Step 3)
        print(f"Removing metadata for client {client_id}...")
        cur.execute("DELETE FROM managed_clients WHERE id = %s", (client_id,))

        cur.execute("DELETE FROM sql_access_ip_databases WHERE db_name = %s", (db_name,))
        cur.execute("""
            DELETE FROM sql_access_ips
            WHERE id NOT IN (SELECT DISTINCT ip_id FROM sql_access_ip_databases)
        """)
        rebuild_pg_hba_rules()
        pool_sync_ok = sync_pgbouncer_auth()

        response = {"status": "success", "message": f"Client {client_id} deleted (Deep Clean)"}
        if POOLING_ENABLED and not pool_sync_ok:
            response["warning"] = "PgBouncer auth sync failed. Run server/sync_pgbouncer_auth.py on the server."
        return response
    except Exception as e:
        print(f"Error deleting client: {e}")
        raise HTTPException(status_code=500, detail="Error al eliminar cliente")
    finally:
        cur.close()
        conn.close()

@app.post("/clients/{client_id}/pause")
def pause_client(client_id: int, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT db_name, db_user FROM managed_clients WHERE id = %s", (client_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Client not found")
        db_name, db_user = row

        cur.execute(sql.SQL("ALTER DATABASE {} ALLOW_CONNECTIONS false").format(sql.Identifier(db_name)))
        cur.execute(sql.SQL("REVOKE CONNECT ON DATABASE {} FROM {}").format(sql.Identifier(db_name), sql.Identifier(db_user)))
        cur.execute(sql.SQL("""
            SELECT pg_terminate_backend(pg_stat_activity.pid)
            FROM pg_stat_activity
            WHERE pg_stat_activity.datname = {}
            AND pid <> pg_backend_pid();
        """).format(sql.Literal(db_name)))

        return {"status": "success", "message": f"Database {db_name} paused"}
    except Exception as e:
        print(f"Error pausing database: {e}")
        raise HTTPException(status_code=500, detail="Error al pausar base de datos")
    finally:
        cur.close()
        conn.close()

@app.post("/clients/{client_id}/resume")
def resume_client(client_id: int, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT db_name, db_user FROM managed_clients WHERE id = %s", (client_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Client not found")
        db_name, db_user = row

        cur.execute(sql.SQL("ALTER DATABASE {} ALLOW_CONNECTIONS true").format(sql.Identifier(db_name)))
        cur.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(db_name), sql.Identifier(db_user)))

        return {"status": "success", "message": f"Database {db_name} resumed"}
    except Exception as e:
        print(f"Error resuming database: {e}")
        raise HTTPException(status_code=500, detail="Error al reanudar base de datos")
    finally:
        cur.close()
        conn.close()

@app.get("/list-databases")
def list_databases(username: str = Depends(get_current_username)):
    # Keep this for compatibility or debug
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT datname FROM pg_database WHERE datistemplate = false;")
    rows = cur.fetchall()
    dbs = [row[0] for row in rows]
    cur.close()
    conn.close()
    return {"databases": dbs}

@app.get("/api/stats")
def get_stats(username: str = Depends(get_current_username)):
    runtime_stats = get_runtime_stats()
    
    # Get connections per DB
    conn = get_db_connection()
    cur = conn.cursor()
    db_connections = {}
    try:
        cur.execute("""
            SELECT datname, count(*) 
            FROM pg_stat_activity 
            WHERE datname IS NOT NULL 
            GROUP BY datname;
        """)
        rows = cur.fetchall()
        for row in rows:
            db_connections[row[0]] = row[1]
    except Exception as e:
        print(f"Error getting db stats: {e}")
    finally:
        cur.close()
        conn.close()

    return {
        "cpu": runtime_stats["cpu"]["percent"],
        "cpu_details": runtime_stats["cpu"],
        "memory": runtime_stats["memory"],
        "runtime_env": runtime_stats["runtime_env"],
        "connections": db_connections
    }

@app.get("/api/ports")
def get_ports(username: str = Depends(get_current_username)):
    try:
        payload = get_firewall_status_payload()
        if payload.get("status") == "error":
            return {
                "status": "error",
                "message": "Could not get firewall status",
                "detail": payload.get("detail"),
                "backend": payload.get("backend"),
                "ports": [],
                "manageable": payload.get("manageable", False),
                "runtime_env": RUNTIME_ENV,
                "protected_ports": sorted(PROTECTED_PORTS),
                "sql_port": PUBLIC_DB_PORT,
            }
        return {
            "status": payload.get("status", "inactive"),
            "backend": payload.get("backend", FIREWALL_BACKEND),
            "ports": payload.get("ports", []),
            "detail": payload.get("detail"),
            "manageable": payload.get("manageable", FIREWALL_BACKEND != "none"),
            "runtime_env": RUNTIME_ENV,
            "protected_ports": sorted(PROTECTED_PORTS),
            "sql_port": PUBLIC_DB_PORT,
        }
    except Exception as e:
        print(f"Error getting ports: {e}")
        return {"status": "error", "message": str(e), "ports": [], "runtime_env": RUNTIME_ENV, "protected_ports": sorted(PROTECTED_PORTS), "sql_port": PUBLIC_DB_PORT}

@app.post("/api/ports/open")
def open_port(req: PortRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    try:
        detail = protected_port_detail(req.port)
        if detail:
            raise HTTPException(status_code=403, detail=detail)
        if not is_port_allowed(req.port):
            raise HTTPException(status_code=403, detail="Puerto no permitido por la politica ALLOWED_PORTS")
        if FIREWALL_BACKEND == "none":
            raise HTTPException(status_code=409, detail=get_firewall_status_payload().get("detail"))
        result = allow_port_rule(req.port, req.protocol)
        
        if result.returncode == 0:
            return {"status": "success", "message": f"Port {req.port}/{req.protocol} opened"}
        else:
            raise HTTPException(status_code=500, detail=result.stderr or "Failed to open port")
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error opening port: {e}")
        raise HTTPException(status_code=500, detail="Error al abrir puerto")

@app.post("/api/ports/close")
def close_port(req: PortRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    try:
        detail = protected_port_detail(req.port)
        if detail:
            raise HTTPException(status_code=403, detail=detail)
        if not is_port_allowed(req.port):
            raise HTTPException(status_code=403, detail="Puerto no permitido por la politica ALLOWED_PORTS")
        if FIREWALL_BACKEND == "none":
            raise HTTPException(status_code=409, detail=get_firewall_status_payload().get("detail"))
        result = revoke_port_rule(req.port, req.protocol)

        if result.returncode == 0:
             return {"status": "success", "message": f"Port {req.port}/{req.protocol} closed"}
        else:
             raise HTTPException(status_code=500, detail=result.stderr or "Failed to close port")
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error closing port: {e}")
        raise HTTPException(status_code=500, detail="Error al cerrar puerto")

@app.get("/api/sql-access")
def get_sql_access(username: str = Depends(get_current_username)):
    entries = []
    allowed = []
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT ips.ip_cidr,
                   COALESCE(array_agg(map.db_name ORDER BY map.db_name) FILTER (WHERE map.db_name IS NOT NULL), ARRAY[]::text[])
            FROM sql_access_ips ips
            LEFT JOIN sql_access_ip_databases map ON map.ip_id = ips.id
            GROUP BY ips.ip_cidr
            ORDER BY ips.ip_cidr
        """)
        rows = cur.fetchall()
        for ip_cidr, db_names in rows:
            entries.append({"ip": ip_cidr, "databases": db_names})
            allowed.append(ip_cidr)
    except Exception:
        return {"status": "error", "message": "No se pudo leer la configuración SQL", "allowed": [], "public_access": False, "entries": []}
    finally:
        cur.close()
        conn.close()
    try:
        if FIREWALL_BACKEND == "none":
            enforcement = "haproxy_acl" if POOLING_ENABLED else "pg_hba"
            detail = (
                f"El acceso SQL se aplica con HAProxy sobre el puerto {PUBLIC_DB_PORT}."
                if enforcement == "haproxy_acl"
                else "El acceso SQL se aplica con reglas pg_hba de PostgreSQL."
            )
            return {
                "status": "managed",
                "backend": FIREWALL_BACKEND,
                "enforcement": enforcement,
                "detail": detail,
                "allowed": allowed,
                "public_access": "0.0.0.0/0" in allowed,
                "entries": entries,
                "runtime_env": RUNTIME_ENV,
            }
        payload = get_firewall_status_payload()
        if payload.get("status") == "error":
            return {
                "status": "error",
                "message": "Could not get firewall status",
                "detail": payload.get("detail"),
                "backend": payload.get("backend"),
                "enforcement": "firewall",
                "allowed": allowed,
                "public_access": False,
                "entries": entries,
                "runtime_env": RUNTIME_ENV,
            }
        return {
            "status": payload.get("status", "inactive"),
            "backend": payload.get("backend", FIREWALL_BACKEND),
            "enforcement": "firewall",
            "detail": payload.get("detail"),
            "allowed": allowed,
            "public_access": payload.get("public_sql", False),
            "entries": entries,
            "runtime_env": RUNTIME_ENV,
        }
    except Exception as e:
        return {"status": "error", "message": str(e), "allowed": allowed, "public_access": False, "entries": entries, "runtime_env": RUNTIME_ENV}

@app.post("/api/sql-access/allow")
def allow_sql_access(req: SqlAccessAssignRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    try:
        ip_value = normalize_sql_ip(req.ip)
        requested = [normalize_identifier(db, "Base de datos") for db in req.databases]
        unique_dbs = []
        seen = set()
        for db_name in requested:
            if db_name not in seen:
                seen.add(db_name)
                unique_dbs.append(db_name)
        if not unique_dbs:
            raise HTTPException(status_code=400, detail="Debes seleccionar al menos una base de datos")
        conn = get_db_connection()
        cur = conn.cursor()
        try:
            cur.execute("SELECT db_name FROM managed_clients WHERE db_name = ANY(%s)", (unique_dbs,))
            existing = {row[0] for row in cur.fetchall()}
            missing = [db for db in unique_dbs if db not in existing]
            if missing:
                raise HTTPException(status_code=400, detail="Base de datos no encontrada")
            cur.execute("""
                INSERT INTO sql_access_ips (ip_cidr)
                VALUES (%s)
                ON CONFLICT (ip_cidr) DO UPDATE SET ip_cidr = EXCLUDED.ip_cidr
                RETURNING id
            """, (ip_value,))
            ip_id = cur.fetchone()[0]
            cur.execute("DELETE FROM sql_access_ip_databases WHERE ip_id = %s", (ip_id,))
            for db_name in unique_dbs:
                cur.execute("""
                    INSERT INTO sql_access_ip_databases (ip_id, db_name)
                    VALUES (%s, %s)
                    ON CONFLICT (ip_id, db_name) DO NOTHING
                """, (ip_id, db_name))
        finally:
            cur.close()
            conn.close()
        result = allow_sql_firewall(ip_value)
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=result.stderr or "Failed to allow IP")
        rebuild_pg_hba_rules()
        return {"status": "success", "message": f"IP {ip_value} allowed", "databases": unique_dbs}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail="Error al permitir IP")

@app.post("/api/sql-access/revoke")
def revoke_sql_access(req: SqlAccessRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    try:
        ip_value = normalize_sql_ip(req.ip)
        conn = get_db_connection()
        cur = conn.cursor()
        try:
            cur.execute("SELECT id FROM sql_access_ips WHERE ip_cidr = %s", (ip_value,))
            row = cur.fetchone()
            if row:
                ip_id = row[0]
                cur.execute("DELETE FROM sql_access_ip_databases WHERE ip_id = %s", (ip_id,))
                cur.execute("DELETE FROM sql_access_ips WHERE id = %s", (ip_id,))
        finally:
            cur.close()
            conn.close()
        result = revoke_sql_firewall(ip_value)
        if result.returncode == 0:
            rebuild_pg_hba_rules()
            return {"status": "success", "message": f"IP {ip_value} revoked"}
        raise HTTPException(status_code=500, detail=result.stderr or "Failed to revoke IP")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail="Error al revocar IP")

@app.get("/api/pooling/status")
def get_pooling_status(username: str = Depends(get_current_username)):
    data = {
        "enabled": POOLING_ENABLED,
        "mode": POOL_MODE,
        "public_port": PUBLIC_DB_PORT,
        "postgres_port": DB_PORT,
        "pgbouncer_host": PGBOUNCER_HOST,
        "pgbouncer_port": PGBOUNCER_PORT,
        "services": {
            "haproxy": get_service_status("haproxy") if POOLING_ENABLED else "disabled",
            "pgbouncer": get_service_status("pgbouncer") if POOLING_ENABLED else "disabled"
        }
    }
    if not POOLING_ENABLED:
        return data
    try:
        data["summary"] = get_pooling_snapshot()
    except Exception as e:
        data["summary"] = {"error": str(e)}
    return data

@app.get("/api/config")
def get_config(username: str = Depends(get_current_username)):
    public_db_endpoint = get_public_db_endpoint()
    return {
        "public_db_host": public_db_endpoint["host"],
        "public_db_port": public_db_endpoint["port"],
        "public_db_host_source": public_db_endpoint["host_source"],
        "pooling_enabled": POOLING_ENABLED,
        "firewall_backend": FIREWALL_BACKEND,
        "runtime_env": RUNTIME_ENV,
        "protected_ports": sorted(PROTECTED_PORTS),
        "app_web_port": APP_WEB_PORT,
        "pool_mode": POOL_MODE,
        "postgres_port": DB_PORT,
        "pgbouncer_host": PGBOUNCER_HOST,
        "pgbouncer_port": PGBOUNCER_PORT
    }

app.mount("/static", StaticFiles(directory="static"), name="static")
