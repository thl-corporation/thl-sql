# Prueba de 1000 conexiones

Esta prueba valida que el VPS soporte 1000 clientes SQL conectados al mismo tiempo usando:

`HAProxy:5432 -> PgBouncer:6432 -> PostgreSQL:5433`

## Objetivo

- Confirmar que `HAProxy` acepta 1000 sockets cliente.
- Confirmar que `PgBouncer` mantiene 1000 clientes con un numero acotado de conexiones servidor.
- Confirmar que PostgreSQL no necesita 1000 backends para sostener la carga.

## Script

El repo trae el script:

- `server/run_sql_load_test.py`

## Ejecucion

En el VPS:

```bash
cd /var/www/pg_manager
source venv/bin/activate
python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8
```

## Parametros recomendados

- `--connections 1000`: numero de clientes a abrir.
- `--hold-seconds 20`: cuanto tiempo mantener abiertas las conexiones.
- `--sample-seconds 8`: cuantas muestras tomar del pool y de PostgreSQL.

## Salida

El script imprime JSON. Campos mas importantes:

- `requested_connections`
- `connected`
- `failed`
- `avg_connect_seconds`
- `max_connect_seconds`
- `peak_pool.cl_active`
- `peak_pool.cl_waiting`
- `peak_pool.sv_active`
- `peak_pool.sv_idle`
- `peak_postgres.total_client_backends`

## Lectura esperada

- `connected` debe quedar en `1000`.
- `failed` debe quedar en `0`.
- `peak_postgres.total_client_backends` debe ser sensiblemente menor a `1000`.
- `peak_pool.sv_active + peak_pool.sv_idle` refleja cuantas conexiones reales llegaron a PostgreSQL.

## Ajustes disponibles

Si el VPS necesita mas margen:

- subir `PGBOUNCER_MAX_CLIENT_CONN`
- ajustar `PGBOUNCER_DEFAULT_POOL_SIZE`
- ajustar `PGBOUNCER_RESERVE_POOL_SIZE`
- revisar `HAPROXY_MAXCONN`
- revisar `POSTGRES_MAX_CONNECTIONS` en `server/configure_postgres_timeouts.sh`

## Flujo recomendado de validacion

1. Ejecutar `python verify_deployment.py`
2. Ejecutar `python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8`
3. Si la prueba es externa, ejecutar `python verify_remote.py`

## Resultado validado en este VPS

Fecha de ejecucion: `2026-04-06`

Comando ejecutado:

```bash
python server/run_sql_load_test.py --connections 1000 --hold-seconds 20 --sample-seconds 8
```

Resultado observado:

```json
{
  "requested_connections": 1000,
  "connected": 1000,
  "failed": 0,
  "closed": 1000,
  "duration_seconds": 25.15,
  "avg_connect_seconds": 0.396,
  "max_connect_seconds": 0.6226,
  "peak_pool": {
    "cl_active": 1001,
    "cl_waiting": 0,
    "sv_active": 0,
    "sv_idle": 15
  },
  "peak_postgres": {
    "total_client_backends": 16
  }
}
```

Lectura:

- El proxy acepto 1000 clientes concurrentes sin fallas.
- PostgreSQL sostuvo la prueba con solo 16 backends cliente en el pico observado.
- La capa de pooling esta absorbiendo correctamente la concurrencia de clientes.

## Resultado rapido adicional (1500 conexiones)

Fecha de ejecucion: `2026-04-06`

Comando ejecutado:

```bash
python server/run_sql_load_test.py --connections 1500 --hold-seconds 5 --sample-seconds 1 --batch-size 150 --connect-timeout 2 --max-total-seconds 55
```

Resultado observado:

```json
{
  "requested_connections": 1500,
  "connected": 1043,
  "failed": 457,
  "closed": 1043
}
```

Lectura:

- La prueba de 1500 en modo rapido mostro degradacion por timeout de apertura.
- El cuello observado fue de aceptacion/handshake bajo rafaga en VPS chico, no de backends de PostgreSQL.
