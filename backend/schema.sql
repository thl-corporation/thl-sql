CREATE TABLE IF NOT EXISTS managed_clients (
    id SERIAL PRIMARY KEY,
    client_name TEXT NOT NULL,
    db_name TEXT NOT NULL,
    db_user TEXT NOT NULL,
    db_password TEXT NOT NULL,
    is_public BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sql_access_ips (
    id SERIAL PRIMARY KEY,
    ip_cidr TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sql_access_ip_databases (
    id SERIAL PRIMARY KEY,
    ip_id INTEGER NOT NULL REFERENCES sql_access_ips(id) ON DELETE CASCADE,
    db_name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (ip_id, db_name)
);
