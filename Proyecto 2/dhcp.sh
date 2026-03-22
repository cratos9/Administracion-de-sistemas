#!/bin/bash

if dpkg -l | grep -q isc-dhcp-server; then
	echo "El paquete ya estaba instalado"
else
	echo "Instalando paquete"
	sudo apt-get update -y
	sudo apt-get install isc-dhcp-server -y
fi

read -p "Nombre: " SCOPE_NAME
read -p "IP inicial: " START_IP
read -p "IP final: " END_IP
read -p "Gateway: " GATEWAY
read -p "DNS: " DNS
read -p "Lease (segundos): " LEASE

sudo bash -c "cat > /etc/dhcp/dhcpd.conf" <<EOF
default-lease-time $LEASE;
max-lease-time $LEASE;

subnet 192.168.100.0 netmask 255.255.255.0{
	range $START_IP $END_IP;
	option routers $GATEWAY;
	option domain-name-servers $DNS;
}
EOF

sudo bash -c 'echo INTERFACESv4="enp0s8" > /etc/default/isc-dhcp-server'
sudo dhcpd -t

sudo systemctl restart isc-dhcp-server
sudo systemctl enable isc-dhcp-server

systemctl status isc-dhcp-server
cat /var/lib/dhcp/dhcpd.leases
