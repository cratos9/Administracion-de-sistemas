$feature = Get-WindowsFeature -Name DHCP

if ($feature.Installed){
	Write-Host "El paquete ya estaba instalado"
} else {
	Write-Host "Instalando paquete"
	Install-WindowsFeature -Name DHCP -IncludeManagementTools
}

$scopeName = Read-Host "Nombre: "
$startIP = Read-Host "IP inicial: "
$endIP = Read-Host "IP final: "
$gateway = Read-Host "Gateway: "
$dns = Read-Host "DNS: "
$scopeId = "192.168.100.0"

Add-DhcpServerv4Scope `
	-Name $scopeName `
	-StartRange $startIP `
	-EndRange $endIP `
	-SubnetMask 255.255.255.0 `
	-ErrorAction SilentlyContinue

Set-DhcpServerv4OptionValue `
	-ScopeId $scopeId `
	-Router $gateway `
	-DnsServer $dns `
	-Force

Get-Service -Name DHCPServer
Get-DhcpServerv4Lease -ScopeId $scopeId
