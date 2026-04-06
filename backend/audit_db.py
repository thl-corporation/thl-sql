import psycopg2
from psycopg2 import sql
import os
from dotenv import load_dotenv

load_dotenv()

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = "postgres" # Connect to default postgres DB to manage others
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD")

if not DB_PASSWORD:
    print("Error: DB_PASSWORD environment variable is not set.")
    # Exit or raise error, but since this is a script, printing and exiting is fine.
    # However, to keep it importable, maybe just leave it None and fail at connection time?
    # But explicit check is better for a script.
    pass # We'll let connection fail if it's None, or we can set a dummy value to avoid NoneType error in connect


def get_db_connection():
    conn = psycopg2.connect(
        database=DB_NAME,
        user=DB_USER,
        host=DB_HOST,
        port=DB_PORT,
        password=DB_PASSWORD
    )
    conn.autocommit = True
    return conn

def audit_and_clean():
    conn = get_db_connection()
    cur = conn.cursor()
    
    try:
        # 1. Get all managed databases from our metadata table
        # We need to connect to the DB where managed_clients table is. 
        # Assuming it is in 'postgres' DB based on main.py logic (default DB_NAME)
        print("Fetching managed clients...")
        try:
            cur.execute("SELECT db_name, db_user FROM managed_clients")
            managed = cur.fetchall()
            managed_dbs = {row[0] for row in managed}
            managed_users = {row[1] for row in managed}
        except Exception as e:
            print(f"Error fetching managed_clients (maybe table doesn't exist?): {e}")
            managed_dbs = set()
            managed_users = set()

        print(f"Managed DBs: {managed_dbs}")

        # 2. Get all actual databases in PostgreSQL
        # Exclude system databases and the 'postgres' default db
        cur.execute("SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'")
        actual_dbs = [row[0] for row in cur.fetchall()]
        
        print(f"Actual DBs in Postgres: {actual_dbs}")

        # 3. Identify Zombies
        zombie_dbs = [db for db in actual_dbs if db not in managed_dbs]
        
        if zombie_dbs:
            print(f"\n!!! FOUND {len(zombie_dbs)} ZOMBIE DATABASES !!!")
            for db in zombie_dbs:
                print(f" - {db}")
                
            confirm = input("\nDo you want to delete these zombie databases and their users? (yes/no): ")
            if confirm.lower() == 'yes':
                for db in zombie_dbs:
                    print(f"Deleting DB: {db}...")
                    # Terminate connections
                    cur.execute(sql.SQL("""
                        SELECT pg_terminate_backend(pid)
                        FROM pg_stat_activity
                        WHERE datname = {}
                        AND pid <> pg_backend_pid();
                    """).format(sql.Literal(db)))
                    
                    # Drop DB
                    cur.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(sql.Identifier(db)))
                    
                    # Try to drop user associated (convention: user_<client_slug>)
                    # We have to guess the user or check owner, but usually our app creates user_...
                    # Let's check the owner of the DB before dropping it? Too late now if dropped.
                    # Instead, let's look for orphan users.
                    print(f"Dropped {db}")

        else:
            print("\nNo zombie databases found.")

        # 4. Check for orphan users (users starting with 'user_' that are not in managed_users)
        cur.execute("SELECT usename FROM pg_user WHERE usename LIKE 'user_%'")
        actual_users = [row[0] for row in cur.fetchall()]
        
        zombie_users = [u for u in actual_users if u not in managed_users]
        
        if zombie_users:
            print(f"\n!!! FOUND {len(zombie_users)} ORPHAN USERS !!!")
            for u in zombie_users:
                print(f" - {u}")
                
            if confirm.lower() == 'yes': # Use same confirmation
                 for u in zombie_users:
                    print(f"Dropping User: {u}...")
                    cur.execute(sql.SQL("DROP USER IF EXISTS {}").format(sql.Identifier(u)))
                    print(f"Dropped {u}")
        else:
            print("\nNo orphan users found.")

    except Exception as e:
        print(f"Error: {e}")
    finally:
        cur.close()
        conn.close()

if __name__ == "__main__":
    audit_and_clean()
