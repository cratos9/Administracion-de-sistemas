#!/bin/bash

SSH_CONFIG="/etc/ssh/sshd_config"
SSH_PORT=22

instalar_ssh() {
	instalar_paquete "openssh-server"
}

habilitar_ssh() {
	systemctl start ssh
	systemctl enable ssh
	log "SSH iniciado y habilitado"
	systemctl status ssh --no-pager | tail -n 6
}

configurar_firewall_ssh() {
	if ! command -v ufw >/dev/null 2>&1; then
		instalar_paquete "ufw"
	fi
	ufw allow $SSH_PORT/tcp
	ufw --force enable 2>/dev/null
	log "Puerto $SSH_PORT abierto en UFW"
	ufw status
}

configurar_seguridad_ssh() {
	cp "$SSH_CONFIG" "{$SSH_CONFIG}.bak" 2>/dev/null

	local items=(
		"PermitRootLogin no"
		"PasswordAuthentication yes"
		"MaxAuthTries 3"
		"LoginGraceTime 60"
		"X11Forwarding no"
		"ClientAliveInterval"
		"ClientAliveCountMax 2"
	)

	for item in "${items[@]}"; do
		local key
		key=$(echo "$item" | awk '{print $1}')
		if grep -q "^#*$key" "$SSH_CONFIG" 2>/dev/null; then
			sed -i "s|^#*$key.*|$item|" "$SSH_CONFIG"
		else
			echo "$item" >> "$SSH_CONFIG"
		fi
	done

	systemctl restart ssh
	log "Configuracion SSH aplicada"
}

verificar_ssh() {
	echo "Estado del servicio:"
	systemctl is-active ssh
	echo ""
	echo "Puerto en escucha:"
	ss -tlnp | grep ":$SSH_PORT" || echo "Puerto $SSH_PORT no detectado"
	echo ""
	echo "Reglas UFW:"
	ufw status 2>/dev/null | grep -E "Status|$SSH_PORT" || true
}

mostrar_conexion_ssh() {
	local user ips
	user=$(logname 2>/dev/null || echo "usuario")
	ips=$(hostname -I)
	echo ""
	echo "Para conectarte desde el cliente:"
	for ip in $ips; do
		echo "  ssh $user@ip"
	done
	echo ""
	echo "Desde PuTTY / MobaXterm: host=$ip puerto=$SSH_PORT"
	echo ""
	echo "NO USAR CONSOLA FISICA, SOLO SSH"
}

configurar_ssh_completo() {
	instalar_ssh
	habilitar_ssh
	configurar_firewall_ssh
	configurar_seguridad_ssh
	verificar_ssh
	mostrar_conexion_ssh
}
