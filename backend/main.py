from fastapi import FastAPI, HTTPException, Depends, status, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from pydantic import BaseModel
import psycopg2
from psycopg2 import sql
import secrets
import string
import os
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
DB_HOST = "localhost"
DB_NAME = "postgres"
DB_USER = "postgres"

# Auth Configuration
ADMIN_USERNAME = "admin"
ADMIN_PASSWORD = "S@p0rt3"
COOKIE_NAME = "access_token"
# Simple token for this single-user app. In production use JWT.
SESSION_TOKEN = "session_" + secrets.token_urlsafe(32)

class ClientRequest(BaseModel):
    client_name: str
    db_name: str

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
        conn = psycopg2.connect(database="postgres", user="postgres", host="/var/run/postgresql")
        conn.autocommit = True
        return conn
    except Exception as e:
        print(f"Connection error: {e}")
        raise HTTPException(status_code=500, detail="Could not connect to database system")

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
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        cur.close()
        conn.close()

@app.get("/list-databases")
def list_databases(username: str = Depends(get_current_username)):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT datname FROM pg_database WHERE datistemplate = false;")
    rows = cur.fetchall()
    dbs = [row[0] for row in rows]
    cur.close()
    conn.close()
    return {"databases": dbs}

app.mount("/static", StaticFiles(directory="static"), name="static")
