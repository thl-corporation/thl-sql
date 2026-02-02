from fastapi import FastAPI, HTTPException, Depends
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

# Configuration - This should ideally come from env vars
DB_HOST = "localhost"
DB_NAME = "postgres"
DB_USER = "postgres"
# Assumes 'postgres' user has passwordless peer auth locally or trusted
# For this script to work, we might need to configure pg_hba.conf to allow 'postgres' user to connect via local socket with 'peer' or 'trust'
# On default Ubuntu install, 'sudo -u postgres' works. 
# We will run this app as root or use a specific system user that has DB creation rights.
# Ideally, we create a 'db_admin' user.

class ClientRequest(BaseModel):
    client_name: str
    db_name: str

def generate_password(length=24):
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for i in range(length))

def get_db_connection():
    # Connecting as postgres user (requires running as root or correct permissions)
    # We will assume this runs on the server where 'peer' auth is allowed for root->postgres 
    # OR we need to set a password for postgres user and use it here.
    # Let's try to connect via Unix socket which usually allows 'postgres' user if we are running as 'postgres' system user.
    try:
        conn = psycopg2.connect(database="postgres", user="postgres", host="/var/run/postgresql")
        conn.autocommit = True
        return conn
    except Exception as e:
        print(f"Connection error: {e}")
        raise HTTPException(status_code=500, detail="Could not connect to database system")

@app.post("/create-client")
def create_client(request: ClientRequest):
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
        
        # 3. Revoke connect on database from public (optional, for security)
        cur.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM public").format(sql.Identifier(db_name)))
        
        return {
            "status": "success",
            "connection_info": {
                "host": "YOUR_SERVER_IP", # We should get this dynamically
                "port": 5432,
                "database": db_name,
                "user": db_user,
                "password": db_pass,
                "connection_string": f"postgresql://{db_user}:{db_pass}@YOUR_SERVER_IP:5432/{db_name}"
            }
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        cur.close()
        conn.close()

@app.get("/list-databases")
def list_databases():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT datname FROM pg_database WHERE datistemplate = false;")
    rows = cur.fetchall()
    dbs = [row[0] for row in rows]
    cur.close()
    conn.close()
    return {"databases": dbs}

# Serve static files (Frontend)
app.mount("/", StaticFiles(directory="static", html=True), name="static")
