$DOMAIN    = "reprobados.com"
$ZONE_FILE = "db.reprobados.com"
$SERVER_IP = $null

function Obtener-IP-Servidor{
	$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } |
    		Where-Object { 
			(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.100.*" 
		} | Select-Object -First 1

	if ($null -eq $adapter) {
	    Write-Host "No se detecto adaptador"
	    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Format-Table Name, InterfaceDescription, Status
	    $adaptersName = Read-Host "Ingresa el nombre del adaptador"
	    $adapter = Get-NetAdapter -Name $adaptersName
	}

	$script:SERVER_IP = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).IPAddress
	Log "IP del servidor: $script:SERVER_IP"
}

function Instalar-DNS {
	$dnsFeature = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
	if ($null -ne $dnsFeature -and $dnsFeature.Installed) {
		Log "Paquete DNS ya instalado"
	} else {
		Log "Instalando DNS"
		Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
		Log "Paquete instalado"
	}
	Import-Module DnsServer -ErrorAction SilentlyContinue
}

function Configurar-Zona-DNS {
	$TARGET_IP = Leer-IP "IP del cliente para $DOMAIN"
	$existingZone = Get-DnsServerZone -Name $DOMAIN -ErrorAction SilentlyContinue
	if ($null -ne $existingZone) {
		Log "Zona $DOMAIN ya existente"
	} else {
		Add-DnsServerPrimaryZone -Name $DOMAIN -ZoneFile $ZONE_FILE -DynamicUpdate None
		Log "Zona $DOMAIN creada"
	}

	foreach ($nombre in ("@","www")) {
		$rec = Get-DnsServerResourceRecord -ZoneName $DOMAIN -Name $nombre -RRType A -ErrorAction SilentlyContinue
		if ($null -ne $rec) {
    			Remove-DnsServerResourceRecord -ZoneName $DOMAIN -Name $nombre -RRType A -Force -ErrorAction SilentlyContinue
		}
		Add-DnsServerResourceRecordA -ZoneName $DOMAIN -Name $nombre -IPv4Address $TARGET_IP
		Log "Registro A: $nombre.$DOMAIN -> $TARGET_IP"
	}

	$recNS = Get-DnsServerResourceRecord -ZoneName $DOMAIN -Name "ns" -RRType A -ErrorAction SilentlyContinue
	if ($null -ne $recNS) {
		Remove-DnsServerResourceRecord -ZoneName $DOMAIN -Name "ns" -RRType A -Force -ErrorAction SilentlyContinue
	}
	Add-DnsServerResourceRecordA -ZoneName $DOMAIN -Name "ns" -IPv4Address $script:SERVER_IP
	Log "Registro A: ns.$DOMAIN -> $script:SERVER_IP"
}

function Reiniciar-DNS {
	Set-Service  -Name DNS -StartupType Automatic
	Restart-Service -Name DNS
	Start-Sleep -Seconds 2
	$svc = Get-Service -Name DNS
	if ($svc.Status -eq "Running") {
		Log "El servicio DNS esta activo"
	} else {
		Write-Host "El servicio DNS no inicio"
	}
}

function Verificar-DNS{
	nslookup $DOMAIN 127.0.0.1
	nslookup "www.$DOMAIN" 127.0.0.1
}

function Configurar-DNS-Completo {
	Obtener-IP-Servidor
	Instalar-DNS
	Configurar-Zona-DNS
	Reiniciar-DNS
	Verificar-DNS
}