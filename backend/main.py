from fastapi import FastAPI, HTTPException, Depends, status, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from pydantic import BaseModel
import psycopg2
from psycopg2 import sql
import secrets
import string
import os
import psutil
import subprocess
import re
from dotenv import load_dotenv
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

# Load environment variables
load_dotenv()

app = FastAPI(title="PostgreSQL Manager", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", None)

# Auth Configuration
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD")
if not ADMIN_PASSWORD:
    raise ValueError("ADMIN_PASSWORD env var is required")
COOKIE_NAME = os.getenv("COOKIE_NAME", "access_token")
ROOT_PASSWORD = os.getenv("ROOT_PASSWORD", None)
# Simple token for this single-user app. In production use JWT.
SESSION_TOKEN = "session_" + secrets.token_urlsafe(32)

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

class ClientRequest(BaseModel):
    client_name: str
    db_name: str

class UpdateClientRequest(BaseModel):
    client_name: str | None = None
    new_password: str | None = None

class LoginRequest(BaseModel):
    username: str
    password: str

class PortRequest(BaseModel):
    port: int
    protocol: str = "tcp"

def get_current_username(request: Request):
    token = request.cookies.get(COOKIE_NAME)
    if not token or token != SESSION_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated"
        )
    return ADMIN_USERNAME

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
    # If already logged in, redirect to dashboard
    token = request.cookies.get(COOKIE_NAME)
    if token == SESSION_TOKEN:
        return RedirectResponse(url="/")
    
    with open("static/login.html", "r", encoding="utf-8") as f:
        return f.read()

@app.post("/login")
def login(creds: LoginRequest, response: Response):
    # Debug logging (remove in production if needed, but useful now)
    print(f"Login attempt for user: {creds.username}")
    
    if not ADMIN_PASSWORD:
         print("CRITICAL ERROR: ADMIN_PASSWORD is not set in environment!")
         raise HTTPException(status_code=500, detail="Server configuration error")

    correct_username = secrets.compare_digest(creds.username, ADMIN_USERNAME)
    correct_password = secrets.compare_digest(creds.password, ADMIN_PASSWORD)
    
    if not (correct_username and correct_password):
        print("Login failed: Invalid credentials")
        raise HTTPException(status_code=400, detail="Usuario o contraseña incorrectos")
    
    print("Login successful")
    
    # Set cookie
    response.set_cookie(
        key=COOKIE_NAME,
        value=SESSION_TOKEN,
        httponly=True,
        max_age=3600 * 24, # 24 hours
        samesite="lax",
        secure=False # Set to True in production with HTTPS
    )
    return {"message": "Login successful"}

@app.post("/logout")
def logout(response: Response):
    response.delete_cookie(COOKIE_NAME)
    return {"message": "Logged out"}

@app.get("/", response_class=HTMLResponse)
def read_root(request: Request):
    # Check auth manually for the root page to redirect instead of 401
    token = request.cookies.get(COOKIE_NAME)
    if not token or token != SESSION_TOKEN:
        return RedirectResponse(url="/login")
        
    with open("static/index.html", "r", encoding="utf-8") as f:
        return f.read()

@app.post("/create-client")
def create_client(request: ClientRequest, username: str = Depends(get_current_username)):
    client_slug = request.client_name.lower().replace(" ", "_")
    db_user = f"user_{client_slug}"
    db_pass = generate_password()
    db_name = request.db_name.lower().replace(" ", "_")

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
            (request.client_name, db_name, db_user, db_pass)
        )

        return {
            "status": "success",
            "connection_info": {
                "host": "66.55.75.32", 
                "port": 5432,
                "database": db_name,
                "user": db_user,
                "password": db_pass,
                "connection_string": f"postgresql://{db_user}:{db_pass}@66.55.75.32:5432/{db_name}"
            }
        }
    except Exception as e:
        # Try to rollback creation if possible, or just fail
        # In autocommit mode, we can't rollback easily, so we rely on manual cleanup or retry
        raise HTTPException(status_code=400, detail=str(e))
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
        clients = []
        for row in rows:
            clients.append({
                "id": row[0],
                "client_name": row[1],
                "db_name": row[2],
                "db_user": row[3],
                "db_password": row[4],
                "created_at": row[5].isoformat() if row[5] else None
            })
        return clients
    finally:
        cur.close()
        conn.close()

@app.put("/clients/{client_id}")
def update_client(client_id: int, request: UpdateClientRequest, username: str = Depends(get_current_username)):
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
            cur.execute("UPDATE managed_clients SET db_password = %s WHERE id = %s", (request.new_password, client_id))
            
        if request.client_name and request.client_name != current_client_name:
            cur.execute("UPDATE managed_clients SET client_name = %s WHERE id = %s", (request.client_name, client_id))
            
        return {"status": "success", "message": "Client updated successfully"}
    except Exception as e:
        print(f"Error updating client: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        cur.close()
        conn.close()

@app.delete("/clients/{client_id}")
def delete_client(client_id: int, username: str = Depends(get_current_username)):
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
        
        return {"status": "success", "message": f"Client {client_id} deleted (Deep Clean)"}
    except Exception as e:
        print(f"Error deleting client: {e}")
        raise HTTPException(status_code=500, detail=str(e))
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
def open_port(req: PortRequest, username: str = Depends(get_current_username)):
    try:
        cmd = ["ufw", "allow", f"{req.port}/{req.protocol}"]
        result = run_sudo_command(cmd)
        
        if result.returncode == 0:
            return {"status": "success", "message": f"Port {req.port}/{req.protocol} opened"}
        else:
            raise HTTPException(status_code=500, detail=result.stderr or "Failed to open port")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/ports/close")
def close_port(req: PortRequest, username: str = Depends(get_current_username)):
    try:
        cmd = ["ufw", "delete", "allow", f"{req.port}/{req.protocol}"]
        result = run_sudo_command(cmd)

        if result.returncode == 0:
             return {"status": "success", "message": f"Port {req.port}/{req.protocol} closed"}
        else:
             raise HTTPException(status_code=500, detail=result.stderr or "Failed to close port")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

app.mount("/static", StaticFiles(directory="static"), name="static")
