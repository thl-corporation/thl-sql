# Instrucciones para actualizar el VPS

Dado que no tengo acceso SSH directo configurado desde este entorno local para ejecutar comandos en tu VPS automáticamente, he subido los cambios al repositorio.

Por favor, conecta a tu VPS mediante SSH y ejecuta los siguientes comandos para actualizar la aplicación:

```bash
# 1. Conectar al VPS (usa tu comando habitual)
# ssh root@<TU_IP_VPS>

# 2. Ir al directorio del proyecto
cd /var/www/pg_manager

# 3. Traer los últimos cambios (Pull)
git pull origin main

# 4. Reiniciar el servicio para aplicar los cambios
systemctl restart pg_manager

# (Opcional) Si quieres ejecutar el script de auditoría en el VPS:
# cd backend
# source ../venv/bin/activate
# python audit_db.py
```

Estos cambios incluyen:
1.  **Fix de borrado**: Ahora se fuerzan el cierre de conexiones antes de borrar una base de datos.
2.  **Script de auditoría**: `backend/audit_db.py` para detectar y limpiar bases de datos "zombies".
