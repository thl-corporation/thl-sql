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
import psutil
import subprocess
import re
import time
import tempfile
from dotenv import load_dotenv
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from cryptography.fernet import Fernet

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

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", None)
PUBLIC_DB_HOST = os.getenv("PUBLIC_DB_HOST", DB_HOST)
PUBLIC_DB_PORT = int(os.getenv("PUBLIC_DB_PORT", "5432"))
PG_HBA_PATH = os.getenv("PG_HBA_PATH", "/etc/postgresql/16/main/pg_hba.conf")
PG_HBA_INCLUDE_PATH = os.getenv("PG_HBA_INCLUDE_PATH", "/etc/postgresql/16/main/pg_hba_sql_manager.conf")

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
ALLOWED_PORTS_ENV = os.getenv("ALLOWED_PORTS", "22,80,443,5432")
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

ALLOWED_PORTS = parse_allowed_ports(ALLOWED_PORTS_ENV)

def is_port_allowed(port: int):
    return ALLOWED_PORTS is None or port in ALLOWED_PORTS

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
    if str(net) in ("0.0.0.0/0", "::/0"):
        raise HTTPException(status_code=400, detail="No se permite acceso público")
    return str(net)

def parse_sql_access_rules(output: str):
    allowed = []
    public_access = False
    for line in output.splitlines():
        if "ALLOW" not in line:
            continue
        parts = line.split()
        if "ALLOW" not in parts:
            continue
        if not any(p.startswith("5432/") for p in parts):
            continue
        allow_index = parts.index("ALLOW")
        source_start = allow_index + 1
        if source_start < len(parts) and parts[source_start] == "IN":
            source_start += 1
        if source_start >= len(parts):
            continue
        source = " ".join(parts[source_start:])
        if source.startswith("Anywhere"):
            public_access = True
            continue
        if source not in allowed:
            allowed.append(source)
    return allowed, public_access

def read_file_content(path: str):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        result = run_sudo_command(["cat", path])
        if result.returncode == 0:
            return result.stdout
    return ""

def write_file_content(path: str, content: str):
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
                run_sudo_command(["chmod", "640", path])
                return True
        finally:
            try:
                os.unlink(tmp.name)
            except Exception:
                pass
    return False

def ensure_pg_hba_include():
    content = read_file_content(PG_HBA_PATH)
    include_line = f"include_if_exists '{PG_HBA_INCLUDE_PATH}'"
    if include_line not in content:
        updated = content.rstrip("\n") + "\n" + include_line + "\n"
        write_file_content(PG_HBA_PATH, updated)

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
        rows = cur.fetchall()
    finally:
        cur.close()
        conn.close()
    lines = [f"host {db_name} {db_user} {ip_cidr} scram-sha-256" for ip_cidr, db_name, db_user in rows]
    ensure_pg_hba_include()
    content = "\n".join(lines)
    if content and not content.endswith("\n"):
        content += "\n"
    write_file_content(PG_HBA_INCLUDE_PATH, content)
    result = run_sudo_command(["systemctl", "reload", "postgresql"])
    if result.returncode != 0:
        run_sudo_command(["systemctl", "restart", "postgresql"])

def encrypt_secret(value: str):
    return fernet.encrypt(value.encode()).decode()

def generate_password(length=24):
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for i in range(length))

def get_db_connection():
    try:
        conn = psycopg2.connect(
            database=DB_NAME,
            user=DB_USER,
            host=DB_HOST,
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
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
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
    except Exception as e:
        print(f"Error initializing metadata DB: {e}")
    finally:
        cur.close()
        conn.close()

# Initialize DB on startup
try:
    init_metadata_db()
except Exception as e:
    print(f"Startup Warning: Could not initialize database: {e}")

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
    
    session_token = "session_" + secrets.token_urlsafe(32)
    csrf_token = secrets.token_urlsafe(32)
    session_store[session_token] = {
        "username": ADMIN_USERNAME,
        "expires_at": time.time() + SESSION_TTL_SEC,
        "csrf": csrf_token
    }

    response.set_cookie(
        key=COOKIE_NAME,
        value=session_token,
        httponly=True,
        max_age=SESSION_TTL_SEC,
        samesite="strict",
        secure=COOKIE_SECURE
    )
    response.set_cookie(
        key=CSRF_COOKIE_NAME,
        value=csrf_token,
        httponly=False,
        max_age=SESSION_TTL_SEC,
        samesite="strict",
        secure=COOKIE_SECURE
    )
    return {"message": "Login successful"}

@app.post("/logout")
def logout(response: Response, request: Request, csrf_ok: bool = Depends(require_csrf)):
    token = request.cookies.get(COOKIE_NAME)
    if token and token in session_store:
        del session_store[token]
    response.delete_cookie(COOKIE_NAME)
    response.delete_cookie(CSRF_COOKIE_NAME)
    return {"message": "Logged out"}

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
        
        # 4. Save metadata
        cur.execute(
            "INSERT INTO managed_clients (client_name, db_name, db_user, db_password) VALUES (%s, %s, %s, %s)",
            (client_name, db_name, db_user, encrypt_secret(db_pass))
        )

        return {
            "status": "success",
            "connection_info": {
                "host": PUBLIC_DB_HOST, 
                "port": PUBLIC_DB_PORT,
                "database": db_name,
                "user": db_user,
                "password": db_pass,
                "connection_string": f"postgresql://{db_user}:{db_pass}@{PUBLIC_DB_HOST}:{PUBLIC_DB_PORT}/{db_name}"
            }
        }
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
            
        if request.client_name and request.client_name != current_client_name:
            new_client_name = normalize_client_name(request.client_name, "Nombre de cliente")
            cur.execute("UPDATE managed_clients SET client_name = %s WHERE id = %s", (new_client_name, client_id))
            
        return {"status": "success", "message": "Client updated successfully"}
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
        
        return {"status": "success", "message": f"Client {client_id} deleted (Deep Clean)"}
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
    # interval=None returns immediately, comparing to last call. 
    # First call may be 0, but subsequent calls will be accurate.
    cpu_percent = psutil.cpu_percent(interval=None) 
    memory = psutil.virtual_memory()
    
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
        "cpu": cpu_percent,
        "memory": {
            "total": memory.total,
            "percent": memory.percent,
            "used": memory.used
        },
        "connections": db_connections
    }

@app.get("/api/ports")
def get_ports(username: str = Depends(get_current_username)):
    try:
        # Check ufw status using helper
        cmd = ["ufw", "status"]
        result = run_sudo_command(cmd)
        
        if result.returncode != 0:
             return {"status": "error", "message": "Could not get firewall status", "detail": result.stderr, "ports": []}
        
        output = result.stdout
        lines = output.splitlines()
        
        ports = []
        is_active = False
        
        for line in lines:
            if "Status: active" in line:
                is_active = True
                continue
            
            if "ALLOW" in line:
                parts = line.split()
                if len(parts) >= 2:
                    port_proto = parts[0]
                    # action = parts[1] # ALLOW
                    
                    if "/" in port_proto:
                        p, proto = port_proto.split("/")
                    else:
                        p = port_proto
                        proto = "any"
                    if str(p) == "5432":
                        continue
                        
                    # Avoid duplicates (v6)
                    exists = False
                    for existing in ports:
                        if existing["port"] == p and existing["protocol"] == proto:
                            exists = True
                            break
                    if not exists:
                        ports.append({"port": p, "protocol": proto})

        return {
            "status": "active" if is_active else "inactive", 
            "ports": ports
        }
    except Exception as e:
        print(f"Error getting ports: {e}")
        return {"status": "error", "message": str(e), "ports": []}

@app.post("/api/ports/open")
def open_port(req: PortRequest, username: str = Depends(get_current_username), csrf_ok: bool = Depends(require_csrf)):
    try:
        if req.port == 5432:
            raise HTTPException(status_code=403, detail="Puerto SQL se gestiona por IP")
        if not is_port_allowed(req.port):
            raise HTTPException(status_code=403, detail="Puerto no permitido")
        cmd = ["ufw", "allow", f"{req.port}/{req.protocol}"]
        result = run_sudo_command(cmd)
        
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
        if req.port == 5432:
            raise HTTPException(status_code=403, detail="Puerto SQL se gestiona por IP")
        if not is_port_allowed(req.port):
            raise HTTPException(status_code=403, detail="Puerto no permitido")
        cmd = ["ufw", "delete", "allow", f"{req.port}/{req.protocol}"]
        result = run_sudo_command(cmd)

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
        cmd = ["ufw", "status"]
        result = run_sudo_command(cmd)
        if result.returncode != 0:
            return {"status": "error", "message": "Could not get firewall status", "detail": result.stderr, "allowed": allowed, "public_access": False, "entries": entries}
        output = result.stdout
        lines = output.splitlines()
        is_active = any("Status: active" in line for line in lines)
        _, public_access = parse_sql_access_rules(output)
        return {"status": "active" if is_active else "inactive", "allowed": allowed, "public_access": public_access, "entries": entries}
    except Exception as e:
        return {"status": "error", "message": str(e), "allowed": allowed, "public_access": False, "entries": entries}

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
        cmd = ["ufw", "allow", "from", ip_value, "to", "any", "port", "5432", "proto", "tcp"]
        result = run_sudo_command(cmd)
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
        cmd = ["ufw", "delete", "allow", "from", ip_value, "to", "any", "port", "5432", "proto", "tcp"]
        result = run_sudo_command(cmd)
        if result.returncode == 0:
            rebuild_pg_hba_rules()
            return {"status": "success", "message": f"IP {ip_value} revoked"}
        raise HTTPException(status_code=500, detail=result.stderr or "Failed to revoke IP")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail="Error al revocar IP")

@app.get("/api/config")
def get_config(username: str = Depends(get_current_username)):
    return {"public_db_host": PUBLIC_DB_HOST, "public_db_port": PUBLIC_DB_PORT}

app.mount("/static", StaticFiles(directory="static"), name="static")
