import os
import sys

import psycopg2
import requests
from dotenv import load_dotenv


load_dotenv(os.path.join(os.path.dirname(__file__), "backend", ".env"))

BACKEND_PORT = os.getenv("BACKEND_BIND_PORT", "8000")
BASE_URL = os.getenv("VERIFY_BASE_URL", f"http://127.0.0.1:{BACKEND_PORT}")
USERNAME = os.getenv("ADMIN_USERNAME", "admin")
PASSWORD = os.getenv("ADMIN_PASSWORD")
REQUIRE_POOLING = os.getenv("REQUIRE_POOLING", "true").lower() in ("1", "true", "yes")
VERIFY_TIMEOUT_SEC = int(os.getenv("VERIFY_TIMEOUT_SEC", "60"))

if not PASSWORD:
    print("Error: ADMIN_PASSWORD not found in environment or .env file.")
    sys.exit(1)


session = requests.Session()


def get_csrf_headers():
    token = session.cookies.get("csrf_token")
    return {"X-CSRF-Token": token} if token else {}


def connect_sql(connection_info: dict):
    conn = psycopg2.connect(
        host="127.0.0.1",
        port=connection_info["port"],
        database=connection_info["database"],
        user=connection_info["user"],
        password=connection_info["password"],
        connect_timeout=VERIFY_TIMEOUT_SEC,
        application_name="verify_deployment_sql",
    )
    conn.autocommit = True
    try:
        cur = conn.cursor()
        cur.execute("SELECT current_database(), current_user, 1")
        return cur.fetchone()
    finally:
        conn.close()


def test_login():
    print(f"1. Testing login to {BASE_URL}...")
    try:
        r = session.get(f"{BASE_URL}/login", timeout=VERIFY_TIMEOUT_SEC)
        if r.status_code != 200:
            print(f"FAILED: Could not reach login page. Status: {r.status_code}")
            return False

        payload = {"username": USERNAME, "password": PASSWORD}
        r = session.post(f"{BASE_URL}/login", json=payload, timeout=VERIFY_TIMEOUT_SEC)
        if r.status_code != 200:
            print(f"FAILED: Login failed. Status: {r.status_code}, Response: {r.text}")
            return False
        print("   Login successful.")
        return True
    except Exception as e:
        print(f"ERROR during login: {e}")
        return False


def test_pooling():
    print("2. Testing pooling endpoint...")
    try:
        r = session.get(f"{BASE_URL}/api/pooling/status", timeout=VERIFY_TIMEOUT_SEC)
        if r.status_code != 200:
            print(f"FAILED: Pooling status failed. Status: {r.status_code}, Response: {r.text}")
            return False
        payload = r.json()
        print(f"   Pooling payload: {payload}")
        if REQUIRE_POOLING and not payload.get("enabled"):
            print("FAILED: Pooling should be enabled but is disabled.")
            return False
        return True
    except Exception as e:
        print(f"ERROR during pooling validation: {e}")
        return False


def test_create_db_and_sql_proxy():
    print("3. Testing database creation and SQL proxy...")
    payload = {"client_name": "Test Client Automated", "db_name": "test_db_automated_01"}
    target_id = None
    try:
        clients = session.get(f"{BASE_URL}/clients", timeout=VERIFY_TIMEOUT_SEC)
        if clients.status_code == 200:
            rows = clients.json()
            existing = next((row for row in rows if row.get("db_name") == payload["db_name"]), None)
            if existing:
                session.delete(f"{BASE_URL}/clients/{existing['id']}", headers=get_csrf_headers(), timeout=VERIFY_TIMEOUT_SEC)

        r = session.post(f"{BASE_URL}/create-client", json=payload, headers=get_csrf_headers(), timeout=VERIFY_TIMEOUT_SEC)
        if r.status_code != 200:
            print(f"FAILED: Create DB failed. Status: {r.status_code}, Response: {r.text}")
            return False

        data = r.json()
        print(f"   Created: {data}")

        clients = session.get(f"{BASE_URL}/clients", timeout=VERIFY_TIMEOUT_SEC)
        rows = clients.json()
        target = next((row for row in rows if row.get("db_name") == payload["db_name"]), None)
        if not target:
            print("FAILED: Could not find created database in /clients")
            return False
        target_id = target["id"]

        allow_resp = session.post(
            f"{BASE_URL}/api/sql-access/allow",
            json={"ip": "127.0.0.1/32", "databases": [payload["db_name"]]},
            headers=get_csrf_headers(),
            timeout=VERIFY_TIMEOUT_SEC,
        )
        if allow_resp.status_code != 200:
            print(f"FAILED: Could not allow 127.0.0.1/32. Status: {allow_resp.status_code}, Response: {allow_resp.text}")
            return False

        row = connect_sql(data["connection_info"])
        print(f"   SQL proxy OK: db={row[0]} user={row[1]}")
        return True
    except Exception as e:
        print(f"ERROR during DB/proxy validation: {e}")
        return False
    finally:
        try:
            session.post(
                f"{BASE_URL}/api/sql-access/revoke",
                json={"ip": "127.0.0.1/32"},
                headers=get_csrf_headers(),
                timeout=VERIFY_TIMEOUT_SEC,
            )
        except Exception:
            pass
        if target_id is not None:
            try:
                session.delete(f"{BASE_URL}/clients/{target_id}", headers=get_csrf_headers(), timeout=VERIFY_TIMEOUT_SEC)
            except Exception:
                pass


if __name__ == "__main__":
    if test_login() and test_pooling() and test_create_db_and_sql_proxy():
        print("\nALL TESTS PASSED.")
        sys.exit(0)
    sys.exit(1)
