#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateRange(1,999)][int]$ImageIndex,
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'),
    [int]$TargetDiskId = -1,
    [switch]$ConfirmDiskErase
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Execute o build com powershell.exe (Windows PowerShell 5.1).' }
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Scripts\Preflight.ps1')
if ($IsoPath -notmatch '^/[^\r\n]+\.iso$' -or $IsoPath -match '[*?\\]' -or $IsoPath -match '/\.\.?/') { throw 'IsoPath deve ser o caminho exato da ISO no USB, como /ISO/Windows11.iso.' }
if ($TargetDiskId -lt -1 -or $TargetDiskId -gt 128) { throw 'TargetDiskId inválido.' }
if (($TargetDiskId -ge 0) -ne [bool]$ConfirmDiskErase) { throw 'Apagamento automático exige TargetDiskId e ConfirmDiskErase juntos. Sem ambos, escolha disco no Setup.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory já existe. Use uma pasta nova; nada será sobrescrito.' }
$sourceBase = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (($output.TrimEnd('\') + '\').StartsWith($sourceBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Crie a saída fora do repositório para não misturar pacote e fontes.' }
$config = Read-DeployConfig $ConfigPath
Assert-DeployConfig $config $root
Assert-PowerShellFiles $root

$packageId = [guid]::NewGuid().ToString('N')
$template = Get-Content -LiteralPath (Join-Path $root 'Autounattend\autounattend-fixed.xml') -Raw -Encoding UTF8
$template = $template.Replace('__EDITAR_INDICE_DA_ISO__', [string]$ImageIndex).Replace('__PACKAGE_ID__', $packageId)
[xml]$xml = $template
if ($TargetDiskId -lt 0) {
    foreach ($node in @($xml.SelectNodes("//*[local-name()='DiskConfiguration' or local-name()='InstallTo']"))) { $null = $node.ParentNode.RemoveChild($node) }
} else {
    foreach ($node in $xml.SelectNodes("//*[local-name()='DiskID']")) { $node.InnerText = [string]$TargetDiskId }
}
if ($xml.OuterXml -match '__[A-Z_]+__|\$\$VT_') { throw 'XML ainda contém placeholders.' }
$commands = @($xml.SelectNodes("//*[local-name()='RunSynchronousCommand']"))
$orders = @()
foreach ($command in $commands) {
    if ($command.Path.Length -gt 259 -or $command.Path.Length -eq 0) { throw 'Path do XML fora do limite de 259 caracteres.' }
    $orders += [int]$command.Order
}
if (@($orders | Select-Object -Unique).Count -ne $orders.Count) { throw 'Ordens duplicadas no XML.' }

$payload = Join-Path $output 'Deploy'
$ventoy = Join-Path $output 'ventoy\deploy'
New-Item -ItemType Directory -Path $payload,$ventoy -Force | Out-Null
foreach ($file in @('Deploy.ps1','Bootstrap.ps1')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $payload }
Copy-Item -LiteralPath (Join-Path $root 'Scripts') -Destination $payload -Recurse
Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $payload 'config.json')
if ($config.rede.mode -eq '8021x') {
    $destination = Resolve-PayloadPath $payload $config.rede.perfil8021x
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Resolve-PayloadPath $root $config.rede.perfil8021x) -Destination $destination
}
if ($config.aplicativos.Count -gt 0) { Copy-Item -LiteralPath (Join-Path $root 'Temp') -Destination $payload -Recurse }
Set-Content -LiteralPath (Join-Path $payload "package-$packageId.marker") -Value $packageId -Encoding UTF8
$entries = @(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path=$_.FullName.Substring($payload.Length + 1); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
[ordered]@{ packageId=$packageId; files=$entries } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $payload 'manifest.json') -Encoding UTF8
$xml.Save((Join-Path $ventoy 'autounattend.xml'))
[ordered]@{ auto_install=@([ordered]@{ image=$IsoPath; template='/ventoy/deploy/autounattend.xml' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'ventoy\ventoy.json') -Encoding UTF8
$diskMode = if ($TargetDiskId -lt 0) { 'MANUAL: escolher disco no Setup' } else { "AUTOMATICO: APAGAR disco $TargetDiskId; conferir numeração no WinPE do equipamento alvo antes de iniciar" }
[ordered]@{ packageId=$packageId; imageIndex=$ImageIndex; isoPath=$IsoPath; diskMode=$diskMode; createdAt=(Get-Date).ToString('o'); maxCommandLength=($commands.Path | ForEach-Object Length | Measure-Object -Maximum).Maximum } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'package-info.json') -Encoding UTF8
Assert-PackageManifest $payload
Write-Host "Pacote criado: $output"
Write-Host $diskMode
Write-Host 'Copie Deploy e ventoy para o USB. Preserve outras configurações Ventoy ao integrar a entrada gerada. Mantenha o USB até terminar specialize.'
Write-Host 'O build valida arquivos, não a ISO/hardware. Confirme índice via DISM, edição, firmware, drivers e autenticação antes do piloto.'
