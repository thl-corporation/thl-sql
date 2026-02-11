import requests
import sys
import time
import os
from dotenv import load_dotenv

# Load environment variables
load_dotenv(os.path.join(os.path.dirname(__file__), 'backend', '.env'))

BASE_URL = "http://66.55.75.32"
USERNAME = os.getenv("ADMIN_USERNAME", "admin")
PASSWORD = os.getenv("ADMIN_PASSWORD")

if not PASSWORD:
    print("Error: ADMIN_PASSWORD not found in environment or .env file.")
    sys.exit(1)

def test_remote_flow():
    session = requests.Session()

    def get_csrf_headers():
        token = session.cookies.get("csrf_token")
        return {"X-CSRF-Token": token} if token else {}
    
    print(f"1. Conectando a {BASE_URL}...")
    try:
        # Login
        login_payload = {"username": USERNAME, "password": PASSWORD}
        resp = session.post(f"{BASE_URL}/login", json=login_payload)
        
        if resp.status_code != 200:
            print(f"ERROR: Falló el login. Status: {resp.status_code}, Body: {resp.text}")
            return False
            
        print("   Login exitoso.")
        
        # Check current clients
        resp = session.get(f"{BASE_URL}/clients")
        if resp.status_code != 200:
            print(f"ERROR: No se pudo obtener la lista de clientes. Status: {resp.status_code}")
            return False
        
        clients = resp.json()
        print(f"   Clientes actuales: {len(clients)}")
        
        # Create temporary test DB
        test_db = "test_verify_remote_db"
        test_user = "test_user_remote"
        test_pass = "test_pass_123"
        
        # Check if already exists and delete if so
        existing = next((c for c in clients if c['db_name'] == test_db), None)
        if existing:
            print(f"   La base de datos de prueba {test_db} ya existe. Eliminándola primero...")
        resp = session.delete(f"{BASE_URL}/clients/{existing['id']}", headers=get_csrf_headers())
            if resp.status_code != 200:
                print(f"ERROR: No se pudo limpiar la base de datos de prueba existente. Status: {resp.status_code}")
                return False
            print("   Limpieza completada.")
            time.sleep(2)

        print(f"2. Creando base de datos de prueba: {test_db}...")
        create_payload = {
            "client_name": "Test Client Remote",
            "db_name": test_db
        }
        resp = session.post(f"{BASE_URL}/create-client", json=create_payload, headers=get_csrf_headers())
        if resp.status_code != 200:
            print(f"ERROR: Falló la creación. Status: {resp.status_code}, Body: {resp.text}")
            return False
        
        client_data = resp.json()
        # ID is not returned in create response, fetch from list
        print(f"   Creado exitosamente. Buscando ID...")
        
        # Verify creation in list and get ID
        resp = session.get(f"{BASE_URL}/clients")
        clients = resp.json()
        target_client = next((c for c in clients if c['db_name'] == test_db), None)
        
        if not target_client:
            print("ERROR: La base de datos creada no aparece en la lista.")
            return False
            
        client_id = target_client['id']
        print(f"   Verificado en la lista. ID encontrado: {client_id}")
        
        # Delete
        print(f"3. Eliminando base de datos {test_db} (Probando el fix de conexiones)...")
        resp = session.delete(f"{BASE_URL}/clients/{client_id}", headers=get_csrf_headers())
        
        if resp.status_code == 200:
            print("   Eliminación reportada como exitosa por el servidor.")
        else:
            print(f"ERROR: Falló la eliminación. Status: {resp.status_code}, Body: {resp.text}")
            return False
            
        # Verify deletion in list
        resp = session.get(f"{BASE_URL}/clients")
        clients = resp.json()
        found = any(c['db_name'] == test_db for c in clients)
        if found:
            print("ERROR: La base de datos sigue apareciendo en la lista después de borrar.")
            return False
            
        print("   Verificado: Ya no aparece en la lista.")
        print("\n¡PRUEBA EXITOSA! El servidor remoto está gestionando correctamente las conexiones y borrados.")
        return True

    except Exception as e:
        print(f"EXCEPCIÓN CRÍTICA: {e}")
        return False

if __name__ == "__main__":
    success = test_remote_flow()
    sys.exit(0 if success else 1)
