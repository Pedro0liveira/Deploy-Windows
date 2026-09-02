#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-DeployConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "config.json não encontrado: $Path" }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { throw "config.json inválido: $($_.Exception.Message)" }
}

$script:DeployRoot = Split-Path -Parent (Resolve-Path -LiteralPath $ConfigPath)
$script:Config = Read-DeployConfig -Path $ConfigPath
$logDirectory = Split-Path -Parent $script:Config.logging.arquivo
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$stateDirectory = Split-Path -Parent $script:Config.deployment.stateFile
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null

$script:DeployContext = [ordered]@{
    Serial = $null; Hostname = $env:COMPUTERNAME; TargetHostname = $null
    Unit = $script:Config.empresa.unidade; Domain = $script:Config.dominio.fqdn
    DomainController = $script:Config.dominio.controlador; Applications = @()
}

function Write-DeployLog {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][ValidateSet('INFO','SUCCESS','ERROR','WARNING')][string]$Result,
        [string]$Message = ''
    )
    if (-not $script:Config.logging.habilitado) { return }
    $loggedHostname = $script:DeployContext.TargetHostname
    if ([string]::IsNullOrWhiteSpace($loggedHostname)) { $loggedHostname = $env:COMPUTERNAME }
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o'); stage = $Stage; operation = $Operation; result = $Result
        message = $Message; hostname = $loggedHostname
        serial = $script:DeployContext.Serial; unidade = $script:DeployContext.Unit
        dominio = $script:DeployContext.Domain; controlador = $script:DeployContext.DomainController
    }
    $entry | ConvertTo-Json -Compress -Depth 4 | Add-Content -LiteralPath $script:Config.logging.arquivo -Encoding utf8
}

function Set-DeploymentState {
    param([Parameter(Mandatory)][string]$Stage)
    [ordered]@{ stage = $Stage; updatedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $script:Config.deployment.stateFile -Encoding utf8
    Write-DeployLog -Stage 'Orchestrator' -Operation 'Set state' -Result INFO -Message $Stage
}

function Get-DeploymentState {
    if (-not (Test-Path -LiteralPath $script:Config.deployment.stateFile)) { return 'Start' }
    try { return ((Get-Content -LiteralPath $script:Config.deployment.stateFile -Raw | ConvertFrom-Json).stage) }
    catch { throw "Arquivo de estado inválido: $($_.Exception.Message)" }
}

function Register-DeploymentResume {
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:DeployRoot 'Deploy.ps1')
    New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'EmpresaDeployResume' -Value $command -PropertyType String -Force | Out-Null
    Write-DeployLog -Stage 'Orchestrator' -Operation 'Register resume' -Result SUCCESS -Message 'Retomada registrada para o próximo logon administrativo.'
}

function Invoke-Checkpoint {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Summary)
    Write-DeployLog -Stage 'Checkpoint' -Operation $Name -Result INFO -Message $Summary
    if ($script:Config.deployment.mode -eq 'validation' -and $script:Config.deployment.pauseAtCheckpoints) {
        Write-Host "`nCHECKPOINT — $Name" -ForegroundColor Cyan
        Write-Host $Summary
        Read-Host 'Revise os dados e pressione ENTER para continuar' | Out-Null
    }
}

. (Join-Path $script:DeployRoot 'Scripts\Computer.ps1')
. (Join-Path $script:DeployRoot 'Scripts\Network.ps1')
. (Join-Path $script:DeployRoot 'Scripts\Software.ps1')
. (Join-Path $script:DeployRoot 'Scripts\Validation.ps1')
. (Join-Path $script:DeployRoot 'Scripts\Domain.ps1')

try {
    $state = Get-DeploymentState
    Write-DeployLog -Stage 'Orchestrator' -Operation 'Start' -Result INFO -Message "Estado atual: $state"

    switch ($state) {
        'Start' {
            Get-ComputerIdentity
            Invoke-Checkpoint -Name 'Identificação' -Summary "Serial: $($script:DeployContext.Serial) | Unidade: $($script:DeployContext.Unit) | Nome calculado: $($script:DeployContext.TargetHostname)"
            Invoke-NetworkStep
            Invoke-Checkpoint -Name 'Rede' -Summary "Interface: $($script:Config.rede.interface) | DHCP, 802.1X, DNS e DC validados."
            Set-DeploymentState -Stage 'AfterHostnameReboot'
            Register-DeploymentResume
            Set-ComputerHostname
            Write-DeployLog -Stage 'Computer' -Operation 'Restart for hostname' -Result INFO -Message 'Reinicializando antes de continuar com aplicativos e AD.'
            Restart-Computer -Force
            return
        }
        'AfterHostnameReboot' {
            Assert-ComputerHostname
            Invoke-SoftwareStep
            Invoke-Checkpoint -Name 'Aplicativos' -Summary "Instaladores processados: $($script:DeployContext.Applications -join ', ')"
            Invoke-PreDomainValidation
            Invoke-Checkpoint -Name 'Pré-AD' -Summary "Hostname, rede, DNS, DC e aplicativos aprovados."
            Set-DeploymentState -Stage 'AfterDomainJoinReboot'
            Register-DeploymentResume
            Join-ConfiguredDomain
            throw 'O ingresso no domínio retornou sem solicitar reinicialização.'
        }
        'AfterDomainJoinReboot' {
            Invoke-PostDomainValidation
            Invoke-Checkpoint -Name 'AD' -Summary "Domínio, DC, DNS, Netlogon e Secure Channel aprovados."
            Set-DeploymentState -Stage 'Completed'
            Write-DeployLog -Stage 'Orchestrator' -Operation 'Finish' -Result SUCCESS -Message 'Deploy concluído. A movimentação para a OU final é manual.'
            Write-Host 'Deploy concluído. Mova a máquina para a OU final manualmente.' -ForegroundColor Green
        }
        'Completed' { Write-DeployLog -Stage 'Orchestrator' -Operation 'Start' -Result INFO -Message 'Deploy já concluído; nenhuma ação executada.' }
        default { throw "Estado de deployment não reconhecido: $state" }
    }
}
catch {
    Write-DeployLog -Stage 'Orchestrator' -Operation 'Failure' -Result ERROR -Message $_.Exception.Message
    Write-Error "DEPLOY INTERROMPIDO: $($_.Exception.Message)"
    exit 1
}
