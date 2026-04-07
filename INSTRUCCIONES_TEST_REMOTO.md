# Verificacion remota

`verify_remote.py` ahora valida tres cosas:

1. El panel web responde y permite operar.
2. El endpoint `/api/pooling/status` reporta `HAProxy` y `PgBouncer` activos.
3. La conexion SQL publica (`5432`) funciona de verdad con un usuario creado desde el panel.

## Requisitos

- Tener `ADMIN_PASSWORD` disponible en `backend/.env` o variables de entorno.
- Ejecutar el script desde una IP publica conocida.
- Configurar `TEST_SQL_IP` con esa IP publica para que el script pueda habilitar temporalmente el acceso SQL y probar la conexion real.

## Variables utiles

- `BASE_URL`
- `ADMIN_USERNAME`
- `ADMIN_PASSWORD`
- `TEST_SQL_IP`
- `TEST_PORT`
- `REQUIRE_POOLING=true`

## Uso

```bash
python verify_remote.py
```

## Runner unificado de pruebas

En el VPS puedes ejecutar la suite local+load con:

```bash
bash server/run_test_suite.sh
```

Y si quieres incluir validacion remota:

```bash
RUN_REMOTE_TEST=1 bash server/run_test_suite.sh
```

## Resultado esperado

- Login exitoso.
- Config y metrics con formato valido.
- Pooling habilitado y servicios activos.
- Creacion y eliminacion correcta de una base de prueba.
- Conexion SQL real exitosa al endpoint publico detras del pooler.
