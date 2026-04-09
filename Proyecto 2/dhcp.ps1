$SCOPE_ID = "192.168.100.0"

function Instalar-DHCP{
	$feature = Get-WindowsFeature -Name DHCP

	if ($feature.Installed){
		Log "DHCP ya estaba instalado"
	} else {
		Log "Instalando DHCP"
		Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
		Log "DHCP instalado"
	}
}

function Configurar-DHCP {
	$scopeName = Read-Host "Nombre: "
	$startIP   = Leer-IP "IP inicial: "
	$endIP     = Leer-IP "IP final: "
	$gateway   = Leer-IP "Gateway: "
	$dns       = Leer-IP "DNS: "

	$existing = Get-DhcpServerv4Scope -ScopeId $SCOPE_ID -ErrorAction SilentlyContinue
	if ($null -ne $existing){
		Log "El scope ya existe"
	} else {
		Add-DhcpServerv4Scope `
			-Name $scopeName `
			-StartRange $startIP `
			-EndRange $endIP `
			-SubnetMask 255.255.255.0 `
			-ErrorAction SilentlyContinue
		Log "Scope creado"
	}

	Set-DhcpServerv4OptionValue `
		-ScopeId $SCOPE_IP `
		-Router $gateway `
		-DnsServer $dns `
		-Force
	Log "Opciones del scope configuradas"
	Set-Service -Name DHCPServer -StartupType Automatic
	Restart-Service -Name DHCPServer
	Log "Servicio reiniciado"
}

function Ver-Leases {
	Log "Leases activos:"
	Get-DhcpServerv4Lease -ScopeId $SCOPE_IP -ErrorAction SilentlyContinue
}

function Configurar-DHCP-Completo{
	Instalar-DHCP
	Configurar-DHCP
	Ver-Leases
}
