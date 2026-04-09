#!/bin/bash

log() {
	echo "[*] $1"
}

verificar_root() {
	if [ "$EUID" -ne 0 ]; then
		echo "Ejecuta como root"
		exit 1
	fi
}

paquete_instalado() {
	dpkg -l 2>/dev/null | grep -q "^ii $1 "
}

instalar_paquete() {
	local pkg="$1"
	if paquete_instalado "$pkg"; then
		log "El paquete $pkg ya esta instalado"
	else
		log "Instalando $pkg ..."
		apt-get update -y -q > /dev/null 2>&1
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" > /dev/null 2>&1
		log "$pkg instalado"
	fi
}

validar_ip() {
	local ip="$1"
	local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
	[[ $ip =~ $regex ]] || return 1
	IFS='.' read -ra o <<< "$ip"
	for oct in "${o[@]}"; do
		(( oct >= 0 && oct <= 255 )) || return 1
	done
	return 0
}

leer_ip() {
	local prompt="$1"
	local var="$2"
	local val
	while true; do
		read -p "$prompt" val
		if validar_ip "$val"; then
			eval "$var='$val'"
			break
		else
			echo "IP invalida"
		fi
	done
}

pausar() {
	read -p "Presiona Enter para continuar"
}
