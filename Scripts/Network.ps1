function Assert-CommandSuccess {
    param([string]$CommandName, [string[]]$Arguments)
    $output = & $CommandName @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "$CommandName falhou ($LASTEXITCODE): $output" }
    return $output
}

function Invoke-NetworkStep {
    $network = $script:Config.rede
    $adapter = Get-NetAdapter -Name $network.interface -ErrorAction Stop
    if ($adapter.Status -ne 'Up') { throw "Interface $($network.interface) sem link ativo (Status: $($adapter.Status))." }
    Write-DeployLog -Stage 'Network' -Operation 'Adapter/link' -Result SUCCESS -Message $adapter.InterfaceDescription

    if ($network.usarDhcp) {
        Set-NetIPInterface -InterfaceAlias $network.interface -AddressFamily IPv4 -Dhcp Enabled
        Assert-CommandSuccess -CommandName 'ipconfig.exe' -Arguments @('/renew', $network.interface) | Out-Null
        Write-DeployLog -Stage 'Network' -Operation 'DHCP renew' -Result SUCCESS
    }

    $profilePath = Join-Path $script:DeployRoot $network.perfil8021x
    if (-not (Test-Path -LiteralPath $profilePath)) { throw "Perfil 802.1X ausente: $profilePath" }
    $profileContent = Get-Content -LiteralPath $profilePath -Raw
    if ($profileContent -match 'EXPORTAR_PERFIL_REAL') { throw 'LAN.xml ainda é o marcador seguro. Exporte o perfil da máquina de referência antes do uso.' }
    if ($profileContent -notmatch [regex]::Escape($network.authMode) -or $profileContent -notmatch [regex]::Escape($network.ssoMode)) {
        throw 'LAN.xml não contém os valores authMode/ssoMode definidos no config.json.'
    }
    Assert-CommandSuccess -CommandName 'netsh.exe' -Arguments @('lan', 'add', 'profile', "filename=$profilePath", "interface=$($network.interface)") | Out-Null
    $authenticated = $false
    $lanStatus = ''
    for ($attempt = 1; $attempt -le 12 -and -not $authenticated; $attempt++) {
        $lanStatus = Assert-CommandSuccess -CommandName 'netsh.exe' -Arguments @('lan', 'show', 'interfaces', "interface=$($network.interface)")
        foreach ($pattern in $network.authenticationSuccessPatterns) {
            if ($lanStatus -match $pattern) { $authenticated = $true; break }
        }
        if (-not $authenticated) { Start-Sleep -Seconds 5 }
    }
    if (-not $authenticated) { throw "802.1X não autenticado. Saída netsh: $lanStatus" }
    Write-DeployLog -Stage 'Network' -Operation '802.1X' -Result SUCCESS -Message 'Perfil importado e autenticação confirmada.'

    $ip = Get-NetIPAddress -InterfaceAlias $network.interface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    $route = Get-NetRoute -InterfaceAlias $network.interface -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
    $dns = Get-DnsClientServerAddress -InterfaceAlias $network.interface -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses
    if (-not $ip) { throw 'Nenhum IPv4 válido obtido por DHCP.' }
    if (-not $route) { throw 'Gateway padrão indisponível.' }
    if (-not $dns) { throw 'DNS indisponível; o script não altera DNS manualmente.' }
    Resolve-DnsName -Name $script:Config.dominio.fqdn -ErrorAction Stop | Out-Null
    $dcOutput = Assert-CommandSuccess -CommandName 'nltest.exe' -Arguments @("/dsgetdc:$($script:Config.dominio.fqdn)")
    Resolve-DnsName -Name $script:Config.dominio.controlador -ErrorAction Stop | Out-Null
    if (-not (Test-NetConnection -ComputerName $script:Config.dominio.controlador -Port 389 -InformationLevel Quiet)) { throw "DC configurado sem LDAP acessível: $($script:Config.dominio.controlador)" }
    Write-DeployLog -Stage 'Network' -Operation 'IP/Gateway/DNS/DC' -Result SUCCESS -Message "IP $($ip.IPAddress); gateway $($route.NextHop); DNS $($dns -join ', '); $dcOutput"
}
