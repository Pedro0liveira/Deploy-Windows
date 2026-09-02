function Invoke-PreDomainValidation {
    Assert-ComputerHostname
    $adapter = Get-NetAdapter -Name $script:Config.rede.interface -ErrorAction Stop
    if ($adapter.Status -ne 'Up') { throw 'Falha na validação pré-AD: Ethernet sem link.' }
    $dns = Get-DnsClientServerAddress -InterfaceAlias $script:Config.rede.interface -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses
    if (-not $dns) { throw 'Falha na validação pré-AD: DNS indisponível.' }
    Resolve-DnsName -Name $script:Config.dominio.fqdn -ErrorAction Stop | Out-Null
    & nltest.exe "/dsgetdc:$($script:Config.dominio.fqdn)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Falha na validação pré-AD: DC não localizado.' }
    if (-not (Test-NetConnection -ComputerName $script:Config.dominio.controlador -Port 389 -InformationLevel Quiet)) { throw 'Falha na validação pré-AD: LDAP do DC configurado inacessível.' }
    Write-DeployLog -Stage 'Validation' -Operation 'Pre-AD' -Result SUCCESS -Message 'Hostname, Ethernet, DNS e DC aprovados.'
}

function Invoke-PostDomainValidation {
    $system = Get-CimInstance Win32_ComputerSystem
    if (-not $system.PartOfDomain -or $system.Domain -ine $script:Config.dominio.fqdn) { throw "A máquina não pertence ao domínio esperado: $($script:Config.dominio.fqdn)" }
    & nltest.exe "/dsgetdc:$($script:Config.dominio.fqdn)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'DC não localizado após Join AD.' }
    Resolve-DnsName -Name $script:Config.dominio.fqdn -ErrorAction Stop | Out-Null
    if (-not (Test-NetConnection -ComputerName $script:Config.dominio.controlador -Port 389 -InformationLevel Quiet)) { throw 'LDAP do DC configurado inacessível após Join AD.' }
    $netlogon = Get-Service -Name Netlogon
    if ($netlogon.Status -ne 'Running') { throw "Netlogon não está em execução: $($netlogon.Status)" }
    & nltest.exe "/sc_query:$($script:Config.dominio.fqdn)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Secure Channel não confiável.' }
    Write-DeployLog -Stage 'Validation' -Operation 'Post-AD' -Result SUCCESS -Message 'Domínio, DC, DNS, Netlogon e Secure Channel aprovados.'
}
