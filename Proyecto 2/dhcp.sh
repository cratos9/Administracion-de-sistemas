#!/bin/bash

DHCP_CONF="/etc/dhcp/dhcpd.conf"
DHCP_DEFAULT="/etc/default/isc-dhcp-server"
DHCP_LEASES="/var/lib/dhcp/dhcpd.leases"

instalar_dhcp() {
	instalar_paquete "isc-dhcp-server"
}

configurar_dhcp() {
	read -p "Nombre: " SCOPE_NAME
	leer_ip "IP inicial: " START_IP
	leer_ip "IP final: " END_IP
	leer_ip "Gateway: " GATEWAY
	leer_ip "DNS: " DNS
	read -p "Lease (segundos): " LEASE
	LEASE=${LEASE:~86400}

	local NET
	NET=$(echo "$GATEWAY" | awk -F'.' '{print $1"."$2"."$3".0"}')

	cat > "DHCP_CONF" <<EOF
default-lease-time $LEASE;
max-lease-time $(( LEASE * 2));

subnet $NET netmask 255.255.255.0{
	range $START_IP $END_IP;
	option routers $GATEWAY;
	option domain-name-servers $DNS;
	option domain-name "$SCOPE_NAME";
}
EOF
	log "Archivo $DHCP_CONF escrito"
}

configurar_interfaz_dhcp() {
	echo "Interfaces disponibles:"
	ip -o link show | awk -F': ' '{print $2}' | grep -v lo | nl -w2
	read -p "Interfaz interna para DHCP: " IFACE_DHCP

	if grep -q "INTERFACESv4" "$DHCP_DEFAULT" 2>/dev/null; then
		sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$IFACE_DHCP\"/" "$DHCP_DEFAULT"
	else
		echo "INTERFACESv4=\"$IFACE_DHCP\"" >> "$DHCP_DEFAULT"
	fi
	log "Interfaz $IFACE_DHCP configurada"
}

reiniciar_dhcp() {
	dhcpd -t -cf "$DHCP_CONF" 2>&1 || { echo "Error"; return 1; }
	systemctl restart isc-dhcp-server
	systemctl enable isc-dhcp-server 2>/dev/null
	systemctl status isc-dhco-server --no-pager | tail -n 6
}

ver_leases_dhcp() {
	if [ -f "$DHCP_LEASES" ] && [ -s "$DHCP_LEASES" ]; then
		cat "$DHCP_LEASES"
	else
		echo "No hay leases activos"
	fi
}

configurar_dhcp_completo() {
	instalar_dhcp
	configurar_dhcp
	configurar_interfaz_dhcp
	reiniciar_dhcp
	ver_leases_dhcp
}
