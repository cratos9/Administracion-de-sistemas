$SSH_PORT = 22

function Instalar-SSH {
	$cap = Get-WindowsCapability -Online -Name OpenSSH.Server* -ErrorAction SilentlyContinue
	if ($cap.State -eq "Installed") {
		Log "OpenSSH Server ya instalado"
	} else {
		Log "Instalando OpenSSH Server"
		Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
		Log "OpenSSH Server instalado"
	}
}

function Habilitar-SSH {
	Start-Service sshd
	Set-Service -Name sshd -StartupType Automatic
	Log "Servicio sshd iniciado y habilitado en el arranque"
	Get-Service sshd | Select-Object Name, Status, StartType
}

function Configurar-Firewall-SSH {
	$regla = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
	if ($null -ne $regla) {
		Log "Regla de firewall para puerto $SSH_PORT ya existe"
	} else {
		New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
			-DisplayName "OpenSSH Server (puerto $SSH_PORT)" `
			-Protocol TCP `
			-LocalPort $SSH_PORT `
			-Action Allow `
			-Direction Inbound | Out-Null
		Log "Regla de firewall creada: puerto $SSH_PORT abierto"
	}
	Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" | Select-Object DisplayName, Enabled, Direction
}

function Verificar-SSH {
	Log "Estado del servicio"
	Get-Service sshd | Select-Object Name, Status, StartType
	Log "Puerto en escucha:"
	netstat -an | findstr ":$SSH_PORT"
	Log "Regla de firewall:"
	Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue |
		Select-Object DisplayName, Enabled
}

function Mostrar-Conexion-SSH {
	$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.100.*" }).IPAddress
	$user = $env:USERNAME
	Write-Host ""
	Write-Host "Para conectarte desde el cliente:"
	Write-Host "  ssh $user@$ip"
	Write-Host ""
	Write-Host "NO USAR CONSOLA FISICA, SOLO SSH"
}

function Configurar-SSH-Completo {
	Verificar-Admin
	Instalar-SSH
	Habilitar-SSH
	Configurar-Firewall-SSH
	Verificar-SSH
	Mostrar-Conexion-SSH
}