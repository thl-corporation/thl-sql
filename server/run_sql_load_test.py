import argparse
import json
import math
import multiprocessing as mp
import os
import queue
import time
from collections import Counter

import psycopg2
from dotenv import load_dotenv


def parse_args():
    parser = argparse.ArgumentParser(
        description="Prueba de concurrencia para validar miles de conexiones cliente a traves de HAProxy + PgBouncer."
    )
    parser.add_argument("--env-file", default=os.path.join("/var", "www", "pg_manager", "backend", ".env"))
    parser.add_argument("--connections", type=int, default=1000)
    parser.add_argument("--hold-seconds", type=int, default=20)
    parser.add_argument("--connect-timeout", type=int, default=10)
    parser.add_argument("--sample-seconds", type=int, default=5)
    parser.add_argument("--batch-size", type=int, default=200)
    parser.add_argument("--max-total-seconds", type=int, default=60)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int)
    parser.add_argument("--database", default=None)
    parser.add_argument("--user", default=None)
    parser.add_argument("--password", default=None)
    return parser.parse_args()


def load_environment(env_file: str) -> None:
    if env_file and os.path.exists(env_file):
        load_dotenv(env_file, override=True)
    else:
        load_dotenv(override=True)


def get_pool_snapshot(admin_host: str, admin_port: int, db_user: str, db_password: str) -> dict:
    summary = {
        "cl_active": 0,
        "cl_waiting": 0,
        "sv_active": 0,
        "sv_idle": 0,
    }
    conn = psycopg2.connect(
        host=admin_host,
        port=admin_port,
        database="pgbouncer",
        user=db_user,
        password=db_password,
        connect_timeout=5,
    )
    conn.autocommit = True
    try:
        cur = conn.cursor()
        cur.execute("SHOW POOLS")
        columns = [desc[0] for desc in cur.description]
        for row in cur.fetchall():
            pool = dict(zip(columns, row))
            summary["cl_active"] += int(pool.get("cl_active", 0))
            summary["cl_waiting"] += int(pool.get("cl_waiting", 0))
            summary["sv_active"] += int(pool.get("sv_active", 0))
            summary["sv_idle"] += int(pool.get("sv_idle", 0))
        cur.close()
    finally:
        conn.close()
    return summary


def get_postgres_snapshot(db_host: str, db_port: int, db_name: str, db_user: str, db_password: str) -> dict:
    conn = psycopg2.connect(
        host=db_host,
        port=db_port,
        database=db_name,
        user=db_user,
        password=db_password,
        connect_timeout=5,
    )
    conn.autocommit = True
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT state, count(*)
            FROM pg_stat_activity
            WHERE backend_type = 'client backend'
            GROUP BY state
            """
        )
        state_counts = {state or "unknown": count for state, count in cur.fetchall()}
        cur.execute(
            """
            SELECT count(*)
            FROM pg_stat_activity
            WHERE backend_type = 'client backend'
            """
        )
        total = cur.fetchone()[0]
        cur.close()
    finally:
        conn.close()
    return {"total_client_backends": total, "states": state_counts}


def chunk_counts(total: int, batch_size: int) -> list[int]:
    if total <= 0:
        return []
    batches = int(math.ceil(total / max(batch_size, 1)))
    counts = [total // batches] * batches
    for index in range(total % batches):
        counts[index] += 1
    return counts


def open_connections_worker(worker_id: int, target_count: int, config: dict, release_event, report_queue) -> None:
    connections = []
    local_errors = []

    for offset in range(target_count):
        started = time.time()
        try:
            conn = psycopg2.connect(
                host=config["host"],
                port=config["port"],
                database=config["database"],
                user=config["user"],
                password=config["password"],
                connect_timeout=config["connect_timeout"],
                application_name=f"load_test_{worker_id}_{offset}",
            )
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
            connections.append(conn)
            report_queue.put(("connected", time.time() - started))
        except Exception as exc:
            local_errors.append(str(exc))
            report_queue.put(("failed", str(exc)))

    report_queue.put(("worker_ready", {"worker_id": worker_id, "requested": target_count}))
    release_event.wait()

    closed = 0
    for conn in connections:
        try:
            conn.close()
            closed += 1
        except Exception:
            pass

    report_queue.put(("worker_done", {"worker_id": worker_id, "closed": closed, "errors": local_errors[:5]}))


def collect_until_workers_ready(report_queue, expected_workers: int, expected_connections: int, timeout_seconds: float):
    counters = Counter()
    timings = []
    errors = []
    ready_workers = set()
    deadline = time.time() + timeout_seconds

    while time.time() < deadline:
        if len(ready_workers) >= expected_workers:
            break
        try:
            event_type, payload = report_queue.get(timeout=0.2)
        except queue.Empty:
            if counters["connected"] + counters["failed"] >= expected_connections:
                continue
            continue

        if event_type == "connected":
            counters["connected"] += 1
            timings.append(float(payload))
        elif event_type == "failed":
            counters["failed"] += 1
            if len(errors) < 10:
                errors.append(str(payload))
        elif event_type == "worker_ready":
            ready_workers.add(int(payload["worker_id"]))
        elif event_type == "worker_done":
            counters["closed"] += int(payload.get("closed", 0))
            for item in payload.get("errors", []):
                if len(errors) < 10:
                    errors.append(str(item))

    return counters, timings, errors, ready_workers


def drain_worker_done(report_queue, expected_workers: int, counters: Counter, errors: list[str], timeout_seconds: float):
    done_workers = set()
    deadline = time.time() + timeout_seconds
    while time.time() < deadline and len(done_workers) < expected_workers:
        try:
            event_type, payload = report_queue.get(timeout=0.2)
        except queue.Empty:
            continue
        if event_type == "connected":
            counters["connected"] += 1
        elif event_type == "failed":
            counters["failed"] += 1
            if len(errors) < 10:
                errors.append(str(payload))
        elif event_type == "worker_done":
            done_workers.add(int(payload["worker_id"]))
            counters["closed"] += int(payload.get("closed", 0))
            for item in payload.get("errors", []):
                if len(errors) < 10:
                    errors.append(str(item))

    return done_workers


def main() -> int:
    args = parse_args()
    load_environment(args.env_file)

    db_host = os.getenv("DB_HOST", "127.0.0.1")
    db_port = int(os.getenv("DB_PORT", "5433"))
    db_name = args.database or os.getenv("DB_NAME", "postgres")
    db_user = args.user or os.getenv("DB_USER", "postgres")
    db_password = args.password or os.getenv("DB_PASSWORD")
    public_port = args.port or int(os.getenv("PUBLIC_DB_PORT", "5432"))
    pgbouncer_port = int(os.getenv("PGBOUNCER_PORT", "6432"))

    if not db_password:
        raise SystemExit("DB_PASSWORD is required")

    process_counts = chunk_counts(args.connections, args.batch_size)
    release_event = mp.Event()
    report_queue = mp.Queue()

    config = {
        "host": args.host,
        "port": public_port,
        "database": db_name,
        "user": db_user,
        "password": db_password,
        "connect_timeout": args.connect_timeout,
    }

    started_at = time.time()
    workers = []
    for worker_id, count in enumerate(process_counts):
        proc = mp.Process(
            target=open_connections_worker,
            args=(worker_id, count, config, release_event, report_queue),
            daemon=True,
        )
        proc.start()
        workers.append(proc)

    counters, timings, errors, ready_workers = collect_until_workers_ready(
        report_queue=report_queue,
        expected_workers=len(workers),
        expected_connections=args.connections,
        timeout_seconds=max(5, min(args.max_total_seconds, max(args.hold_seconds, args.connect_timeout) + 120)),
    )

    peak_pool = {"cl_active": 0, "cl_waiting": 0, "sv_active": 0, "sv_idle": 0}
    peak_postgres = {"total_client_backends": 0, "states": {}}
    samples = []
    observe_seconds = max(args.sample_seconds, args.hold_seconds, 1)
    for _ in range(observe_seconds):
        try:
            pool_snapshot = get_pool_snapshot("127.0.0.1", pgbouncer_port, db_user, db_password)
        except Exception as exc:
            pool_snapshot = {"error": str(exc)}
        try:
            postgres_snapshot = get_postgres_snapshot(db_host, db_port, db_name, db_user, db_password)
        except Exception as exc:
            postgres_snapshot = {"error": str(exc)}

        samples.append({"pool": pool_snapshot, "postgres": postgres_snapshot})

        if "error" not in pool_snapshot:
            for key in peak_pool:
                peak_pool[key] = max(peak_pool[key], int(pool_snapshot.get(key, 0)))
        if "error" not in postgres_snapshot:
            peak_postgres["total_client_backends"] = max(
                peak_postgres["total_client_backends"],
                int(postgres_snapshot.get("total_client_backends", 0)),
            )
            if peak_postgres["states"] == {}:
                peak_postgres["states"] = postgres_snapshot.get("states", {})
        time.sleep(1)

    release_event.set()
    for worker in workers:
        worker.join(timeout=30)

    done_workers = drain_worker_done(
        report_queue=report_queue,
        expected_workers=len(workers),
        counters=counters,
        errors=errors,
        timeout_seconds=30,
    )

    completed_at = time.time()
    result = {
        "requested_connections": args.connections,
        "connected": counters["connected"],
        "failed": counters["failed"],
        "closed": counters["closed"],
        "duration_seconds": round(completed_at - started_at, 2),
        "avg_connect_seconds": round(sum(timings) / len(timings), 4) if timings else None,
        "max_connect_seconds": round(max(timings), 4) if timings else None,
        "workers": len(workers),
        "batch_size": args.batch_size,
        "ready_workers": len(ready_workers),
        "finished_workers": len(done_workers),
        "peak_pool": peak_pool,
        "peak_postgres": peak_postgres,
        "sample_count": len(samples),
        "errors": errors[:10],
    }

    print(json.dumps(result, indent=2))
    return 0 if counters["connected"] == args.connections and counters["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
