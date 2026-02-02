from fastapi import FastAPI, HTTPException, Depends, status, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from pydantic import BaseModel
import psycopg2
from psycopg2 import sql
import secrets
import string
import os
import psutil
from dotenv import load_dotenv
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

# Load environment variables
load_dotenv()

app = FastAPI()

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
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "S@p0rt3")
COOKIE_NAME = os.getenv("COOKIE_NAME", "access_token")
# Simple token for this single-user app. In production use JWT.
SESSION_TOKEN = "session_" + secrets.token_urlsafe(32)

class ClientRequest(BaseModel):
    client_name: str
    db_name: str

class UpdateClientRequest(BaseModel):
    client_name: str | None = None
    new_password: str | None = None

class LoginRequest(BaseModel):
    username: str
    password: str

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
init_metadata_db()

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
    correct_username = secrets.compare_digest(creds.username, ADMIN_USERNAME)
    correct_password = secrets.compare_digest(creds.password, ADMIN_PASSWORD)
    
    if not (correct_username and correct_password):
        raise HTTPException(status_code=400, detail="Usuario o contraseña incorrectos")
    
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
        # Note: Need to terminate connections first usually, but for now simple drop
        # Force drop by terminating backends
        cur.execute(sql.SQL("""
            SELECT pg_terminate_backend(pg_stat_activity.pid)
            FROM pg_stat_activity
            WHERE pg_stat_activity.datname = {}
            AND pid <> pg_backend_pid();
        """).format(sql.Literal(db_name)))
        
        cur.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(sql.Identifier(db_name)))
        
        # Drop User
        cur.execute(sql.SQL("DROP USER IF EXISTS {}").format(sql.Identifier(db_user)))
        
        # Remove from metadata
        cur.execute("DELETE FROM managed_clients WHERE id = %s", (client_id,))
        
        return {"status": "success", "message": f"Client {client_id} deleted"}
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
    return {
        "cpu": cpu_percent,
        "memory": {
            "total": memory.total,
            "percent": memory.percent,
            "used": memory.used
        }
    }

app.mount("/static", StaticFiles(directory="static"), name="static")
