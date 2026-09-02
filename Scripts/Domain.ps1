function Join-ConfiguredDomain {
    $domain = $script:Config.dominio
    if ($domain.credenciais.modo -ne 'prompt') { throw "Modo de credencial não suportado nesta V1: $($domain.credenciais.modo)" }
    $credential = Get-Credential -UserName $domain.credenciais.usuarioPadrao -Message "Informe uma conta autorizada a ingressar computadores em $($domain.fqdn)."
    if (-not $credential) { throw 'Credenciais de AD não foram informadas.' }
    Write-DeployLog -Stage 'Domain' -Operation 'Join start' -Result INFO -Message "Iniciando Add-Computer em $($domain.fqdn)."
    Add-Computer -DomainName $domain.fqdn -Credential $credential -Force -Restart
}
