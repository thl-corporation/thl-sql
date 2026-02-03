import psycopg2
from psycopg2 import sql
import os
import sys

# Hardcoded credentials matching the VPS environment
DB_HOST = "localhost"
DB_NAME = "postgres"
DB_USER = "postgres"
DB_PASSWORD = "Sup3rS3cur3P0stgr3s!"

def get_db_connection():
    conn = psycopg2.connect(
        host=DB_HOST,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )
    conn.autocommit = True
    return conn

def cleanup():
    print("Starting cleanup process...")
    try:
        conn = get_db_connection()
        cur = conn.cursor()
    except Exception as e:
        print(f"Failed to connect to database: {e}")
        return

    try:
        # 1. Fetch managed clients to clean up users and known DBs
        print("Fetching managed clients...")
        try:
            cur.execute("SELECT db_name, db_user FROM managed_clients")
            clients = cur.fetchall()
        except Exception as e:
            print(f"Error fetching managed_clients (table might not exist): {e}")
            clients = []

        # 2. Drop specific client databases and users
        for db_name, db_user in clients:
            print(f"Processing client: DB={db_name}, User={db_user}")
            
            # Terminate connections
            try:
                cur.execute(sql.SQL("""
                    SELECT pg_terminate_backend(pg_stat_activity.pid)
                    FROM pg_stat_activity
                    WHERE pg_stat_activity.datname = {}
                    AND pid <> pg_backend_pid();
                """).format(sql.Literal(db_name)))
            except Exception as e:
                print(f"Error terminating connections for {db_name}: {e}")

            # Drop Database
            try:
                cur.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(sql.Identifier(db_name)))
                print(f"Dropped database {db_name}")
            except Exception as e:
                print(f"Error dropping database {db_name}: {e}")

            # Drop User
            try:
                cur.execute(sql.SQL("DROP USER IF EXISTS {}").format(sql.Identifier(db_user)))
                print(f"Dropped user {db_user}")
            except Exception as e:
                print(f"Error dropping user {db_user}: {e}")

        # 3. Scan for ANY other non-system databases
        print("Scanning for stray databases...")
        cur.execute("SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres' AND datname != 'rdsadmin'")
        stray_dbs = [row[0] for row in cur.fetchall()]
        
        for db in stray_dbs:
            print(f"Found stray database: {db}")
            # Terminate connections
            cur.execute(sql.SQL("""
                SELECT pg_terminate_backend(pg_stat_activity.pid)
                FROM pg_stat_activity
                WHERE pg_stat_activity.datname = {}
                AND pid <> pg_backend_pid();
            """).format(sql.Literal(db)))
            
            # Drop database
            cur.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(sql.Identifier(db)))
            print(f"Dropped stray database {db}")

        # 4. Truncate managed_clients
        print("Truncating metadata table...")
        cur.execute("TRUNCATE TABLE managed_clients")
        print("Metadata cleared.")

        print("Cleanup completed successfully.")

    except Exception as e:
        print(f"Critical Error during cleanup: {e}")
    finally:
        if cur: cur.close()
        if conn: conn.close()

if __name__ == "__main__":
    cleanup()
