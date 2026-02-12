import requests
import sys
import time
import os
import ipaddress
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), 'backend', '.env'))

BASE_URL = os.getenv("BASE_URL", "https://sql.thlcorporation.com")
USERNAME = os.getenv("ADMIN_USERNAME", "admin")
PASSWORD = os.getenv("ADMIN_PASSWORD")
TEST_PORT_ENV = os.getenv("TEST_PORT", "443").strip()
TEST_SQL_IP = os.getenv("TEST_SQL_IP", "144.91.101.204/32").strip()

if not PASSWORD:
    print("Error: ADMIN_PASSWORD not found in environment or .env file.")
    sys.exit(1)

def normalize_ip(value: str):
    net = ipaddress.ip_network(value.strip(), strict=False)
    return str(net)

def test_remote_flow():
    session = requests.Session()
    ok = True

    def fail(msg):
        nonlocal ok
        ok = False
        print(f"ERROR: {msg}")

    def get_csrf_headers():
        token = session.cookies.get("csrf_token")
        return {"X-CSRF-Token": token} if token else {}

    def request_json(method, path, expected=(200,), headers=None, **kwargs):
        url = f"{BASE_URL}{path}"
        resp = session.request(method, url, headers=headers, **kwargs)
        if resp.status_code not in expected:
            fail(f"{method} {path} falló. Status: {resp.status_code}, Body: {resp.text}")
            return None
        try:
            return resp.json()
        except Exception:
            fail(f"{method} {path} devolvió JSON inválido")
            return None

    print(f"1. Conectando a {BASE_URL}...")
    try:
        login_payload = {"username": USERNAME, "password": PASSWORD}
        resp = session.post(f"{BASE_URL}/login", json=login_payload)

        if resp.status_code != 200:
            fail(f"Falló el login. Status: {resp.status_code}, Body: {resp.text}")
            return False

        print("   Login exitoso.")

        print("2. Probando tarjetas y listas...")
        stats = request_json("GET", "/api/stats")
        if stats is not None:
            if "cpu" not in stats or "memory" not in stats or "connections" not in stats:
                fail("La tarjeta de métricas no tiene el formato esperado")

        ports_data = request_json("GET", "/api/ports")
        if ports_data is not None:
            ports_list = ports_data.get("ports")
            if not isinstance(ports_list, list):
                fail("La lista de puertos no tiene el formato esperado")

        sql_data = request_json("GET", "/api/sql-access")
        if sql_data is not None:
            allowed_list = sql_data.get("allowed")
            if not isinstance(allowed_list, list):
                fail("La lista de IPs permitidas no tiene el formato esperado")

        config = request_json("GET", "/api/config")
        if config is not None:
            if "public_db_host" not in config or "public_db_port" not in config:
                fail("La tarjeta de configuración no tiene el formato esperado")

        resp = session.get(f"{BASE_URL}/clients")
        if resp.status_code != 200:
            fail(f"No se pudo obtener la lista de clientes. Status: {resp.status_code}")
            return False

        clients = resp.json()
        if not isinstance(clients, list):
            fail("La lista de clientes no tiene el formato esperado")
            return False
        print(f"   Clientes actuales: {len(clients)}")

        test_db = "test_verify_remote_db"

        existing = next((c for c in clients if c.get('db_name') == test_db), None)
        if existing:
            print(f"   La base de datos de prueba {test_db} ya existe. Eliminándola primero...")
            resp = session.delete(f"{BASE_URL}/clients/{existing['id']}", headers=get_csrf_headers())
            if resp.status_code != 200:
                fail(f"No se pudo limpiar la base de datos de prueba existente. Status: {resp.status_code}")
                return False
            print("   Limpieza completada.")
            time.sleep(2)

        print(f"3. Creando base de datos de prueba: {test_db}...")
        create_payload = {
            "client_name": "Test Client Remote",
            "db_name": test_db
        }
        resp = session.post(f"{BASE_URL}/create-client", json=create_payload, headers=get_csrf_headers())
        if resp.status_code != 200:
            fail(f"Falló la creación. Status: {resp.status_code}, Body: {resp.text}")
            return False

        print("   Creado exitosamente. Buscando ID...")
        resp = session.get(f"{BASE_URL}/clients")
        clients = resp.json()
        target_client = next((c for c in clients if c.get('db_name') == test_db), None)

        if not target_client:
            fail("La base de datos creada no aparece en la lista.")
            return False

        client_id = target_client['id']
        print(f"   Verificado en la lista. ID encontrado: {client_id}")

        print(f"4. Eliminando base de datos {test_db}...")
        resp = session.delete(f"{BASE_URL}/clients/{client_id}", headers=get_csrf_headers())

        if resp.status_code != 200:
            fail(f"Falló la eliminación. Status: {resp.status_code}, Body: {resp.text}")
            return False

        resp = session.get(f"{BASE_URL}/clients")
        clients = resp.json()
        found = any(c.get('db_name') == test_db for c in clients)
        if found:
            fail("La base de datos sigue apareciendo en la lista después de borrar.")
            return False

        print("   Verificado: Ya no aparece en la lista.")

        print("5. Probando apertura y cierre de puertos...")
        if TEST_PORT_ENV:
            try:
                test_port = int(TEST_PORT_ENV)
            except Exception:
                fail("TEST_PORT inválido")
                test_port = None

            if test_port in (22, 80, 443, 5432):
                ports_before = request_json("GET", "/api/ports")
                ports_before_list = ports_before.get("ports", []) if ports_before else []
                def port_is_open(ports, port):
                    for p in ports:
                        try:
                            if int(p.get("port")) == int(port):
                                return True
                        except Exception:
                            continue
                    return False
                if ports_before is not None and not port_is_open(ports_before_list, test_port):
                    fail(f"El puerto {test_port} no aparece en la lista")
                print(f"   Puerto {test_port} protegido. Se omite abrir/cerrar.")
                test_port = None

            if test_port:
                ports_before = request_json("GET", "/api/ports")
                ports_before_list = ports_before.get("ports", []) if ports_before else []

                def port_is_open(ports, port):
                    for p in ports:
                        try:
                            if int(p.get("port")) == int(port):
                                return True
                        except Exception:
                            continue
                    return False

                was_open = port_is_open(ports_before_list, test_port)

                if was_open:
                    resp = session.post(
                        f"{BASE_URL}/api/ports/close",
                        json={"port": test_port, "protocol": "tcp"},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo cerrar el puerto {test_port}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        ports_after = request_json("GET", "/api/ports")
                        if ports_after and port_is_open(ports_after.get("ports", []), test_port):
                            fail(f"El puerto {test_port} sigue abierto después de cerrar")

                    resp = session.post(
                        f"{BASE_URL}/api/ports/open",
                        json={"port": test_port, "protocol": "tcp"},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo reabrir el puerto {test_port}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        ports_after = request_json("GET", "/api/ports")
                        if ports_after and not port_is_open(ports_after.get("ports", []), test_port):
                            fail(f"El puerto {test_port} no aparece en la lista después de abrir")
                else:
                    resp = session.post(
                        f"{BASE_URL}/api/ports/open",
                        json={"port": test_port, "protocol": "tcp"},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo abrir el puerto {test_port}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        ports_after = request_json("GET", "/api/ports")
                        if ports_after and not port_is_open(ports_after.get("ports", []), test_port):
                            fail(f"El puerto {test_port} no aparece en la lista después de abrir")

                    resp = session.post(
                        f"{BASE_URL}/api/ports/close",
                        json={"port": test_port, "protocol": "tcp"},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo cerrar el puerto {test_port}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        ports_after = request_json("GET", "/api/ports")
                        if ports_after and port_is_open(ports_after.get("ports", []), test_port):
                            fail(f"El puerto {test_port} sigue abierto después de cerrar")
        else:
            print("   TEST_PORT no configurado. Se omite la prueba de puertos.")

        print("6. Probando acceso SQL por IP...")
        if TEST_SQL_IP:
            try:
                test_ip_norm = normalize_ip(TEST_SQL_IP)
            except Exception:
                fail("TEST_SQL_IP inválido")
                test_ip_norm = None

            if test_ip_norm:
                sql_before = request_json("GET", "/api/sql-access")
                allowed = sql_before.get("allowed", []) if sql_before else []

                def normalize_list(items):
                    normalized = []
                    for item in items:
                        try:
                            normalized.append(normalize_ip(item))
                        except Exception:
                            normalized.append(item)
                    return normalized

                allowed_norm = normalize_list(allowed)
                was_allowed = test_ip_norm in allowed_norm

                if was_allowed:
                    resp = session.post(
                        f"{BASE_URL}/api/sql-access/revoke",
                        json={"ip": test_ip_norm},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo revocar la IP {test_ip_norm}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        sql_after = request_json("GET", "/api/sql-access")
                        allowed_after = normalize_list(sql_after.get("allowed", [])) if sql_after else []
                        if test_ip_norm in allowed_after:
                            fail("La IP sigue en la lista después de revocar")

                    resp = session.post(
                        f"{BASE_URL}/api/sql-access/allow",
                        json={"ip": test_ip_norm},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo restaurar la IP {test_ip_norm}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        sql_after = request_json("GET", "/api/sql-access")
                        allowed_after = normalize_list(sql_after.get("allowed", [])) if sql_after else []
                        if test_ip_norm not in allowed_after:
                            fail("La IP no aparece en la lista después de permitir")
                else:
                    resp = session.post(
                        f"{BASE_URL}/api/sql-access/allow",
                        json={"ip": test_ip_norm},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo permitir la IP {test_ip_norm}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        sql_after = request_json("GET", "/api/sql-access")
                        allowed_after = normalize_list(sql_after.get("allowed", [])) if sql_after else []
                        if test_ip_norm not in allowed_after:
                            fail("La IP no aparece en la lista después de permitir")

                    resp = session.post(
                        f"{BASE_URL}/api/sql-access/revoke",
                        json={"ip": test_ip_norm},
                        headers=get_csrf_headers()
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo revocar la IP {test_ip_norm}. Status: {resp.status_code}, Body: {resp.text}")
                    else:
                        sql_after = request_json("GET", "/api/sql-access")
                        allowed_after = normalize_list(sql_after.get("allowed", [])) if sql_after else []
                        if test_ip_norm in allowed_after:
                            fail("La IP sigue en la lista después de revocar")
        else:
            print("   TEST_SQL_IP no configurado. Se omite la prueba de IP.")

        if ok:
            print("\n¡PRUEBAS COMPLETADAS! El panel respondió correctamente en listas y acciones.")
        return ok

    except Exception as e:
        print(f"EXCEPCIÓN CRÍTICA: {e}")
        return False

if __name__ == "__main__":
    success = test_remote_flow()
    sys.exit(0 if success else 1)
