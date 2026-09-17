function Join-ConfiguredDomain {
    $domain = $script:Config.dominio
    $system = Get-CimInstance Win32_ComputerSystem
    if ($system.PartOfDomain) {
        if ($system.Domain -ine $domain.fqdn) { throw "Computador já pertence a outro domínio: $($system.Domain)" }
        Write-DeployLog 'Domain' 'Join' INFO 'Associação já existente; reconciliando retomada e reinicialização.'
        return
    }
    $credential = Get-Credential -UserName $domain.credenciais.usuarioPadrao -Message "Conta autorizada a ingressar computadores em $($domain.fqdn)"
    if (-not $credential) { throw 'Credenciais de AD não informadas; ingresso permanece pendente.' }
    $result = Add-Computer -DomainName $domain.fqdn -Server $domain.controlador -Credential $credential -Force -PassThru -ErrorAction Stop
    if (-not $result.HasSucceeded) { throw 'Add-Computer não confirmou sucesso.' }
    Write-DeployLog 'Domain' 'Join' SUCCESS 'Ingresso confirmado; reboot será coordenado pelo orquestrador.'
}
