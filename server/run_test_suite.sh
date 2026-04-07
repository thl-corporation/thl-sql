#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/var/www/pg_manager}"
LOAD_CONNECTIONS="${LOAD_CONNECTIONS:-1000}"
LOAD_HOLD_SECONDS="${LOAD_HOLD_SECONDS:-20}"
LOAD_SAMPLE_SECONDS="${LOAD_SAMPLE_SECONDS:-8}"
RUN_REMOTE_TEST="${RUN_REMOTE_TEST:-0}"

cd "${APP_DIR}"

if [ ! -d "venv" ]; then
    echo "Error: no existe ${APP_DIR}/venv"
    exit 1
fi

# shellcheck disable=SC1091
source venv/bin/activate

echo "[1/3] Smoke local (verify_deployment.py)..."
python verify_deployment.py

echo "[2/3] Prueba de carga SQL..."
python server/run_sql_load_test.py \
    --connections "${LOAD_CONNECTIONS}" \
    --hold-seconds "${LOAD_HOLD_SECONDS}" \
    --sample-seconds "${LOAD_SAMPLE_SECONDS}"

echo "[3/3] Smoke remoto opcional..."
if [ "${RUN_REMOTE_TEST}" = "1" ]; then
    python verify_remote.py
else
    echo "Omitido. Para ejecutarlo: RUN_REMOTE_TEST=1 bash server/run_test_suite.sh"
fi

echo "Suite completada."
