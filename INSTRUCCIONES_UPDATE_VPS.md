# Guía de Actualización Automática del VPS

Este repositorio está configurado para permitir actualizaciones directas al servidor VPS mediante comandos SSH remotos, utilizando llaves SSH almacenadas fuera del repositorio.

## 🚀 Comando de Actualización Rápida

Para desplegar los últimos cambios de la rama `main` al servidor, ejecuta este comando desde tu terminal local (PowerShell o Bash) en la raíz del proyecto:

```bash
ssh -i ~/.ssh/vps_kamatera_id_ed25519 root@66.55.75.32 "cd /var/www/pg_manager && GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_github' git pull origin main && systemctl restart pg_manager"
```

### ¿Qué hace este comando?
1.  Conecta al VPS usando la llave privada local.
2.  Navega a la carpeta del proyecto.
3.  Usa la llave de despliegue configurada en el servidor para hacer `git pull` desde GitHub.
4.  Reinicia el servicio `pg_manager` para aplicar los cambios.

---

## 🛠️ Actualización Manual (Paso a Paso)

Si prefieres entrar al servidor y verificar manualmente:

1.  **Conectar al VPS:**
    ```bash
    ssh -i ~/.ssh/vps_kamatera_id_ed25519 root@66.55.75.32
    ```

2.  **Ejecutar la actualización:**
    ```bash
    cd /var/www/pg_manager
    git pull origin main
    systemctl restart pg_manager
    ```

3.  **Verificar estado:**
    ```bash
    systemctl status pg_manager
    ```

---

## 🔑 Gestión de Llaves
- **Llave Local**: `~/.ssh/vps_kamatera_id_ed25519` (Se usa para conectar TU PC -> VPS)
- **Llave Remota**: `~/.ssh/id_ed25519_github` (Se usa para conectar VPS -> GitHub)

## 🔒 Recomendaciones de seguridad operativa
- Usar HTTPS con certificados válidos en Nginx para sql.thlcorporation.com
- Configurar COOKIE_SECURE=true en el servicio
- Limitar ALLOWED_ORIGINS a https://sql.thlcorporation.com
- Mantener ALLOWED_PORTS sin 5432 y gestionar SQL por IP desde el panel

## ✅ Verificación rápida post-deploy
1. Probar acceso web:
   - https://sql.thlcorporation.com
2. Ejecutar verificación remota:
   ```bash
   python verify_remote.py
   ```
3. Validar acceso SQL por IP:
   - Ingresar al panel y revisar “Acceso SQL por IP”
