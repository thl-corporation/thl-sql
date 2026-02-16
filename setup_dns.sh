#!/bin/bash
set -e

# Colores para output
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Configurando DNS a Google (8.8.8.8)...${NC}"

# Verificar si systemd-resolved está en uso (Estándar en Ubuntu 18.04+)
if systemctl is-active --quiet systemd-resolved; then
    echo "Detectado systemd-resolved."
    
    # Backup
    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak.$(date +%F_%T)
    
    # Configurar DNS principal
    if grep -q "^DNS=" /etc/systemd/resolved.conf; then
        sed -i 's/^DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
    elif grep -q "^#DNS=" /etc/systemd/resolved.conf; then
        sed -i 's/^#DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
    else
        echo "DNS=8.8.8.8 8.8.4.4" >> /etc/systemd/resolved.conf
    fi
    
    # Configurar Fallback DNS (Cloudflare como respaldo)
    if grep -q "^FallbackDNS=" /etc/systemd/resolved.conf; then
        sed -i 's/^FallbackDNS=.*/FallbackDNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
    elif grep -q "^#FallbackDNS=" /etc/systemd/resolved.conf; then
        sed -i 's/^#FallbackDNS=.*/FallbackDNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
    else
        echo "FallbackDNS=1.1.1.1 1.0.0.1" >> /etc/systemd/resolved.conf
    fi

    systemctl restart systemd-resolved
    echo -e "${GREEN}systemd-resolved reiniciado exitosamente.${NC}"
    
    echo "Verificando configuración..."
    resolvectl status | grep "DNS Servers" -A 2 || true
else
    echo "No se detectó systemd-resolved. Modificando /etc/resolv.conf directamente..."
    
    # Backup
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%F_%T)
    
    # Sobrescribir resolv.conf
    # Nota: Esto podría ser sobrescrito por DHCP client si no se configura permanentemente en /etc/network/interfaces o netplan
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf
    
    echo -e "${GREEN}/etc/resolv.conf actualizado.${NC}"
fi

echo -e "${GREEN}Prueba de conectividad y resolución...${NC}"
ping -c 3 google.com
