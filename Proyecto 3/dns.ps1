$DOMAIN    = "reprobados.com"
$ZONE_FILE = "db.reprobados.com"
$SERVER_IP = "192.168.100.11"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Debes ejecutar como administrador"
    exit 1
}

function Validate-IP($ip) {
    return $ip -match "^(\d{1,3}\.){3}\d{1,3}$" -and
        ($ip.Split('.') | ForEach-Object { [int]$_ -le 255 -and [int]$_ -ge 0 }) -notcontains $false
}

$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } |
    Where-Object { (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.100.*" } |
        Select-Object -First 1

if ($null -eq $adapter) {
    Write-Host "No se detecto adaptador"
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    $adapters | Format-Table Name, InterfaceDescription, Status
    $adaptersName = Read-Host "Ingresa el nombre del adaptador"
    $adapter = Get-NetAdapter -Name $adaptersName
}

$currentIP = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
$isDHCP    = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).Dhcp -eq "Enabled"

if ($isDHCP -or $currentIP -notlike "192.168.100.*") {
    Write-Host "La interfaz no tiene IP estatica"
    $setStatic = Read-Host "Configurar IP estatica? (s/n)"
    if ($setStatic -eq "s") {
        do {
            $staticIP = Read-Host "IP fija"
        } while (-not (Validate-IP $staticIP))

        do {
            $gateway = Read-Host "Gateway"
        } while (-not (Validate-IP $gateway))

        $prefix = Read-Host "Prefijo"
        if ([string]::IsNullOrEmpty($prefix)) { $prefix = 24 }

        Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute     -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress    -InterfaceIndex $adapter.ifIndex -IPAddress $staticIP -PrefixLength $prefix -DefaultGateway $gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses ("127.0.0.1","8.8.8.8")
        $currentIP = $staticIP
        Write-Host "IP estatica configurada: $currentIP"
    }
} else {
    Write-Host "IP estatica detectada: $currentIP"
}

do {
    $TARGET_IP = Read-Host "IP del cliente para $DOMAIN"
} while (-not (Validate-IP $TARGET_IP))

$dnsFeature = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
if ($null -ne $dnsFeature -and $dnsFeature.Installed) {
    Write-Host "Paquete DNS ya instalado"
} else {
    Write-Host "Instalando DNS"
    Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
    Write-Host "Paquete instalado"
}

Import-Module DnsServer -ErrorAction SilentlyContinue

$existingZone = Get-DnsServerZone -Name $DOMAIN -ErrorAction SilentlyContinue
if ($null -ne $existingZone) {
    Write-Host "Zona $DOMAIN ya existente"
} else {
    Add-DnsServerPrimaryZone -Name $DOMAIN -ZoneFile $ZONE_FILE -DynamicUpdate None
    Write-Host "Zona $DOMAIN creada"
}

$recA = Get-DnsServerResourceRecord -ZoneName $DOMAIN -Name "@" -RRType A -ErrorAction SilentlyContinue
if ($null -ne $recA) {
    Remove-DnsServerResourceRecord -ZoneName $DOMAIN -Name "@" -RRType A -Force -ErrorAction SilentlyContinue
}
Add-DnsServerResourceRecordA -ZoneName $DOMAIN -Name "@" -IPv4Address $TARGET_IP
Write-Host "Registro A: $DOMAIN -> $TARGET_IP"

$recWWW = Get-DnsServerResourceRecord -ZoneName $DOMAIN -Name "www" -RRType A -ErrorAction SilentlyContinue
if ($null -ne $recWWW) {
    Remove-DnsServerResourceRecord -ZoneName $DOMAIN -Name "www" -RRType A -Force -ErrorAction SilentlyContinue
}
Add-DnsServerResourceRecordA -ZoneName $DOMAIN -Name "www" -IPv4Address $TARGET_IP
Write-Host "Registro A: www.$DOMAIN -> $TARGET_IP"

$recNS = Get-DnsServerResourceRecord -ZoneName $DOMAIN -Name "ns" -RRType A -ErrorAction SilentlyContinue
if ($null -ne $recNS) {
    Remove-DnsServerResourceRecord -ZoneName $DOMAIN -Name "ns" -RRType A -Force -ErrorAction SilentlyContinue
}
Add-DnsServerResourceRecordA -ZoneName $DOMAIN -Name "ns" -IPv4Address $currentIP
Write-Host "Registro A: ns.$DOMAIN -> $currentIP"

Set-Service  -Name DNS -StartupType Automatic
Restart-Service -Name DNS
Start-Sleep -Seconds 2

$svc = Get-Service -Name DNS
if ($svc.Status -eq "Running") {
    Write-Host "El servicio DNS esta activo"
} else {
    Write-Host "El servicio DNS no inicio"
    exit 1
}

Write-Host ""
Write-Host "--- nslookup $DOMAIN ---"
nslookup $DOMAIN 127.0.0.1

Write-Host ""
Write-Host "--- nslookup www.$DOMAIN ---"
nslookup "www.$DOMAIN" 127.0.0.1

Write-Host " $DOMAIN      -> $TARGET_IP"
Write-Host " www.$DOMAIN  -> $TARGET_IP"
Write-Host " ns.$DOMAIN   -> $currentIP"