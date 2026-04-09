#!/bin/bash

DOMAIN="reprobados.com"
ZONE_FILE="/var/cache/bind/db.${DOMAIN}"
NAMED_CONF_LOCAL="/etc/bind/named.conf.local"
NAMED_CONF_OPTIONS="/etc/bind/named.conf.options"
INTERNAL_IFACE="enp0s8"
DNS_SERVER_IP=""

obtener_ip_enp0s8() {
	DNS_SERVER_IP=$(ip -o -4 addr show dev "$INTERNAL_IFACE" 2>/dev/null \
		| awk '{print $4}' | cut -d'/' -f1 | head -n 1)
	if [[ -z "$DNS_SERVER_IP" ]]; then
		echo "La interfaz $INTERNAL_IFACE no tiene IP estatica"
		read -p "Configurar IP estatica? (s/n): " resp
		if [[ "$resp" == "s" ]]; then
        		leer_ip "IP estatica para $INTERNAL_IFACE" DNS_SERVER_IP
			read -p "Prefijo (24 recomandado): " PREFIX
	        	PREFIX=${PREFIX:-24}

			mkdir -p /etc/netplan
			cat > /etc/netplan/01-dns-server.yaml << NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERNAL_IFACE:
      addresses:
        - $DNS_SERVER_IP/$PREFIX
      dhcp4: false
NETPLAN

			chmod 600 /etc/netplan/01-dns-server.yaml
			netplan apply 2>/dev/null && log "IP estatica configurada: $DNS_SERVER_IP"
		else
			log "IP detectada en $INTERNAL_IFACE para continuar"
			return 1
		fi
	else
		log "IP detectada en $INTERNAL_IFACE: $DNS_SERVER_IP"
	fi
}

instalar_dns() {
	for pkg in bind9 bind9utils bind9-doc dnsultils; do
		instalar_paquete "$pkg"
	done
	mkdir -p /etc/bind /var/cache/bind
}

configurar_opciones_bind() {
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
	log "named.conf.options configurado"
}

configurar_zona_dns() {
	local TARGET_IP
	leer_ip "IP del cliente para el dominio $DOMAIN:" TARGET_IP

	touch "$NAMED_CONF_LOCAL"
	if grep -q "\"${DOMAIN}\"" "$NAMED_CONF_LOCAL"; then
		echo "Zona ya existente"
	else
    		cat >> "$NAMED_CONF_LOCAL" << EOF

zone "$DOMAIN" {
    type master;
    file "$ZONE_FILE";
};
EOF
		log "Zona $DOMAIN registrada en named.conf.local"
	fi

	local SERIAL
	SERIAL=$(date +%Y%m%d01)

	cat > "$ZONE_FILE" << EOF
\$TTL 604800
@   IN  SOA ns.$DOMAIN. admin.$DOMAIN. (
            $SERIAL
            604800
            86400
            2419200
            604800 )

@   IN  NS  ns.$DOMAIN.
@   IN  A   $TARGET_IP
www IN  A   $TARGET_IP
ns  IN  A   $DNS_SERVER_IP
EOF

	chown bind:bind "$ZONE_FILE" 2>/dev/null || true
	log "archivo creado en $ZONE_FILE"
}

reiniciar_dns() {
	named-checkconf 2>&1 && log "named-checkconf OK"
	named-checkzone "$DOMAIN" "$ZONE_FILE" 2>&1 && log "named-checkzone OK"

	systemctl restart named 2>/dev/null || systemctl restart bind9 2>/dev/null
	systemctl enable named 2>/dev/null || systemctl enable bind9 2>/dev/null || true

	if systemctl is-active --quiet named 2>/dev/null || \
		systemctl is-active --quiet bind9 2>/dev/null; then
		log "Bind9 activo"
	else
		log "Bind9 no inicio"
		journalctl -u bind9 --no-pager | tail -n 10
	fi
}

verificar_dns() {
	if command -v nslookup >/dev/null 2>&1 ; then
		nslookup "$DOMAIN" 127.0.0.1
		nslookup "www.$DOMAIN" 127.0.0.1
	else
		echo "nslookup no disponible"
	fi
}

configurar_dns_completo() {
	obtener_ip_enp0s8
	instalar_dns
	configurar_opciones_bind
	configurar_zona_dns
	reiniciar_dns
	verificar_dns
}
