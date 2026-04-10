#!/bin/bash

set -euo pipefail

FTP_BASE="/srv/ftp"
FTP_HOME_BASE="/home/ftpusers"
VSFTPD_CONF="/etc/vsftpd.conf"
USERCONF_DIR="/etc/vsftpd/userconf"
USERLIST_FILE="/etc/vsftpd.userlist"
GRUPOS=("reprobados" "recursadores")

check_root() {
    [[ $EUID -eq 0 ]] || { echo "Debes ejecutar como root"; exit 1; }
}

instalar_vsftpd() {
    echo "Instalacion de vsftpd"
    if dpkg -l vsftpd 2>/dev/null | grep -q "^ii"; then
        echo "vsftpd ya esta instalado."
    else
        apt-get update -q && apt-get install -y vsftpd
        echo "vsftpd instalado."
    fi
    [[ -f "${VSFTPD_CONF}.bak" ]] || cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak"
    grep -qx "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells
    mkdir -p /var/run/vsftpd/empty
    chmod 000 /var/run/vsftpd/empty
}

configurar_vsftpd() {
    echo "Configuracion de vsftpd.conf"
    mkdir -p "$USERCONF_DIR"
    cat > "$VSFTPD_CONF" << 'VSCONF'
listen=YES
listen_ipv6=NO
anonymous_enable=YES
anon_root=/srv/ftp
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
user_config_dir=/etc/vsftpd/userconf
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
ftpd_banner=Bienvenido al servidor FTP. Solo personal autorizado.
dirmessage_enable=YES
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
xferlog_std_format=YES
log_ftp_protocol=YES
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
pam_service_name=vsftpd
secure_chroot_dir=/var/run/vsftpd/empty
ssl_enable=NO
VSCONF
    touch "$USERLIST_FILE"
    greq -qxF "anonymous" "$USERLIST_FILE" || echo "anonymous" >> "$USERLIST_FILE"
    greq -qxF "ftp"       "$USERLIST_FILE" || echo "anonymous" >> "$USERLIST_FILE"
    echo "vsftpd.conf configurado."
}

crear_grupos() {
    echo "Creacion de grupos"
    for grupo in "${GRUPOS[@]}"; do
        if getent group "$grupo" &>/dev/null; then
            echo "Grupo '$grupo' ya existe."
        else
            groupadd "$grupo"
            echo "Grupo '$grupo' creado."
        fi
    done
    if ! getent group ftpusers &>/dev/null; then
        groupadd ftpusers
        echo "Grupo 'ftpusers' creado."
    fi
}

crear_estructura_base() {
    echo "Estructura de directorios base"
    mkdir -p "${FTP_BASE}/general" "${FTP_BASE}/reprobados" \
             "${FTP_BASE}/recursadores" "$FTP_HOME_BASE"

    chown root:ftp       "${FTP_BASE}";           chmod 755  "${FTP_BASE}"
    chown root:ftpusers  "${FTP_BASE}/general";   chmod 2775 "${FTP_BASE}/general"
    chown root:reprobados   "${FTP_BASE}/reprobados";   chmod 2770 "${FTP_BASE}/reprobados"
    chown root:recursadores "${FTP_BASE}/recursadores"; chmod 2770 "${FTP_BASE}/recursadores"

    echo "Directorios y permisos configurados."
}

montar_bind() {
    local src="$1" dst="$2"
    grep -qF "$dst" /etc/fstab || echo "${src}  ${dst}  none  bind  0  0" >> /etc/fstab
    mountpoint -q "$dst" || mount --bind "$src" "$dst"
}

crear_home_usuario() {
    local username="$1"
    local grupo="$2"
    local home_dir="${FTP_HOME_BASE}/${username}"

    mkdir -p "$home_dir"
    chown root:root "$home_dir"
    chmod 755 "$home_dir"

    mkdir -p "${home_dir}/general"
    chown root:ftpusers "${home_dir}/general"
    chmod 2775 "${home_dir}/general"

    mkdir -p "${home_dir}/${grupo}"
    chown root:"${grupo}" "${home_dir}/${grupo}"
    chmod 2770 "${home_dir}/${grupo}"

    mkdir -p "${home_dir}/${username}"
    chown "${username}":ftpusers "${home_dir}/${username}"
    chmod 750 "${home_dir}/${username}"

    montar_bind "${FTP_BASE}/general"  "${home_dir}/general"
    montar_bind "${FTP_BASE}/${grupo}" "${home_dir}/${grupo}"
}

crear_usuario_ftp() {
    local username="$1"
    local password="$2"
    local grupo="$3"
    local home_dir="${FTP_HOME_BASE}/${username}"

    echo "Creando usuario: ${username} (grupo: ${grupo})"

    if id "$username" &>/dev/null; then
        echo "Usuario '$username' ya existe. Actualizando."
    else
        useradd --home-dir "$home_dir" --no-create-home \
                --shell /usr/sbin/nologin --gid ftpusers "$username"
    fi

    echo "${username}:${password}" | chpasswd

    for g in "${GRUPOS[@]}"; do
        gpasswd -d "$username" "$g" &>/dev/null || true
    done
    usermod -aG "$grupo" "$username"

    crear_home_usuario "$username" "$grupo"

    grep -qxF "$username" "$USERLIST_FILE" || echo "$username" >> "$USERLIST_FILE"

    echo "Usuario '$username' listo."
}

cambiar_grupo_usuario() {
    local username="$1"
    local nuevo_grupo="$2"
    local home_dir="${FTP_HOME_BASE}/${username}"

    echo "Cambio de grupo: ${username} -> ${nuevo_grupo}"

    id "$username" &>/dev/null || { echo "Usuario '$username' no existe."; return 1; }
    [[ "$nuevo_grupo" == "reprobados" || "$nuevo_grupo" == "recursadores" ]] \
        || { echo "Grupo invalido. Use: reprobados | recursadores"; return 1; }

    local grupo_actual=""
    for g in "${GRUPOS[@]}"; do
        id -nG "$username" | tr ' ' '\n' | grep -qx "$g" && grupo_actual="$g" && break
    done

    if [[ "$grupo_actual" == "$nuevo_grupo" ]]; then
        echo "'$username' ya pertenece a '$nuevo_grupo'."; return 0
    fi

    if [[ -n "$grupo_actual" ]]; then
        mountpoint -q "${home_dir}/${grupo_actual}" 2>/dev/null \
            && umount "${home_dir}/${grupo_actual}"
        sed -i "\|${home_dir}/${grupo_actual}|d" /etc/fstab
        rm -rf "${home_dir:?}/${grupo_actual}"
        gpasswd -d "$username" "$grupo_actual" &>/dev/null || true
        echo "Carpeta '${grupo_actual}' eliminada."
    fi

    usermod -aG "$nuevo_grupo" "$username"
    mkdir -p "${home_dir}/${nuevo_grupo}"
    chown root:"${nuevo_grupo}" "${home_dir}/${nuevo_grupo}"
    chmod 2770 "${home_dir}/${nuevo_grupo}"
    montar_bind "${FTP_BASE}/${nuevo_grupo}" "${home_dir}/${nuevo_grupo}"

    echo "Grupo cambiado a '${nuevo_grupo}'."
}

creacion_masiva_usuarios() {
    echo "Creacion de usuarios"
    local n
    while true; do
        read -rp "Cuantos usuarios desea crear? " n
        [[ "$n" =~ ^[1-9][0-9]*$ ]] && break
        echo "Ingrese un numero entero positivo."
    done

    for (( i=1; i<=n; i++ )); do
        echo ""
        echo "Usuario $i / $n"

        local username
        while true; do
            read -rp "  Nombre de usuario              : " username
            [[ "$username" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,29}$ ]] && break
            echo "  Invalido: letras/numeros/guion, min 3 chars, inicia con letra."
        done

        local pass1 pass2
        while true; do
            read -rsp "  Contrasena                     : " pass1; echo
            read -rsp "  Confirmar contrasena           : " pass2; echo
            [[ "$pass1" == "$pass2" && -n "$pass1" ]] && break
            echo "  Las contrasenas no coinciden o estan vacias."
        done

        local grupo
        while true; do
            read -rp "  Grupo (reprobados/recursadores): " grupo
            [[ "$grupo" == "reprobados" || "$grupo" == "recursadores" ]] && break
            echo "  Ingrese exactamente: reprobados  o  recursadores"
        done

        crear_usuario_ftp "$username" "$pass1" "$grupo"
    done
}

configurar_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "=== Configurando UFW ==="
        ufw allow 20/tcp  &>/dev/null || true
        ufw allow 21/tcp  &>/dev/null || true
        ufw allow 40000:50000/tcp &>/dev/null || true
        ufw reload &>/dev/null
        echo "Puertos FTP habilitados en UFW."
    fi
}

reiniciar_vsftpd() {
    echo "=== Reiniciando vsftpd ==="
    systemctl enable vsftpd
    systemctl restart vsftpd
    systemctl is-active --quiet vsftpd \
        && echo "vsftpd activo." \
        || { echo "vsftpd no inicio. Revise: journalctl -u vsftpd -n 30"; exit 1; }
}

mostrar_estado() {
    systemctl status vsftpd --no-pager || true
    echo ""
    ss -tlnp | grep -E ':21|:20|:4[0-9]{4}' || echo "Sin puertos FTP activos."
}

mostrar_resumen() {
    echo ""
    echo "Configuracion completada"
    echo "  Raiz anonima : ${FTP_BASE}"
    echo "  Homes FTP    : ${FTP_HOME_BASE}"
    echo "  Config       : ${VSFTPD_CONF}"
    echo "  Userlist     : ${USERLIST_FILE}"
    echo ""
    echo "  Anonimo  -> ${FTP_BASE}/general  (solo lectura)"
    echo "  Auth     -> ~/general            (escritura)"
    echo "  Auth     -> ~/reprobados|recursadores (escritura)"
    echo "  Auth     -> ~/\$usuario          (escritura personal)"
    echo ""
    echo "  Usuarios registrados:"
    while IFS= read -r u; do
        local g
        g=$(id -nG "$u" 2>/dev/null | tr ' ' '\n' \
            | grep -E "^(reprobados|recursadores)$" | head -1 || echo "sin grupo")
        echo "    $u  ->  $g"
    done < "$USERLIST_FILE"
    echo ""
}

menu_principal() {
    echo ""
    echo "  SERVIDOR FTP LINUX - vsftpd"
    echo "  Grupos: reprobados | recursadores"
    echo "  1) Configuracion inicial completa"
    echo "  2) Agregar nuevos usuarios"
    echo "  3) Cambiar grupo de un usuario"
    echo "  4) Reiniciar vsftpd"
    echo "  5) Ver estado del servicio"
    echo "  6) Salir"
    echo ""
    read -rp "Opcion [1-6]: " opcion

    case "$opcion" in
        1)
            instalar_vsftpd
            crear_grupos
            configurar_vsftpd
            crear_estructura_base
            creacion_masiva_usuarios
            configurar_firewall
            reiniciar_vsftpd
            mostrar_resumen
            ;;
        2)
            creacion_masiva_usuarios
            reiniciar_vsftpd
            ;;
        3)
            read -rp "Usuario a modificar              : " usr_mod
            read -rp "Nuevo grupo (reprobados/recursadores): " grp_mod
            cambiar_grupo_usuario "$usr_mod" "$grp_mod"
            reiniciar_vsftpd
            ;;
        4) reiniciar_vsftpd ;;
        5) mostrar_estado ;;
        6) echo "Saliendo..."; exit 0 ;;
        *) echo "Opcion invalida."; menu_principal ;;
    esac
}

main() {
    check_root
    menu_principal
}

main "$@"
