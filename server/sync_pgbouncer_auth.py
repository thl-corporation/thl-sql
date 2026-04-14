import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import psycopg2
from cryptography.fernet import Fernet
from dotenv import load_dotenv


def parse_args():
    parser = argparse.ArgumentParser(
        description="Regenera el auth_file de PgBouncer usando las credenciales administradas por la app."
    )
    parser.add_argument(
        "--env-file",
        default=os.path.join("/var", "www", "pg_manager", "backend", ".env"),
        help="Ruta al archivo .env del backend.",
    )
    parser.add_argument(
        "--auth-file",
        default=os.getenv("PGBOUNCER_AUTH_FILE", "/etc/pgbouncer/userlist.txt"),
        help="Ruta del auth_file de PgBouncer.",
    )
    parser.add_argument(
        "--no-reload",
        action="store_true",
        help="No recargar el servicio pgbouncer despues de escribir el archivo.",
    )
    return parser.parse_args()


def quote_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def write_atomic(path: str, content: str) -> None:
    directory = os.path.dirname(path) or "."
    with tempfile.NamedTemporaryFile("w", delete=False, dir=directory, encoding="utf-8") as tmp:
        tmp.write(content)
        tmp_name = tmp.name
    os.replace(tmp_name, path)


def load_environment(env_file: str) -> None:
    if env_file and os.path.exists(env_file):
        load_dotenv(env_file, override=True)
    else:
        load_dotenv(override=True)


def fetch_managed_passwords(conn, encryption_key: str) -> dict[str, str]:
    passwords: dict[str, str] = {}
    cur = conn.cursor()
    try:
        cur.execute("SELECT to_regclass('public.managed_clients')")
        if not cur.fetchone()[0]:
            return passwords

        fernet = Fernet(encryption_key.encode())
        cur.execute("SELECT db_user, db_password FROM managed_clients ORDER BY db_user")
        for db_user, encrypted_password in cur.fetchall():
            if not db_user or not encrypted_password:
                continue
            try:
                passwords[db_user] = fernet.decrypt(encrypted_password.encode()).decode()
            except Exception as exc:
                print(f"Warning: no se pudo desencriptar la clave de {db_user}: {exc}", file=sys.stderr)
    finally:
        cur.close()
    return passwords


def build_auth_content(passwords: dict[str, str]) -> str:
    lines = []
    for username in sorted(passwords):
        password = passwords[username]
        lines.append(f'"{quote_value(username)}" "{quote_value(password)}"')
    return "\n".join(lines) + ("\n" if lines else "")


def is_systemd_available() -> bool:
    return os.path.isdir("/run/systemd/system") and shutil.which("systemctl") is not None


def detect_service_manager() -> str:
    configured = os.getenv("SERVICE_MANAGER", "").strip().lower()
    if configured in {"systemd", "service"}:
        return configured
    if is_systemd_available():
        return "systemd"
    if shutil.which("service"):
        return "service"
    return "unknown"


def reload_pgbouncer() -> None:
    service_manager = detect_service_manager()
    if service_manager == "systemd":
        result = subprocess.run(["systemctl", "reload", "pgbouncer"], capture_output=True, text=True)
        if result.returncode == 0:
            return
        restart_result = subprocess.run(["systemctl", "restart", "pgbouncer"], capture_output=True, text=True)
        if restart_result.returncode != 0:
            raise RuntimeError(restart_result.stderr.strip() or "No se pudo reiniciar pgbouncer")
        return

    if service_manager == "service":
        result = subprocess.run(["service", "pgbouncer", "reload"], capture_output=True, text=True)
        if result.returncode == 0:
            return
        restart_result = subprocess.run(["service", "pgbouncer", "restart"], capture_output=True, text=True)
        if restart_result.returncode != 0:
            raise RuntimeError(restart_result.stderr.strip() or "No se pudo reiniciar pgbouncer")
        return

    raise RuntimeError("No se detecto un gestor de servicios compatible para recargar PgBouncer")


def main() -> int:
    args = parse_args()
    load_environment(args.env_file)

    db_host = os.getenv("DB_HOST", "localhost")
    db_port = int(os.getenv("DB_PORT", "5433"))
    db_name = os.getenv("DB_NAME", "postgres")
    db_user = os.getenv("DB_USER", "postgres")
    db_password = os.getenv("DB_PASSWORD")
    encryption_key = os.getenv("ENCRYPTION_KEY")

    if not db_password:
        print("DB_PASSWORD is required to build PgBouncer auth.", file=sys.stderr)
        return 1
    if not encryption_key:
        print("ENCRYPTION_KEY is required to build PgBouncer auth.", file=sys.stderr)
        return 1

    conn = psycopg2.connect(
        host=db_host,
        port=db_port,
        database=db_name,
        user=db_user,
        password=db_password,
    )
    conn.autocommit = True

    try:
        passwords = {db_user: db_password}
        passwords.update(fetch_managed_passwords(conn, encryption_key))
    finally:
        conn.close()

    content = build_auth_content(passwords)
    write_atomic(args.auth_file, content)
    os.chmod(args.auth_file, 0o640)

    try:
        import pwd
        import grp

        for owner in ("postgres", "pgbouncer"):
            try:
                uid = pwd.getpwnam(owner).pw_uid
                gid = grp.getgrnam(owner).gr_gid
                os.chown(args.auth_file, uid, gid)
                break
            except KeyError:
                continue
    except Exception:
        pass

    if not args.no_reload:
        reload_pgbouncer()

    print(f"PgBouncer auth file actualizado: {args.auth_file} ({len(passwords)} usuarios)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
