function Invoke-SoftwareStep {
    foreach ($application in $script:Config.aplicativos) {
        $installer = Join-Path (Join-Path $script:DeployRoot 'Temp') $application.arquivo
        if (-not (Test-Path -LiteralPath $installer)) { throw "Instalador não encontrado: $installer" }
        $arguments = @($application.argumentos | ForEach-Object { [string]$_ })
        Write-DeployLog -Stage 'Software' -Operation 'Start installer' -Result INFO -Message $application.arquivo
        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
        if ($application.codigosSaidaEsperados -notcontains $process.ExitCode) {
            throw "Instalador $($application.arquivo) retornou $($process.ExitCode); esperados: $($application.codigosSaidaEsperados -join ', ')."
        }
        if ($application.validacao.tipo -eq 'file') {
            if (-not (Test-Path -LiteralPath $application.validacao.caminho)) { throw "Validação do aplicativo falhou: $($application.validacao.caminho)" }
        }
        $script:DeployContext.Applications += $application.arquivo
        Write-DeployLog -Stage 'Software' -Operation 'Install' -Result SUCCESS -Message "$($application.arquivo), exit code $($process.ExitCode)"
    }
}
