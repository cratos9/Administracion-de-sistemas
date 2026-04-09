#!/bin/bash

ver_estado_servidor() {
	echo "Los datos son:"
	echo "Nombre del host:"
	hostname
	echo ""
	echo "Direccion IP:"
	hostname -I
	echo ""
	echo "Espacio en disco:"
	df -h /
}
