function Wait-InstallerProcess {
    param($Process, [int]$TimeoutSeconds)
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) { throw "Instalador excedeu ${TimeoutSeconds}s (PID $($Process.Id)). Ele NÃO foi encerrado; aguarde e confira antes de retomar." }
    $Process.Refresh()
    return $Process.ExitCode
}

function Invoke-SoftwareStep {
    foreach ($application in $script:Config.aplicativos) {
        $installer = Resolve-PayloadPath $script:DeployRoot ('Temp\' + $application.arquivo)
        $fingerprint = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash + ':' + ($application | ConvertTo-Json -Depth 5 -Compress)
        $records = @($script:State.applications | Where-Object { $_.name -eq $application.arquivo })
        if ($records.Count -gt 1) { throw 'Estado de aplicativo duplicado.' }
        $record = if ($records.Count -eq 1) { $records[0] } else { $null }
        if ($record -and $record.fingerprint -cne $fingerprint) { throw "Pacote/configuração mudou para $($application.arquivo). Reconcilie a instalação antes de continuar." }
        if ($record -and $record.pid) {
            $running = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
            if ($running -and $running.StartTime.ToUniversalTime().ToString('o') -eq $record.startedAt) { throw "Instalador ainda em execução: $($application.arquivo), PID $($record.pid)." }
        }
        if (Test-Path -LiteralPath $application.validacao.caminho -PathType Leaf) {
            if (-not $record) {
                $record = [pscustomobject]@{ name=$application.arquivo; fingerprint=$fingerprint; completed=$true; pid=0; startedAt='' }
                $script:State.applications = @($script:State.applications) + @($record)
            }
            $record.completed = $true; $record.pid = 0
            Save-DeploymentState
            $script:DeployContext.Applications += $application.arquivo
            Write-DeployLog 'Software' 'Detected' SUCCESS $application.arquivo
            continue
        }
        if ($record -and $record.completed) { throw "Detecção de aplicativo concluído falhou: $($application.arquivo). Não será reinstalado silenciosamente." }
        $parameters = @{ FilePath=$installer; PassThru=$true; WorkingDirectory=(Split-Path -Parent $installer); ErrorAction='Stop' }
        if ($application.argumentos.Count -gt 0) { $parameters.ArgumentList = ($application.argumentos | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ' }
        if (-not $record) {
            $record = [pscustomobject]@{ name=$application.arquivo; fingerprint=$fingerprint; completed=$false; pid=0; startedAt='' }
            $script:State.applications = @($script:State.applications) + @($record)
        }
        Save-DeploymentState
        Write-DeployLog 'Software' 'Start' INFO $application.arquivo
        $process = Start-Process @parameters
        $record.pid = $process.Id
        $record.startedAt = $process.StartTime.ToUniversalTime().ToString('o')
        Save-DeploymentState
        try { $code = Wait-InstallerProcess $process $application.timeoutSeconds }
        finally { $process.Dispose() }
        if ($application.codigosSaidaEsperados -notcontains $code) { throw "Instalador $($application.arquivo) retornou $code." }
        if (-not (Test-Path -LiteralPath $application.validacao.caminho -PathType Leaf)) { throw "Detecção pós-instalação falhou: $($application.validacao.caminho)" }
        $record.completed = $true; $record.pid = 0
        if ($code -eq 3010) {
            # Persistir junto com o sucesso do aplicativo, antes de devolver ao orquestrador.
            $script:State.stage = 'SoftwareRebootPending'
            $script:State.rebootFrom = Get-BootMarker
        }
        Save-DeploymentState
        $script:DeployContext.Applications += $application.arquivo
        Write-DeployLog 'Software' 'Install' SUCCESS "$($application.arquivo), código $code"
        if ($code -eq 3010) { return $true }
    }
    return $false
}
