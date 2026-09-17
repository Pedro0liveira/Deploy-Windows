#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
$transcribing = $false
$result = 1
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.User.Value -eq 'S-1-5-18') { throw 'Abra PowerShell como administrador na sessão interativa e execute Bootstrap.ps1 novamente.' }
    $logDirectory = Join-Path $env:ProgramData 'Deploy'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    Start-Transcript -Path (Join-Path $logDirectory 'bootstrap.log') -Append | Out-Null
    $transcribing = $true
    . (Join-Path $PSScriptRoot 'Scripts\Preflight.ps1')
    Assert-PackageManifest $PSScriptRoot
    Assert-PowerShellFiles $PSScriptRoot
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Deploy.ps1') -ConfigPath $ConfigPath
    $result = $LASTEXITCODE
    if ($result -ne 0) { throw "Deploy retornou código $result. Consulte deploy.log e preserve state.json." }
} catch {
    $result = 1
    Write-Host "DEPLOY INTERROMPIDO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Corrija a causa, reconstrua/recopie o pacote se necessário e execute Bootstrap.ps1 como administrador. Não apague state.json sem reconciliar a máquina.'
    if ([Environment]::UserInteractive) { Read-Host 'Pressione ENTER para fechar' | Out-Null }
} finally { if ($transcribing) { Stop-Transcript | Out-Null } }
exit $result
