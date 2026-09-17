function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Regras CommandLineToArgvW: preservar espaços, aspas e barras finais.
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Assert-CommandSuccess {
    param([string]$CommandName, [string[]]$Arguments, [int]$TimeoutSeconds = 60)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $CommandName
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Console]::OutputEncoding
    $info.StandardErrorEncoding = [Console]::OutputEncoding
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); throw "$CommandName excedeu ${TimeoutSeconds}s." }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$CommandName falhou ($($process.ExitCode)): $output" }
        return $output
    } finally { $process.Dispose() }
}

function Wait-DeployCondition {
    param([string]$Description, [scriptblock]$Action)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastError = ''
    do {
        try { & $Action; return } catch { $lastError = $_.Exception.Message }
        if ($watch.Elapsed.TotalSeconds -ge $script:Config.rede.timeoutSeconds) { break }
        Start-Sleep -Seconds 3
    } while ($true)
    throw "$Description não ficou disponível. Última falha: $lastError"
}

function Test-LanAuthentication {
    param([string]$Output, [string]$InterfaceName, [string]$InterfaceGuid, [string[]]$Patterns)
    # Somente o bloco da interface exata. Não aceitar sucesso de outro adaptador.
    $blocks = [regex]::Matches($Output, '(?ims)^\s*(?:Name|Nome)\s*:\s*(?<name>[^\r\n]+)\r?\n(?<body>.*?)(?=^\s*(?:Name|Nome)\s*:|\z)')
    foreach ($block in $blocks) {
        if ($block.Groups['name'].Value.Trim() -ine $InterfaceName) { continue }
        $body = $block.Groups['body'].Value
        $guidMatch = [regex]::Match($body, '(?im)^\s*GUID\s*:\s*\{?(?<id>[0-9a-f-]{36})\}?\s*$')
        if (-not $guidMatch.Success -or [guid]$guidMatch.Groups['id'].Value -ne [guid]$InterfaceGuid) { return $false }
        foreach ($pattern in $Patterns) { if ([regex]::IsMatch($body, $pattern)) { return $true } }
    }
    return $false
}

function Assert-NetworkAddress {
    $alias = $script:Config.rede.interface
    $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(169\.254\.|127\.|0\.)' } | Select-Object -First 1
    $route = Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Select-Object -First 1
    $dns = @(Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses)
    if (-not $ip -or -not $route -or $dns.Count -eq 0) { throw 'IPv4 utilizável, gateway ou DNS indisponível.' }
}

function Assert-DomainReachable {
    Resolve-DnsName -Name ("_ldap._tcp.dc._msdcs." + $script:Config.dominio.fqdn) -Type SRV -ErrorAction Stop | Out-Null
    Resolve-DnsName -Name $script:Config.dominio.controlador -ErrorAction Stop | Out-Null
    Assert-CommandSuccess 'nltest.exe' @("/dsgetdc:$($script:Config.dominio.fqdn)") | Out-Null
    if (-not (Test-NetConnection -ComputerName $script:Config.dominio.controlador -Port 389 -InformationLevel Quiet)) { throw 'LDAP do DC configurado indisponível.' }
}

function Invoke-NetworkStep {
    $network = $script:Config.rede
    Wait-DeployCondition 'Link da interface' {
        $adapter = Get-NetAdapter -Name $network.interface -ErrorAction Stop
        if ($adapter.Status -ne 'Up') { throw "Interface $($network.interface) sem link." }
    }
    $adapter = Get-NetAdapter -Name $network.interface -ErrorAction Stop
    if ($network.mode -eq '8021x') {
        Set-Service -Name dot3svc -StartupType Automatic -ErrorAction Stop
        Start-Service -Name dot3svc -ErrorAction Stop
        (Get-Service dot3svc).WaitForStatus('Running', [TimeSpan]::FromSeconds($network.timeoutSeconds))
        $profilePath = Resolve-PayloadPath $script:DeployRoot $network.perfil8021x
        Assert-CommandSuccess 'netsh.exe' @('lan','set','autoconfig','enabled=yes',"interface=$($network.interface)") | Out-Null
        Assert-CommandSuccess 'netsh.exe' @('lan','add','profile',"filename=$profilePath", "interface=$($network.interface)") | Out-Null
        Assert-CommandSuccess 'netsh.exe' @('lan','reconnect',"interface=$($network.interface)") | Out-Null
        Wait-DeployCondition 'Autenticação 802.1X' {
            $status = Assert-CommandSuccess 'netsh.exe' @('lan','show','interfaces')
            if (-not (Test-LanAuthentication $status $network.interface $adapter.InterfaceGuid $network.authenticationSuccessPatterns)) { throw "802.1X não confirmado na interface alvo. Saída netsh: $status" }
        }
        Write-DeployLog 'Network' '802.1X' SUCCESS 'Autenticação confirmada na interface alvo.'
    } else { Write-DeployLog 'Network' 'Preparation' INFO 'Rede de preparação selecionada explicitamente; não exige 802.1X.' }
    # DHCP somente depois de autenticar, para não bloquear a importação do perfil.
    if ($network.usarDhcp) {
        Set-NetIPInterface -InterfaceAlias $network.interface -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
        Wait-DeployCondition 'DHCP' { Assert-CommandSuccess 'ipconfig.exe' @('/renew',$network.interface) | Out-Null; Assert-NetworkAddress }
    } else { Wait-DeployCondition 'Endereço de rede' { Assert-NetworkAddress } }
    Wait-DeployCondition 'DNS/DC' { Assert-DomainReachable }
    Write-DeployLog 'Network' 'Ready' SUCCESS 'Link, endereço, rota, DNS e DC aprovados.'
}
