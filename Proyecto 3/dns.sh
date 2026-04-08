#!/bin/bash

set -e

DOMAIN="reprobados.com"
ZONE_FILE="/var/cache/bind/db.${DOMAIN}"
NAMED_CONF_LOCAL="/etc/bind/named.conf.local"
NAMED_CONF_OPTIONS="/etc/bind/named.conf.options"
INTERNAL_IFACE="enp0s8"

if [ "$EUID" -ne 0 ]; then
    echo "Debes ser root para ejecutar"
    exit 1
fi

mkdir -p /etc/bind /var/cache/bind

validate_ip() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    [[ $ip =~ $regex ]] || return 1
    IFS='.' read -ra o <<< "$ip"
    for octet in "${o[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

CURRENT_IP=$(ip -o -4 addr show dev "$INTERNAL_IFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n 1)
IS_DHCP=$(ip -o -4 addr show dev "$INTERNAL_IFACE" 2>/dev/null | grep -c "dynamic" || true)

if [[ "$IS_DHCP" -gt 0 || -z "$CURRENT_IP" ]]; then
    echo "La interfaz $INTERNAL_IFACE no tiene IP estatica"
    read -p "Configurar IP estatica? (s/n): " SET_STATIC

    if [[ "$SET_STATIC" == "s" ]]; then
        while true; do
            read -p "IP fija: " STATIC_IP
            validate_ip "$STATIC_IP" && break
            echo "IP invalida"
        done
        read -p "Prefijo (24 recomandado): " PREFIX
        PREFIX=${PREFIX:-24}

        cat > /etc/netplan/01-dns-server.yaml << NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERNAL_IFACE}:
      addresses:
        - ${STATIC_IP}/${PREFIX}
      dhcp4: false
NETPLAN

        chmod 600 /etc/netplan/01-dns-server.yaml
        netplan apply 2>/dev/null && echo "IP estatica configurada: $STATIC_IP" \
            || { echo "Error aplicando netplan"; exit 1; }
        CURRENT_IP="$STATIC_IP"
        echo "IP estatica configurada: $CURRENT_IP"
    fi
else
    echo "IP estatica detectada: $CURRENT_IP"
fi

[[ -z "$CURRENT_IP" ]] && { echo "No se pudo conectar"; exit 1; }
echo "IP del servidor DNS: $CURRENT_IP"

while true; do
    read -p "Ingresa la IP del cliente a la que apuntara $DOMAIN: " TARGET_IP
    validate_ip "$TARGET_IP" && break
    echo "IP invalida"
done

if dpkg -l 2>/dev/null | grep -q "^ii  bind9 "; then
    echo "Paquetes ya instalados"
else
    echo "Instalando paquetes"
    apt-get update -y -q > /dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        bind9 bind9utils bind9-doc dnsutils > /dev/null 2>&1 \
        || { echo "Error instalando paquetes"; exit 1; }
    echo "Paquetes instalados"
fi

cat > "$NAMED_CONF_OPTIONS" << EOF
options {
    directory "/var/cache/bind";
    forwarders { 8.8.8.8; 8.8.4.4; };
    allow-query { any; };
    allow-recursion { any; };
    dnssec-validation auto;
    listen-on { any; };
};
EOF

touch "$NAMED_CONF_LOCAL"

if grep -q "\"${DOMAIN}\"" "$NAMED_CONF_LOCAL"; then
    echo "Zona ya existente"
else
    cat >> "$NAMED_CONF_LOCAL" << EOF

zone "${DOMAIN}" {
    type master;
    file "${ZONE_FILE}";
};
EOF
    echo "Zona $DOMAIN registrada en named.conf.local"
fi

SERIAL=$(date +%Y%m%d01)

cat > "$ZONE_FILE" << EOF
\$TTL 604800
@   IN  SOA ns.${DOMAIN}. admin.${DOMAIN}. (
            ${SERIAL}
            604800
            86400
            2419200
            604800 )

@   IN  NS  ns.${DOMAIN}.
@   IN  A   ${TARGET_IP}
www IN  A   ${TARGET_IP}
ns  IN  A   ${CURRENT_IP}
EOF

chown bind:bind "$ZONE_FILE" 2>/dev/null || true
echo "archivo creado en $ZONE_FILE"

command -v named-checkconf >/dev/null 2>&1 \
    && { named-checkconf && echo "named-checkconf: OK"; }

command -v named-checkzone >/dev/null 2>&1 \
    && { named-checkzone "$DOMAIN" "$ZONE_FILE" && echo "named-checkzone: OK"; }

systemctl restart named 2>/dev/null || systemctl restart bind9 2>/dev/null \
    || { echo "Error al reiniciar el servidor"; exit 1; }
systemctl enable named 2>/dev/null || systemctl enable bind9 2>/dev/null || true

if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
    echo "Bind9 activo"
else
    echo "Bind9 no inicio"
    journalctl -u bind9 --no-pager | tail -n 20
fi

if command -v nslookup >/dev/null 2>&1 ; then
    echo ""
    nslookup "$DOMAIN" 127.0.0.1
    nslookup "www.$DOMAIN" 127.0.0.1
fi

echo ""
echo "Configuracion completa"
echo "  $DOMAIN      -> $TARGET_IP"
echo "  www.$DOMAIN  -> $TARGET_IP"
echo "  ns.$DOMAIN   -> $CURRENT_IP"