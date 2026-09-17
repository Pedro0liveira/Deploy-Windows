function Write-DeployLog {
    param([string]$Stage, [string]$Operation, [ValidateSet('INFO','SUCCESS','ERROR','WARNING')][string]$Result, [string]$Message = '')
    if (-not $script:Config.logging.habilitado) { return }
    [ordered]@{ timestamp=(Get-Date).ToString('o'); stage=$Stage; operation=$Operation; result=$Result; message=$Message; hostname=$script:DeployContext.TargetHostname; serial=$script:DeployContext.Serial; dominio=$script:Config.dominio.fqdn } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $script:Config.logging.arquivo -Encoding UTF8
}

function Save-DeploymentState {
    $path = $script:Config.deployment.stateFile
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $script:State.updatedAt = (Get-Date).ToString('o')
    $script:State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $path) }
}

function Set-DeploymentState {
    param([string]$Stage)
    $script:State.stage = $Stage
    Save-DeploymentState
    Write-DeployLog 'Orchestrator' 'State' INFO $Stage
}

function Initialize-DeploymentState {
    $path = $script:Config.deployment.stateFile
    if (Test-Path -LiteralPath $path) {
        $script:State = Read-DeployConfig $path
        Assert-RequiredProperties $script:State @('version','stage','serial','targetHostname','domain','configPath','applications','rebootFrom','updatedAt') 'state'
        if ($script:State.version -ne 2) { throw 'Estado legado: preserve o arquivo e reconcilie hostname/domínio antes de iniciar um novo deploy.' }
        if ($script:State.serial -ine $script:DeployContext.Serial -or $script:State.targetHostname -ine $script:DeployContext.TargetHostname -or $script:State.domain -ine $script:Config.dominio.fqdn -or $script:State.configPath -ine $script:ConfigPath) { throw 'Estado pertence a outra identidade/configuração. Não será sobrescrito.' }
    } else {
        $script:State = [pscustomobject]@{ version=2; stage='Start'; serial=$script:DeployContext.Serial; targetHostname=$script:DeployContext.TargetHostname; domain=$script:Config.dominio.fqdn; configPath=$script:ConfigPath; applications=@(); rebootFrom=''; updatedAt='' }
        Save-DeploymentState
    }
}

function Register-DeploymentResume {
    # SID permanece estável quando o computador é renomeado. Nunca usar SYSTEM.
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($sid -eq 'S-1-5-18') { throw 'Execute com administrador interativo, não como SYSTEM.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f (Join-Path $script:DeployRoot 'Bootstrap.ps1'), $script:ConfigPath
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments -WorkingDirectory $script:DeployRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'EmpresaDeployResume' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'EmpresaDeployResume' -ErrorAction SilentlyContinue
    Write-DeployLog 'Orchestrator' 'Resume' SUCCESS "Retomada no próximo logon da mesma conta administrativa ($sid)."
}

function Remove-DeploymentResume {
    $task = Get-ScheduledTask -TaskName 'EmpresaDeployResume' -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName 'EmpresaDeployResume' -Confirm:$false }
}

function Invoke-Checkpoint {
    param([string]$Name,[string]$Summary)
    Write-DeployLog 'Checkpoint' $Name INFO $Summary
    if ($script:Config.deployment.mode -eq 'validation' -and $script:Config.deployment.pauseAtCheckpoints) {
        Write-Host "`nCHECKPOINT - $Name" -ForegroundColor Cyan
        Write-Host $Summary
        Read-Host 'Revise os dados e pressione ENTER para continuar' | Out-Null
    }
}

function Get-BootMarker { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }

function Request-DeploymentReboot {
    param([string]$NextStage)
    $script:State.rebootFrom = Get-BootMarker
    Set-DeploymentState $NextStage
    Write-DeployLog 'Orchestrator' 'Reboot' INFO 'Entre novamente com a mesma conta administrativa local.'
    Restart-Computer -Force -ErrorAction Stop
}
