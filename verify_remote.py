import ipaddress
import os
import sys
import time

import psycopg2
import requests
from dotenv import load_dotenv


load_dotenv(os.path.join(os.path.dirname(__file__), "backend", ".env"))

BASE_URL = os.getenv("BASE_URL", "https://sql.thlcorporation.com")
USERNAME = os.getenv("ADMIN_USERNAME", "admin")
PASSWORD = os.getenv("ADMIN_PASSWORD")
TEST_PORT_ENV = os.getenv("TEST_PORT", "443").strip()
TEST_SQL_IP = os.getenv("TEST_SQL_IP", "144.91.101.204/32").strip()
REQUIRE_POOLING = os.getenv("REQUIRE_POOLING", "true").lower() in ("1", "true", "yes")

if not PASSWORD:
    print("Error: ADMIN_PASSWORD not found in environment or .env file.")
    sys.exit(1)


def normalize_ip(value: str):
    net = ipaddress.ip_network(value.strip(), strict=False)
    return str(net)


def connect_sql(connection_info: dict):
    conn = psycopg2.connect(
        host=connection_info["host"],
        port=connection_info["port"],
        database=connection_info["database"],
        user=connection_info["user"],
        password=connection_info["password"],
        connect_timeout=10,
        application_name="verify_remote_sql",
    )
    conn.autocommit = True
    try:
        cur = conn.cursor()
        cur.execute("SELECT current_database(), current_user, 1")
        row = cur.fetchone()
        return {"database": row[0], "user": row[1], "ok": row[2] == 1}
    finally:
        conn.close()


def test_remote_flow():
    session = requests.Session()
    ok = True
    target_client_id = None
    test_db = "test_verify_remote_db"

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
            fail(f"{method} {path} fallo. Status: {resp.status_code}, Body: {resp.text}")
            return None
        try:
            return resp.json()
        except Exception:
            fail(f"{method} {path} devolvio JSON invalido")
            return None

    def fetch_clients():
        resp = session.get(f"{BASE_URL}/clients")
        if resp.status_code != 200:
            fail(f"No se pudo obtener la lista de clientes. Status: {resp.status_code}")
            return []
        data = resp.json()
        if not isinstance(data, list):
            fail("La lista de clientes no tiene el formato esperado")
            return []
        return data

    def find_ip_entry(sql_payload, ip_value):
        entries = sql_payload.get("entries", []) if isinstance(sql_payload, dict) else []
        for entry in entries:
            try:
                if normalize_ip(entry.get("ip", "")) == ip_value:
                    return entry
            except Exception:
                continue
        return None

    def restore_ip_mapping(ip_value, original_databases):
        if original_databases:
            resp = session.post(
                f"{BASE_URL}/api/sql-access/allow",
                json={"ip": ip_value, "databases": original_databases},
                headers=get_csrf_headers(),
            )
            if resp.status_code != 200:
                fail(f"No se pudo restaurar la IP {ip_value}. Status: {resp.status_code}, Body: {resp.text}")
        else:
            resp = session.post(
                f"{BASE_URL}/api/sql-access/revoke",
                json={"ip": ip_value},
                headers=get_csrf_headers(),
            )
            if resp.status_code != 200:
                fail(f"No se pudo revocar la IP {ip_value}. Status: {resp.status_code}, Body: {resp.text}")

    try:
        print(f"1. Conectando a {BASE_URL}...")
        login_payload = {"username": USERNAME, "password": PASSWORD}
        resp = session.post(f"{BASE_URL}/login", json=login_payload)
        if resp.status_code != 200:
            fail(f"Fallo el login. Status: {resp.status_code}, Body: {resp.text}")
            return False
        print("   Login exitoso.")

        print("2. Validando endpoints principales...")
        stats = request_json("GET", "/api/stats")
        if stats is not None and ("cpu" not in stats or "memory" not in stats or "connections" not in stats):
            fail("La tarjeta de metricas no tiene el formato esperado")

        ports_data = request_json("GET", "/api/ports")
        if ports_data is not None and not isinstance(ports_data.get("ports"), list):
            fail("La lista de puertos no tiene el formato esperado")

        sql_data = request_json("GET", "/api/sql-access")
        if sql_data is not None and not isinstance(sql_data.get("allowed"), list):
            fail("La lista de IPs permitidas no tiene el formato esperado")

        config = request_json("GET", "/api/config")
        if config is not None:
            if "public_db_host" not in config or "public_db_port" not in config:
                fail("La tarjeta de configuracion no tiene el formato esperado")
            else:
                print(f"   Conexion SQL publica configurada en {config['public_db_host']}:{config['public_db_port']}")

        pooling = request_json("GET", "/api/pooling/status")
        if pooling is not None:
            print(
                "   Pooling:",
                f"enabled={pooling.get('enabled')}",
                f"mode={pooling.get('mode')}",
                f"services={pooling.get('services')}",
            )
            if REQUIRE_POOLING and not pooling.get("enabled"):
                fail("El pooler deberia estar habilitado y no lo esta")
            services = pooling.get("services", {})
            if REQUIRE_POOLING and (services.get("haproxy") != "active" or services.get("pgbouncer") != "active"):
                fail("HAProxy/PgBouncer no estan activos segun /api/pooling/status")

        clients = fetch_clients()
        print(f"   Clientes actuales: {len(clients)}")

        existing = next((c for c in clients if c.get("db_name") == test_db), None)
        if existing:
            print(f"   Limpiando base de prueba existente: {test_db}")
            resp = session.delete(f"{BASE_URL}/clients/{existing['id']}", headers=get_csrf_headers())
            if resp.status_code != 200:
                fail(f"No se pudo limpiar la base existente. Status: {resp.status_code}, Body: {resp.text}")
                return False
            time.sleep(2)

        print(f"3. Creando base de datos de prueba: {test_db}...")
        create_payload = {"client_name": "Test Client Remote", "db_name": test_db}
        resp = session.post(f"{BASE_URL}/create-client", json=create_payload, headers=get_csrf_headers())
        if resp.status_code != 200:
            fail(f"Fallo la creacion. Status: {resp.status_code}, Body: {resp.text}")
            return False
        create_result = resp.json()

        clients = fetch_clients()
        target_client = next((c for c in clients if c.get("db_name") == test_db), None)
        if not target_client:
            fail("La base creada no aparece en la lista.")
            return False
        target_client_id = target_client["id"]
        print(f"   Creada y verificada con ID={target_client_id}")

        print("4. Probando apertura y cierre de puertos HTTP auxiliares...")
        if TEST_PORT_ENV:
            try:
                test_port = int(TEST_PORT_ENV)
            except Exception:
                fail("TEST_PORT invalido")
                test_port = None

            if test_port in (22, 80, 443, 5432):
                print(f"   Puerto {test_port} protegido. Se omite abrir/cerrar.")
            elif test_port:
                def port_is_open(payload, port):
                    for item in payload.get("ports", []):
                        try:
                            if int(item.get("port")) == int(port):
                                return True
                        except Exception:
                            continue
                    return False

                before = request_json("GET", "/api/ports") or {"ports": []}
                was_open = port_is_open(before, test_port)

                if not was_open:
                    resp = session.post(
                        f"{BASE_URL}/api/ports/open",
                        json={"port": test_port, "protocol": "tcp"},
                        headers=get_csrf_headers(),
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo abrir el puerto {test_port}. Status: {resp.status_code}, Body: {resp.text}")

                resp = session.post(
                    f"{BASE_URL}/api/ports/close",
                    json={"port": test_port, "protocol": "tcp"},
                    headers=get_csrf_headers(),
                )
                if resp.status_code != 200:
                    fail(f"No se pudo cerrar el puerto {test_port}. Status: {resp.status_code}, Body: {resp.text}")

                if was_open:
                    resp = session.post(
                        f"{BASE_URL}/api/ports/open",
                        json={"port": test_port, "protocol": "tcp"},
                        headers=get_csrf_headers(),
                    )
                    if resp.status_code != 200:
                        fail(f"No se pudo restaurar el puerto {test_port}. Status: {resp.status_code}, Body: {resp.text}")
        else:
            print("   TEST_PORT no configurado. Se omite la prueba de puertos.")

        print("5. Probando acceso SQL por IP y conexion real al pool...")
        if TEST_SQL_IP:
            try:
                test_ip_norm = normalize_ip(TEST_SQL_IP)
            except Exception:
                fail("TEST_SQL_IP invalido")
                test_ip_norm = None

            if test_ip_norm:
                sql_before = request_json("GET", "/api/sql-access") or {}
                original_entry = find_ip_entry(sql_before, test_ip_norm)
                original_databases = list(original_entry.get("databases", [])) if original_entry else []
                desired_databases = sorted(set(original_databases + [test_db]))

                resp = session.post(
                    f"{BASE_URL}/api/sql-access/allow",
                    json={"ip": test_ip_norm, "databases": desired_databases},
                    headers=get_csrf_headers(),
                )
                if resp.status_code != 200:
                    fail(f"No se pudo permitir la IP {test_ip_norm}. Status: {resp.status_code}, Body: {resp.text}")
                else:
                    try:
                        sql_result = connect_sql(create_result["connection_info"])
                        if not sql_result.get("ok"):
                            fail("La conexion SQL al pool no devolvio el resultado esperado")
                        else:
                            print(
                                "   Conexion SQL OK:",
                                f"db={sql_result['database']}",
                                f"user={sql_result['user']}",
                            )
                    except Exception as exc:
                        fail(f"No se pudo conectar via SQL al endpoint publico: {exc}")
                    finally:
                        restore_ip_mapping(test_ip_norm, original_databases)
        else:
            print("   TEST_SQL_IP no configurado. Se omite la prueba de SQL real.")

        print(f"6. Eliminando base de datos de prueba: {test_db}...")
        if target_client_id is not None:
            resp = session.delete(f"{BASE_URL}/clients/{target_client_id}", headers=get_csrf_headers())
            if resp.status_code != 200:
                fail(f"Fallo la eliminacion. Status: {resp.status_code}, Body: {resp.text}")
            else:
                clients = fetch_clients()
                if any(c.get("db_name") == test_db for c in clients):
                    fail("La base sigue apareciendo en la lista despues de borrar.")

        if ok:
            print("\nPRUEBAS COMPLETADAS: API, proxy SQL y operaciones administrativas respondieron correctamente.")
        return ok

    except Exception as e:
        print(f"EXCEPCION CRITICA: {e}")
        return False
    finally:
        if target_client_id is not None:
            try:
                session.delete(f"{BASE_URL}/clients/{target_client_id}", headers=get_csrf_headers())
            except Exception:
                pass


if __name__ == "__main__":
    success = test_remote_flow()
    sys.exit(0 if success else 1)
