#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DeployRoot = $PSScriptRoot
$lock = $null
$exitCode = 0
try {
    $lockDirectory = Join-Path $env:ProgramData 'Deploy'
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
    $lock = [IO.File]::Open((Join-Path $lockDirectory 'deploy.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    foreach ($name in @('Preflight','Runtime','Computer','Network','Software','Validation','Domain','Orchestrator')) { . (Join-Path $script:DeployRoot "Scripts\$name.ps1") }
    $script:ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    if ($script:ConfigPath -match '["\r\n]') { throw 'Caminho de configuração inválido.' }
    $script:Config = Read-DeployConfig $script:ConfigPath
    Assert-DeployConfig $script:Config $script:DeployRoot
    Assert-PowerShellFiles $script:DeployRoot
    if ($env:SystemDrive -ine 'C:') { throw 'O pacote usa C:\Deploy; instalação em outra letra exige um pacote adaptado.' }
    $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
    if ($edition -like 'Core*') { throw 'Windows Home não ingressa no AD. Selecione uma edição compatível na ISO.' }
    foreach ($path in @($script:Config.logging.arquivo,$script:Config.deployment.stateFile)) { New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null }
    $script:DeployContext = [ordered]@{ Serial=''; TargetHostname=''; Applications=@() }
    Get-ComputerIdentity
    Initialize-DeploymentState
    if ($script:State.stage -ne 'Completed') { Register-DeploymentResume }
    Invoke-Deployment
} catch {
    $exitCode = 1
    $message = $_.Exception.Message
    [Console]::Error.WriteLine("DEPLOY INTERROMPIDO: $message")
    try { if (Get-Variable Config -Scope Script -ErrorAction SilentlyContinue) { Write-DeployLog 'Orchestrator' 'Failure' ERROR $message } }
    catch { [Console]::Error.WriteLine('Não foi possível gravar o log estruturado; consulte bootstrap.log.') }
} finally { if ($null -ne $lock) { $lock.Dispose() } }
exit $exitCode
