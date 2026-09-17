function Get-ComputerIdentity {
    $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
    if ($script:Config.computador.validarSerial) {
        if ([string]::IsNullOrWhiteSpace($serial)) { throw 'Serial da BIOS vazio.' }
        $serial = $serial.Trim().ToUpperInvariant()
        if ($script:Config.computador.serialsInvalidos -contains $serial) { throw "Serial inválido ou genérico: $serial" }
    }
    $normalizedSerial = ($serial -replace '[^A-Za-z0-9-]', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedSerial)) { throw 'Serial ficou vazio após normalização.' }
    $name = $script:Config.computador.nomePattern.Replace('{UNIDADE}', $script:Config.empresa.unidade).Replace('{SERIAL}', $normalizedSerial).ToUpperInvariant()
    if ($name.Length -gt 15 -or $name -notmatch '^[A-Z0-9][A-Z0-9-]{0,14}$' -or $name.EndsWith('-')) {
        throw "Hostname inválido para NetBIOS: $name"
    }
    $script:DeployContext.Serial = $normalizedSerial
    $script:DeployContext.TargetHostname = $name
    Write-DeployLog -Stage 'Computer' -Operation 'Identify' -Result SUCCESS -Message "Serial $normalizedSerial; hostname calculado $name"
}

function Set-ComputerHostname {
    if (-not $script:DeployContext.TargetHostname) { Get-ComputerIdentity }
    if ($env:COMPUTERNAME -ieq $script:DeployContext.TargetHostname) {
        Write-DeployLog -Stage 'Computer' -Operation 'Rename' -Result INFO -Message 'Hostname já aplicado.'
        return
    }
    $system = Get-CimInstance Win32_ComputerSystem
    if ($system.PartOfDomain) { throw 'Rename de computador já no domínio exige reconciliação manual.' }
    Rename-Computer -NewName $script:DeployContext.TargetHostname -Force -ErrorAction Stop
    Write-DeployLog -Stage 'Computer' -Operation 'Rename' -Result SUCCESS -Message "Hostname pendente de reinicialização: $($script:DeployContext.TargetHostname)"
}

function Assert-ComputerHostname {
    Get-ComputerIdentity
    if ($env:COMPUTERNAME -ine $script:DeployContext.TargetHostname) {
        throw "Hostname aplicado incorretamente. Atual: $env:COMPUTERNAME; esperado: $($script:DeployContext.TargetHostname)"
    }
    Write-DeployLog -Stage 'Computer' -Operation 'Validate hostname' -Result SUCCESS -Message $env:COMPUTERNAME
}
