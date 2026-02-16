# vps-kamatera-SQL-01
Panel web para administrar un servidor PostgreSQL y el firewall del VPS.

## Funcionalidades actuales
- Login de administrador con cookie de sesión y CSRF
- Crear y eliminar bases de datos y usuarios
- Listado de clientes y métricas del servidor (CPU, RAM, conexiones)
- Apertura y cierre de puertos vía UFW
- Acceso SQL por IP (gestión de reglas UFW para 5432)
- UI con gráficas y panel de operaciones

## Requisitos de negocio
- Crear y eliminar bases de datos y usuarios
- Poner bases de datos en reposo o “pausa”
- Abrir y cerrar puertos del servidor
- Controlar acceso SQL por IP
- Panel con gráficas y listados

## Estado respecto a los requisitos
- Crear/eliminar DB y usuarios: Implementado
- Abrir/cerrar puertos: Implementado
- Gráficas y listados: Implementado
- Pausar/Reanudar DB: Implementado
- Acceso SQL por IP: Implementado

## Cómo ejecutar en local
1. Crear un entorno virtual y activar:
   - Windows: `python -m venv venv && venv\Scripts\activate`
2. Instalar dependencias:
   - `pip install -r backend/requirements.txt`
3. Configurar variables en `backend/.env` usando `backend/.env.example`
4. Iniciar la API:
   - `uvicorn main:app --host 127.0.0.1 --port 8000 --log-level info`
5. Abrir en el navegador:
   - `http://127.0.0.1:8000`

## Dominio y HTTPS
El panel está publicado en:
- https://sql.thlcorporation.com

Configuración recomendada:
- ALLOWED_ORIGINS=https://sql.thlcorporation.com
- COOKIE_SECURE=true

## Variables de entorno clave
- DB_HOST, DB_NAME, DB_USER, DB_PASSWORD
- ADMIN_USERNAME, ADMIN_PASSWORD
- ENCRYPTION_KEY
- ALLOWED_ORIGINS
- COOKIE_SECURE
- PUBLIC_DB_HOST, PUBLIC_DB_PORT
- LOGIN_RATE_LIMIT, LOGIN_RATE_WINDOW_SEC
- ALLOWED_PORTS

## Endpoints principales
- GET /login
- POST /login
- POST /logout
- POST /create-client
- GET /clients
- PUT /clients/{client_id}
- DELETE /clients/{client_id}
- POST /clients/{client_id}/pause
- POST /clients/{client_id}/resume
- GET /api/stats
- GET /api/ports
- POST /api/ports/open
- POST /api/ports/close
- GET /api/sql-access
- POST /api/sql-access/allow
- POST /api/sql-access/revoke
- GET /api/config

## Pausar bases de datos (implementado)
Para “pausar” una base sin eliminarla:
- Revocar CONNECT al rol del cliente
- Terminar conexiones activas con pg_terminate_backend
La reactivación invierte esos pasos (GRANT CONNECT, etc.).

## Optimización del Servidor
- **DNS**: Se ha configurado el uso de Google DNS (8.8.8.8) y Cloudflare (1.1.1.1) para mejorar la velocidad de resolución de nombres y la estabilidad de las conexiones salientes.

## Seguridad recomendada
- Usar HTTPS en producción con sql.thlcorporation.com
- Limitar ALLOWED_ORIGINS a https://sql.thlcorporation.com
- Configurar COOKIE_SECURE=true
- Evitar ROOT_PASSWORD en procesos web; usar sudoers con comandos permitidos
- Gestionar el puerto 5432 solo por IP y evitar apertura pública
- Validar y sanitizar entradas que se muestran en la UI
