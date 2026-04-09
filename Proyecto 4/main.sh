#!/bin/bash

P4="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$P4")"

source "$P4/funciones_comunes.sh"
source "$ROOT/Proyecto 1/check_status.sh"
source "$ROOT/Proyecto 2/dhcp.sh"
source "$ROOT/Proyecto 3/dns.sh"
source "$P4/funciones_ssh.sh"

verificar_root

while true; do
	clear
	echo "Opciones:"
	echo "1. Estado del servidor"
	echo "2. Configurar DHCP"
	echo "3. Configurar DNS"
	echo "4. Configurar SSH"
	echo "5. Ver leases DHCP"
	echo "6. Verificar SSH"
	echo "7. Info de conexion SSH"
	echo "0. Salir"
	echo ""
	read -p "Opcion: " op

	case "$op" in
		1) ver_estado_servidor; pausar ;;
		2) configurar_dhcp_completo; pausar ;;
		3) configurar_dns_completo; pausar ;;
		4) configurar_ssh_completo; pausar ;;
		5) ver_leases_dhcp; pausar ;;
		6) verificar_ssh; pausar ;;
		7) mostrar_conexion_ssh; pausar ;;
		0) echo "Saliendo"; exit 0 ;;
		*) echo "Opcion invalida"; sleep 1 ;;
	esac
done
