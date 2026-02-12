---
name: "push-pull-vps"
description: "Gestiona push/pull y despliegue al VPS con llaves SSH. Invocar cuando el usuario pida actualizar la nube, el servidor, o hacer push/pull."
---

# Push/Pull y Actualización de VPS

## Alcance

Usa este procedimiento cuando se solicite:
- Push o pull del repositorio
- Actualizar la nube (GitHub)
- Actualizar el servidor (VPS)
- Validar llaves SSH y rutas

## Llaves SSH

- Local → VPS: `./ssh_keys/vps_kamatera_id_ed25519`
- VPS → GitHub: `~/.ssh/id_ed25519_github`

## Remotos

- URL SSH: `git@github.com:thl-corporation-spa/vps-kamatera-SQL-01.git`

## Push/Pull Local

1. Verificar estado:
   - `git status -sb`
2. Asegurar remoto:
   - `git remote set-url origin git@github.com:thl-corporation-spa/vps-kamatera-SQL-01.git`
3. Push usando la llave del proyecto:
   - PowerShell:
     - `$env:GIT_SSH_COMMAND="ssh -i ./ssh_keys/vps_kamatera_id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"; git push origin main`

## Actualización en VPS

1. Actualizar remoto en VPS:
   - `ssh -i ./ssh_keys/vps_kamatera_id_ed25519 root@66.55.75.32 git -C /var/www/pg_manager remote set-url origin git@github.com:thl-corporation-spa/vps-kamatera-SQL-01.git`
2. Pull en VPS:
   - `ssh -i ./ssh_keys/vps_kamatera_id_ed25519 root@66.55.75.32 "cd /var/www/pg_manager && GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_github -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' git pull origin main"`
3. Reiniciar servicio:
   - `ssh -i ./ssh_keys/vps_kamatera_id_ed25519 root@66.55.75.32 systemctl restart pg_manager`

## Verificación

- `ssh -i ./ssh_keys/vps_kamatera_id_ed25519 root@66.55.75.32 systemctl status pg_manager`
