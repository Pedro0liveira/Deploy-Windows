#requires -Version 5.1
[CmdletBinding()]
param([string]$WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('deploy-tests-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Teste com powershell.exe 5.1.' }
$repo = Split-Path -Parent $PSScriptRoot
$script:results = @()
$testRoot = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $testRoot) { throw 'Use pasta de testes nova.' }
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert-True { param($Condition,[string]$Message='Falhou'); if (-not $Condition) { throw $Message } }
function Assert-Throws { param([scriptblock]$Action,[string]$Pattern='*'); try { & $Action } catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }; throw 'Era esperada uma falha.' }
function Test { param([string]$Name,[scriptblock]$Body); try { & $Body; $script:results += [pscustomobject]@{name=$Name;passed=$true;error=''}; Write-Host "PASS $Name" } catch { $script:results += [pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message}; Write-Host "FAIL $Name : $($_.Exception.Message)" } }
function Load-Script { param([string]$Name); . (Join-Path $repo "Scripts\$Name.ps1") }
# Nenhum teste deve executar operações reais de sistema.
function Restart-Computer { throw 'REAL_REBOOT_FORBIDDEN' }
function Rename-Computer { throw 'REAL_RENAME_FORBIDDEN' }
function Add-Computer { throw 'REAL_JOIN_FORBIDDEN' }
function Register-ScheduledTask { throw 'REAL_TASK_FORBIDDEN' }
function Set-Service { throw 'REAL_SERVICE_CHANGE_FORBIDDEN' }
function Set-NetIPInterface { throw 'REAL_NETWORK_CHANGE_FORBIDDEN' }
function Write-DeployLog { }

Test 'Parser 5.1 e UTF-8 BOM de todos os scripts' {
    foreach ($file in Get-ChildItem $repo -Recurse -Filter '*.ps1') {
        $t=$null; $e=$null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e)
        Assert-True ($e.Count -eq 0) "$($file.Name): $($e | Out-String)"
    }
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    Assert-PowerShellFiles $repo
}

Test 'Configuração entregue bloqueia ambiente ainda indefinido' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    $cfg = Read-DeployConfig (Join-Path $repo 'config.json')
    Assert-Throws { Assert-DeployConfig $cfg $repo } '*rede.mode*'
    $cfg.rede.mode = 'preparation'
    Assert-Throws { Assert-DeployConfig $cfg $repo } '*conta real*'
    $cfg.dominio.credenciais.usuarioPadrao = 'LAB\join'
    Assert-Throws { Assert-DeployConfig $cfg $repo } '*FQDN real*'
    $cfg.dominio.controlador = 'dc.lab.local'
    Assert-Throws { Assert-DeployConfig $cfg $repo } '*instalador real*'
    $cfg.aplicativos = @()
    Assert-DeployConfig $cfg $repo
    $cfg.rede.mode = '8021x'
    Assert-Throws { Assert-DeployConfig $cfg $repo } '*LAN.xml*'
}

Test 'Caminhos não escapam do payload' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    Assert-Throws { Resolve-PayloadPath $repo '..\outside.exe' } '*fora do payload*'
    Assert-Throws { Resolve-PayloadPath $repo 'C:\outside.exe' } '*relativo inválido*'
}

Test 'Falha de rename não avança para pós-reboot' {
    . (Join-Path $repo 'Scripts\Orchestrator.ps1')
    $script:State = [pscustomobject]@{stage='Start';rebootFrom=''}
    $script:DeployContext = @{TargetHostname='LAB-123';Serial='123'}
    function Invoke-Checkpoint { }
    function Invoke-NetworkStep { }
    function Set-DeploymentState { param($Stage) $script:State.stage=$Stage }
    function Set-ComputerHostname { throw 'rename failed' }
    function Request-DeploymentReboot { throw 'REBOOT_NOT_EXPECTED' }
    Assert-Throws { Invoke-Deployment } 'rename failed'
    Assert-True ($script:State.stage -eq 'RenamePending')
}

Test 'Cancelamento ou falha de join mantém ingresso pendente' {
    . (Join-Path $repo 'Scripts\Orchestrator.ps1')
    $script:State = [pscustomobject]@{stage='AfterHostnameReboot';rebootFrom=''}
    function Assert-ComputerHostname { }
    function Invoke-NetworkStep { }
    function Invoke-SoftwareStep { return $false }
    function Invoke-PreDomainValidation { }
    function Invoke-Checkpoint { }
    function Set-DeploymentState { param($Stage) $script:State.stage=$Stage }
    function Join-ConfiguredDomain { throw 'join cancelled' }
    function Request-DeploymentReboot { throw 'REBOOT_NOT_EXPECTED' }
    Assert-Throws { Invoke-Deployment } 'join cancelled'
    Assert-True ($script:State.stage -eq 'JoinPending')
}

Test 'Reiniciar é obrigatório antes de validar estágio seguinte' {
    . (Join-Path $repo 'Scripts\Orchestrator.ps1')
    $script:State = [pscustomobject]@{stage='AfterDomainJoinReboot';rebootFrom='boot1'}
    $script:requested = ''
    function Get-BootMarker { 'boot1' }
    function Request-DeploymentReboot { param($NextStage) $script:requested=$NextStage }
    function Invoke-PostDomainValidation { throw 'VALIDATION_TOO_EARLY' }
    Invoke-Deployment
    Assert-True ($script:requested -eq 'AfterDomainJoinReboot')
}

Test 'Fluxo completo só conclui após os dois reboots e validação AD' {
    . (Join-Path $repo 'Scripts\Orchestrator.ps1')
    $script:State=[pscustomobject]@{stage='Start';rebootFrom=''}
    $script:DeployContext=@{TargetHostname='LAB-123';Serial='123'}
    $script:trace=@()
    function Invoke-Checkpoint { }
    function Invoke-NetworkStep { }
    function Set-DeploymentState { param($Stage) $script:State.stage=$Stage }
    function Set-ComputerHostname { $script:trace += 'rename' }
    function Save-DeploymentState { }
    function Get-BootMarker { 'boot-new' }
    function Request-DeploymentReboot { param($NextStage) $script:State.stage=$NextStage; $script:State.rebootFrom='boot-old'; $script:trace += 'reboot' }
    function Assert-ComputerHostname { }
    function Invoke-SoftwareStep { $script:trace += 'apps'; $false }
    function Invoke-PreDomainValidation { }
    function Join-ConfiguredDomain { $script:trace += 'join' }
    function Invoke-PostDomainValidation { $script:trace += 'validate' }
    function Remove-DeploymentResume { $script:trace += 'cleanup' }
    Invoke-Deployment
    Assert-True ($script:State.stage -eq 'AfterHostnameReboot')
    Invoke-Deployment
    Assert-True ($script:State.stage -eq 'AfterDomainJoinReboot')
    Invoke-Deployment
    Assert-True ($script:State.stage -eq 'Completed')
    Assert-True (($script:trace -join ',') -eq 'rename,reboot,apps,join,reboot,validate,cleanup')
}

Test 'Perfil 802.1X é conferido por elementos, não por comentário contendo valores' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    $fixture=Join-Path $testRoot 'profile'
    New-Item -ItemType Directory -Path (Join-Path $fixture 'Network') -Force | Out-Null
    $cfg=Read-DeployConfig (Join-Path $repo 'config.json')
    $cfg.rede.mode='8021x'; $cfg.dominio.credenciais.usuarioPadrao='LAB\join'; $cfg.dominio.controlador='dc.lab.local'; $cfg.aplicativos=@()
    $xml='<LANProfile xmlns="http://www.microsoft.com/networking/LAN/profile/v1"><MSM><security><OneXEnabled>true</OneXEnabled><OneX xmlns="http://www.microsoft.com/networking/OneX/v1"><authMode>machineOrUser</authMode><singleSignOn><type>preLogon</type></singleSignOn></OneX></security></MSM></LANProfile>'
    $path=Join-Path $fixture 'Network\LAN.xml'
    Set-Content $path $xml -Encoding UTF8
    Assert-DeployConfig $cfg $fixture
    Set-Content $path ($xml.Replace('<type>preLogon</type>','<!-- preLogon --><type>postLogon</type>')) -Encoding UTF8
    Assert-Throws { Assert-DeployConfig $cfg $fixture } '*ssoMode*'
}

Test 'Ingresso usa DC configurado e não reinicia dentro de Add-Computer' {
    . (Join-Path $repo 'Scripts\Domain.ps1')
    $script:Config = @{dominio=@{fqdn='lab.local';controlador='dc.lab.local';credenciais=@{usuarioPadrao='LAB\join'}}}
    function Get-CimInstance { @{PartOfDomain=$false} }
    function Get-Credential { 'MOCK' }
    function Add-Computer { param($DomainName,$Server,$Credential,[switch]$Force,[switch]$PassThru,$ErrorAction); Assert-True ($Server -eq 'dc.lab.local'); @{HasSucceeded=$true} }
    Join-ConfiguredDomain
}

Test 'Retomada preserva configuração alternativa e usa principal interativo' {
    . (Join-Path $repo 'Scripts\Runtime.ps1')
    function Write-DeployLog { }
    $script:DeployRoot = 'C:\Deploy'
    $script:ConfigPath = 'C:\Config cliente\cliente.json'
    function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory); Assert-True ($Argument.Contains('"C:\Config cliente\cliente.json"')); 'action' }
    function New-ScheduledTaskTrigger { param([switch]$AtLogOn,$User); Assert-True ($User -match '^S-1-'); 'trigger' }
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); Assert-True ($LogonType -eq 'Interactive' -and $RunLevel -eq 'Highest' -and $UserId -ne 'S-1-5-18'); 'principal' }
    function New-ScheduledTaskSettingsSet { param($MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries); 'settings' }
    function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force); Assert-True ($TaskName -eq 'EmpresaDeployResume') }
    function Remove-ItemProperty { }
    Register-DeploymentResume
}

Test 'Estado é escrito atomicamente e recusa outra máquina/configuração' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    . (Join-Path $repo 'Scripts\Runtime.ps1')
    function Write-DeployLog { }
    $script:Config = @{deployment=@{stateFile=(Join-Path $testRoot 'state.json')};dominio=@{fqdn='lab.local'}}
    $script:ConfigPath = 'C:\Deploy\config.json'
    $script:DeployContext = @{Serial='123';TargetHostname='LAB-123'}
    Initialize-DeploymentState
    Set-DeploymentState 'RenamePending'
    Assert-True ((Read-DeployConfig $script:Config.deployment.stateFile).stage -eq 'RenamePending')
    $script:DeployContext.Serial = '456'
    Assert-Throws { Initialize-DeploymentState } '*outra identidade*'
}

Test 'Autenticação pertence à interface exata, em português e inglês' {
    . (Join-Path $repo 'Scripts\Network.ps1')
    $guid='11111111-1111-1111-1111-111111111111'
    $other='22222222-2222-2222-2222-222222222222'
    $patterns=@('(?im)^\s*(Authentication|Autenticação)\s*:\s*(succeeded|êxito)\s*$')
    $text="Nome : Ethernet`r`nGUID : $guid`r`nAutenticação : falhou`r`n`r`nNome : Ethernet 2`r`nGUID : $other`r`nAutenticação : êxito`r`n"
    Assert-True (-not (Test-LanAuthentication $text 'Ethernet' $guid $patterns))
    Assert-True (Test-LanAuthentication $text 'Ethernet 2' $other $patterns)
    $english="Name : Ethernet`r`nGUID : $guid`r`nAuthentication : succeeded`r`n"
    Assert-True (Test-LanAuthentication $english 'Ethernet' $guid $patterns)
    Assert-True (-not (Test-LanAuthentication $english 'Ethernet' $other $patterns))
}

Test 'Serviço e 802.1X precedem DHCP; show interfaces sem argumento inválido' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    . (Join-Path $repo 'Scripts\Network.ps1')
    $script:DeployRoot=$repo
    $script:Config=@{rede=@{mode='8021x';interface='Ethernet';perfil8021x='Network\LAN.xml';timeoutSeconds=10;usarDhcp=$true;authenticationSuccessPatterns=@('success')}}
    $script:calls = @()
    function Wait-DeployCondition { param($Description,$Action); & $Action }
    function Get-NetAdapter { @{Status='Up';InterfaceGuid='11111111-1111-1111-1111-111111111111'} }
    function Set-Service { $script:calls += 'service' }
    function Start-Service { }
    function Get-Service { $o=New-Object psobject; $o | Add-Member ScriptMethod WaitForStatus {}; $o }
    function Assert-CommandSuccess { param($CommandName,$Arguments); $script:calls += "$CommandName $($Arguments -join ' ')"; if ($Arguments -contains 'show') { Assert-True ($Arguments.Count -eq 3) }; 'mock' }
    function Test-LanAuthentication { $true }
    function Set-NetIPInterface { }
    function Assert-NetworkAddress { }
    function Assert-DomainReachable { }
    Invoke-NetworkStep
    $auth = [array]::IndexOf($script:calls,'netsh.exe lan show interfaces')
    $dhcp = [array]::IndexOf($script:calls,'ipconfig.exe /renew Ethernet')
    Assert-True ($auth -ge 0 -and $dhcp -gt $auth -and $script:calls[0] -eq 'service')
}

Test 'Argumentos nativos preservam espaços, aspas e barras finais' {
    . (Join-Path $repo 'Scripts\Network.ps1')
    Assert-True ((ConvertTo-NativeArgument 'C:\Program Files\App\') -ceq '"C:\Program Files\App\\"')
    Assert-True ((ConvertTo-NativeArgument 'a"b') -ceq '"a\"b"')
    Assert-True ((ConvertTo-NativeArgument '') -ceq '""')
    # Processo somente de leitura, com captura real de stdout e exit code.
    $name = Assert-CommandSuccess "$env:SystemRoot\System32\hostname.exe" @()
    Assert-True (-not [string]::IsNullOrWhiteSpace($name))
}

Test 'Aplicativo sem argumentos e falha parcial retomam sem reinstalar A' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    . (Join-Path $repo 'Scripts\Network.ps1')
    . (Join-Path $repo 'Scripts\Software.ps1')
    $script:DeployRoot=Join-Path $testRoot 'apps'
    New-Item -ItemType Directory -Path (Join-Path $script:DeployRoot 'Temp') -Force | Out-Null
    $apps=@()
    foreach ($name in @('A','B')) {
        Set-Content (Join-Path $script:DeployRoot "Temp\$name.exe") 'MOCK ONLY - NOT EXECUTABLE'
        $apps += [pscustomobject]@{arquivo="$name.exe";argumentos=@();codigosSaidaEsperados=@(0);timeoutSeconds=10;validacao=@{tipo='file';caminho=(Join-Path $script:DeployRoot "$name.installed")}}
    }
    $script:Config=@{aplicativos=$apps}
    $script:State=[pscustomobject]@{applications=@();stage='AfterHostnameReboot';rebootFrom=''}
    $script:DeployContext=@{Applications=@()}
    $script:starts=@(); $script:failB=$true
    function Save-DeploymentState { }
    function Get-Process { $null }
    function Start-Process {
        param($FilePath,$ArgumentList,$WorkingDirectory,[switch]$PassThru,$ErrorAction)
        Assert-True (-not $PSBoundParameters.ContainsKey('ArgumentList')) 'ArgumentList vazio não deve ser passado'
        $name=[IO.Path]::GetFileNameWithoutExtension($FilePath)
        $script:starts += $name
        $code=if ($name -eq 'B' -and $script:failB) { 9 } else { 0 }
        if ($code -eq 0) { Set-Content (Join-Path $script:DeployRoot "$name.installed") 'ok' }
        $p=[pscustomobject]@{Id=999999;StartTime=(Get-Date);MockExitCode=$code}
        $p | Add-Member ScriptMethod Dispose {}
        return $p
    }
    function Wait-InstallerProcess { param($Process,$TimeoutSeconds) return $Process.MockExitCode }
    Assert-Throws { Invoke-SoftwareStep } '*retornou 9*'
    $script:failB=$false
    $reboot=Invoke-SoftwareStep
    Assert-True (-not $reboot)
    Assert-True (($script:starts -join ',') -eq 'A,B,B')
    Assert-True (@($script:State.applications | Where-Object completed).Count -eq 2)
}

Test 'Código 3010 persiste reboot; timeout não mata instalador' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    . (Join-Path $repo 'Scripts\Software.ps1')
    $script:DeployRoot=Join-Path $testRoot 'reboot-app'
    New-Item -ItemType Directory -Path (Join-Path $script:DeployRoot 'Temp') -Force | Out-Null
    Set-Content (Join-Path $script:DeployRoot 'Temp\App.exe') 'MOCK ONLY'
    $script:Config=@{aplicativos=@([pscustomobject]@{arquivo='App.exe';argumentos=@();codigosSaidaEsperados=@(0,3010);timeoutSeconds=10;validacao=@{tipo='file';caminho=(Join-Path $script:DeployRoot 'installed')}})}
    $script:State=[pscustomobject]@{applications=@();stage='AfterHostnameReboot';rebootFrom=''}
    $script:DeployContext=@{Applications=@()}
    function Save-DeploymentState { }
    function Get-BootMarker { 'boot1' }
    function Start-Process {
        Set-Content (Join-Path $script:DeployRoot 'installed') 'ok'
        $p=[pscustomobject]@{Id=999999;StartTime=(Get-Date)}
        $p | Add-Member ScriptMethod Dispose {}
        return $p
    }
    function Wait-InstallerProcess { 3010 }
    Assert-True (Invoke-SoftwareStep)
    Assert-True ($script:State.stage -eq 'SoftwareRebootPending' -and $script:State.rebootFrom -eq 'boot1')
    . (Join-Path $repo 'Scripts\Software.ps1')
    $process=[pscustomobject]@{Id=999999}
    $process | Add-Member ScriptMethod WaitForExit { param($ms) return $false }
    $process | Add-Member ScriptMethod Kill { throw 'KILL_FORBIDDEN' }
    Assert-Throws { Wait-InstallerProcess $process 1 } '*NÃO foi encerrado*'
}

Test 'Build manual e automático, manifesto e limite XML' {
    . (Join-Path $repo 'Scripts\Preflight.ps1')
    $cfg=Read-DeployConfig (Join-Path $repo 'config.json')
    $cfg.rede.mode='preparation'; $cfg.dominio.credenciais.usuarioPadrao='LAB\join'; $cfg.dominio.controlador='dc.lab.local'; $cfg.aplicativos=@()
    $configFile=Join-Path $testRoot 'config-valid.json'
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $configFile -Encoding UTF8
    $builder=Join-Path $repo 'VentoyPackaging\Build-VentoyPayload.ps1'
    $manual=Join-Path $testRoot 'manual'
    & $builder -OutputDirectory $manual -ImageIndex 6 -IsoPath '/ISO/Win11.iso' -ConfigPath $configFile
    [xml]$xml=Get-Content (Join-Path $manual 'ventoy\deploy\autounattend.xml') -Raw
    Assert-True ($xml.SelectNodes("//*[local-name()='WillWipeDisk']").Count -eq 0)
    foreach ($node in $xml.SelectNodes("//*[local-name()='Path']")) { Assert-True ($node.InnerText.Length -le 259) }
    Assert-True ($xml.OuterXml -notmatch '__[A-Z_]+__|\$\$VT_')
    Assert-PackageManifest (Join-Path $manual 'Deploy')
    Assert-Throws { & $builder -OutputDirectory (Join-Path $testRoot 'refused') -ImageIndex 6 -IsoPath '/ISO/Win11.iso' -ConfigPath $configFile -TargetDiskId 0 } '*ConfirmDiskErase*'
    $automatic=Join-Path $testRoot 'automatic'
    & $builder -OutputDirectory $automatic -ImageIndex 6 -IsoPath '/ISO/Win11.iso' -ConfigPath $configFile -TargetDiskId 1 -ConfirmDiskErase
    [xml]$auto=Get-Content (Join-Path $automatic 'ventoy\deploy\autounattend.xml') -Raw
    Assert-True ($auto.SelectSingleNode("//*[local-name()='DiskID']").InnerText -eq '1')
    Add-Content (Join-Path $manual 'Deploy\Scripts\Domain.ps1') '# altered'
    Assert-Throws { Assert-PackageManifest (Join-Path $manual 'Deploy') } '*alterado*'
}

$script:results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host "Resultados preservados: $testRoot"
if (@($script:results | Where-Object { -not $_.passed }).Count -gt 0) { exit 1 }
Write-Host "$($script:results.Count) testes passaram. Nenhuma instalação/rede/AD/disco foi alterado."
