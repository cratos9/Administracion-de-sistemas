$P4 = $PSScriptRoot
$ROOT = Split-Path $P4 -Parent

. "$P4\funciones_comunes.ps1"
. "$ROOT\Proyecto 1\check_status.ps1"
. "$ROOT\Proyecto 2\dhcp.ps1"
. "$ROOT\Proyecto 3\dns.ps1"
. "$P4\funciones_ssh.ps1"

Verificar-Admin

do {
	Clear-Host
	Write-Host "Opciones:"
	Write-Host ""
	Write-Host "[1] Estado del servidor"
	Write-Host "[2] Configurar DHCP"
	Write-Host "[3] Configurar DNS"
	Write-Host "[4] Configurar SSH"
	Write-Host "[5] Ver leases DHCP"
	Write-Host "[6] Verificar SSH"
	Write-Host "[7] Info de conexion SSH"
	Write-Host "[0] Salir"
	Write-Host ""
	$op = Read-Host " Opcion"

	switch ($op) {
		"1" { Ver-EstadoServidor;       Pausar }
		"2" { Configurar-DHCP-Completo; Pausar }
		"3" { Configurar-DNS-Completo;  Pausar }
		"4" { Configurar-SSH-Completo;  Pausar }
		"5" { Ver-Leases;               Pausar }
		"6" { Verificar-SSH;            Pausar }
		"7" { Mostrar-Conexion-SSH;     Pausar }
		"0" { Write-Host "Saliendo"; exit 0 }
		default { Write-Host "Opcion invalida"; Start-Sleep 1 }	
	}
} while ($true)