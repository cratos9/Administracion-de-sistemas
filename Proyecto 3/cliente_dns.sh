#!/bin/bash

DOMAIN="reprobados.com"
EXPECTED_IP="192.168.100.12"
PASS=0
FAIL=0

read -p "IP del servidor DNS: " DNS_SERVER

if [[ -z "$DNS_SERVER" ]]; then
    echo "Debes ingresar una IP de servidor DNS"
    exit 1
fi

echo "validar DNS de linux server"
echo "servidor DNS: $DNS_SERVER"
echo "dominio: $DOMAIN"
echo "IP esperada: $EXPECTED_IP"

if ! command -v nslookup >/dev/null 2>&1; then
    echo "Instalando paquetes"
    sudo apt-get install -y -q dnsutils > /dev/null 2>&1
fi

echo "nameserver $DNS_SERVER" | sudo tee /etc/resolv.conf > /dev/null

check() {
    local prueba="$1"
    local resultado="$2"
    if [ "$resultado" = "$EXPECTED_IP" ]; then
        echo "[ok]    $prueba -> $esperado"
        PASS=$((PASS + 1))
    else
        echo "[fail]  $prueba -> esperado: $EXPECTED_IP, obtenido: $resultado"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "--- nslookup reprobados.com ---"
nslookup "$DOMAIN" "$DNS_SERVER"