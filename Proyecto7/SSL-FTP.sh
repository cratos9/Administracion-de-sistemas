#!/bin/bash

VSFTPD_CONF="/etc/vsftpd.conf"
SSL_DIR="/etc/ssl/servidores/ftp"
CERT_DAYS=365

check_root() {
if [ "$(id -u)" -ne 0 ]; then
echo "Ejecuta este script como root o con sudo."
exit 1
fi
}

verificar_vsftpd() {
if ! systemctl is-active --quiet vsftpd; then
echo "vsftpd no esta corriendo. Instala y levanta vsftpd antes de configurar SSL."
exit 1
fi
}

generar_certificado() {
mkdir -p "$SSL_DIR"

if [ -f "${SSL_DIR}/cert.pem" ] && [ -f "${SSL_DIR}/key.pem" ]; then
echo "Certificado FTP ya existe. Reutilizando."
return
fi

apt-get install -y openssl 2>/dev/null

openssl req -x509 -nodes -newkey rsa:2048 \
-keyout "${SSL_DIR}/key.pem" \
-out "${SSL_DIR}/cert.pem" \
-days "$CERT_DAYS" \
-subj "/C=MX/ST=Estado/L=Ciudad/O=ServidorFTP/CN=ftp-servidor" 2>/dev/null

chmod 600 "${SSL_DIR}/key.pem"
chmod 644 "${SSL_DIR}/cert.pem"

echo "Certificado autofirmado generado para vsftpd."
}

configurar_ssl_vsftpd() {
generar_certificado

if [ ! -f "$VSFTPD_CONF" ]; then
echo "Archivo ${VSFTPD_CONF} no encontrado."
exit 1
fi

[ -f "${VSFTPD_CONF}.prebak" ] || cp "$VSFTPD_CONF" "${VSFTPD_CONF}.prebak"

sed -i '/^ssl_enable/d' "$VSFTPD_CONF"
sed -i '/^rsa_cert_file/d' "$VSFTPD_CONF"
sed -i '/^rsa_private_key_file/d' "$VSFTPD_CONF"
sed -i '/^ssl_tlsv1/d' "$VSFTPD_CONF"
sed -i '/^ssl_sslv2/d' "$VSFTPD_CONF"
sed -i '/^ssl_sslv3/d' "$VSFTPD_CONF"
sed -i '/^force_local_data_ssl/d' "$VSFTPD_CONF"
sed -i '/^force_local_logins_ssl/d' "$VSFTPD_CONF"
sed -i '/^allow_anon_ssl/d' "$VSFTPD_CONF"
sed -i '/^require_ssl_reuse/d' "$VSFTPD_CONF"
sed -i '/^ssl_ciphers/d' "$VSFTPD_CONF"

cat >> "$VSFTPD_CONF" <<EOF
ssl_enable=YES
rsa_cert_file=${SSL_DIR}/cert.pem
rsa_private_key_file=${SSL_DIR}/key.pem
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
allow_anon_ssl=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
EOF

echo "Directivas SSL agregadas a ${VSFTPD_CONF}."
}

reiniciar_vsftpd() {
systemctl restart vsftpd
sleep 2

if systemctl is-active --quiet vsftpd; then
echo "vsftpd reiniciado con SSL activo."
else
echo "vsftpd no pudo reiniciar. Revisa: journalctl -xeu vsftpd.service"
exit 1
fi
}

verificar_certificado() {
CERT="${SSL_DIR}/cert.pem"
if [ -f "$CERT" ]; then
EXPIRY=$(openssl x509 -noout -enddate -in "$CERT" 2>/dev/null | cut -d= -f2)
SUBJECT=$(openssl x509 -noout -subject -in "$CERT" 2>/dev/null | cut -d= -f2-)
echo "Certificado FTP: OK"
echo "Sujeto : ${SUBJECT}"
echo "Vence  : ${EXPIRY}"
else
echo "No se encontro certificado en ${SSL_DIR}."
fi

echo ""
systemctl is-active vsftpd && echo "vsftpd: activo" || echo "vsftpd: inactivo"
ss -tlnp | grep ':21' || echo "Puerto 21 no detectado."
}

menu_principal() {
check_root

while true; do
echo ""
echo "Gestor SSL - Servidor FTP (vsftpd)"
echo "1) Configurar certificado SSL y activar FTPS"
echo "2) Ver estado del certificado"
echo "3) Salir"
read -rp "Opcion: " OPCION

case $OPCION in
1)
verificar_vsftpd
configurar_ssl_vsftpd
reiniciar_vsftpd
verificar_certificado
;;
2)
verificar_certificado
;;
3) echo "Saliendo."; exit 0 ;;
*) echo "Opcion invalida." ;;
esac
done
}

menu_principal