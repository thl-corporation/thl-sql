import requests
import sys
import os
from dotenv import load_dotenv

# Load environment variables
load_dotenv(os.path.join(os.path.dirname(__file__), 'backend', '.env'))

# Configuration
BASE_URL = "http://127.0.0.1:8000"
USERNAME = os.getenv("ADMIN_USERNAME", "admin")
PASSWORD = os.getenv("ADMIN_PASSWORD")

if not PASSWORD:
    print("Error: ADMIN_PASSWORD not found in environment or .env file.")
    sys.exit(1)

session = requests.Session()

def test_login():
    print(f"Testing Login to {BASE_URL}...")
    try:
        # 1. Get Login Page (to check connectivity)
        r = session.get(f"{BASE_URL}/login")
        if r.status_code != 200:
            print(f"FAILED: Could not reach login page. Status: {r.status_code}")
            return False

        # 2. Perform Login
        payload = {"username": USERNAME, "password": PASSWORD}
        r = session.post(f"{BASE_URL}/login", json=payload)
        
        if r.status_code == 200:
            print("SUCCESS: Login successful.")
            return True
        else:
            print(f"FAILED: Login failed. Status: {r.status_code}, Response: {r.text}")
            return False
    except Exception as e:
        print(f"ERROR during login: {e}")
        return False

def test_create_db():
    print("\nTesting Database Creation...")
    payload = {
        "client_name": "Test Client Automated",
        "db_name": "test_db_automated_01"
    }
    
    try:
        r = session.post(f"{BASE_URL}/create-client", json=payload)
        
        if r.status_code == 200:
            data = r.json()
            print("SUCCESS: Database created successfully.")
            print(f"Details: {data}")
            return True
        elif r.status_code == 400 and "already exists" in r.text:
             print("SUCCESS (Partial): Database already exists (Test ran before).")
             return True
        else:
            print(f"FAILED: Create DB failed. Status: {r.status_code}, Response: {r.text}")
            return False
    except Exception as e:
        print(f"ERROR during create db: {e}")
        return False

if __name__ == "__main__":
    if test_login():
        if test_create_db():
            print("\nALL TESTS PASSED.")
            sys.exit(0)
        else:
            sys.exit(1)
    else:
        sys.exit(1)
