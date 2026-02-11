# Script de Verificación Remota

Este script intenta conectar al servidor remoto para verificar que la creación y eliminación de bases de datos funciona correctamente.

## Uso
1. Asegúrate de tener las credenciales correctas del panel (usuario y contraseña de la web).
2. Edita `BASE_URL`, `USERNAME` y `PASSWORD` en el script si son diferentes a los valores por defecto.
3. Para el VPS usar `https://sql.thlcorporation.com` como BASE_URL (valor por defecto en el script).
4. Ejecuta:
   ```bash
   python verify_remote.py
   ```
5. Validar manualmente el acceso SQL por IP en el panel si es necesario.
