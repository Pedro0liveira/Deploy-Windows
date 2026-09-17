function Invoke-PreDomainValidation {
    Assert-ComputerHostname
    Invoke-NetworkStep
    foreach ($application in $script:Config.aplicativos) {
        if (-not (Test-Path -LiteralPath $application.validacao.caminho -PathType Leaf)) { throw "Aplicativo não detectado: $($application.arquivo)" }
    }
    Write-DeployLog 'Validation' 'Pre-AD' SUCCESS 'Hostname, rede, DNS, DC e aplicativos aprovados.'
}

function Invoke-PostDomainValidation {
    Assert-ComputerHostname
    $system = Get-CimInstance Win32_ComputerSystem
    if (-not $system.PartOfDomain -or $system.Domain -ine $script:Config.dominio.fqdn) { throw "Computador não pertence ao domínio esperado: $($script:Config.dominio.fqdn)" }
    Invoke-NetworkStep
    Wait-DeployCondition 'Netlogon/canal seguro' {
        if ((Get-Service Netlogon).Status -ne 'Running') { throw 'Netlogon ainda não iniciou.' }
        if (-not (Test-ComputerSecureChannel -Server $script:Config.dominio.controlador -ErrorAction Stop)) { throw 'Canal seguro não confiável.' }
    }
    Write-DeployLog 'Validation' 'Post-AD' SUCCESS 'Domínio, DC, DNS, Netlogon e canal seguro aprovados.'
}
