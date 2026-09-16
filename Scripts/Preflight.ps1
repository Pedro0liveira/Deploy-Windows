function Resolve-PayloadPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) { throw "Caminho relativo inválido: $RelativePath" }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Caminho fora do payload: $RelativePath" }
    return $path
}

function Assert-RequiredProperties {
    param($Object, [string[]]$Names, [string]$Section)
    foreach ($name in $Names) {
        if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$name] -or $null -eq $Object.$name) { throw "Configuração obrigatória ausente: $Section.$name" }
    }
}

function Read-DeployConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuração não encontrada: $Path" }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "JSON inválido: $Path. $($_.Exception.Message)" }
}

function Assert-DeployConfig {
    param($Config, [string]$Root)
    Assert-RequiredProperties $Config @('deployment','empresa','computador','rede','dominio','aplicativos','logging') 'config'
    Assert-RequiredProperties $Config.deployment @('mode','pauseAtCheckpoints','stateFile') 'deployment'
    Assert-RequiredProperties $Config.empresa @('unidade') 'empresa'
    Assert-RequiredProperties $Config.computador @('nomePattern','validarSerial','serialsInvalidos') 'computador'
    Assert-RequiredProperties $Config.rede @('mode','interface','usarDhcp','timeoutSeconds') 'rede'
    Assert-RequiredProperties $Config.dominio @('fqdn','controlador','credenciais') 'dominio'
    Assert-RequiredProperties $Config.dominio.credenciais @('modo','usuarioPadrao') 'dominio.credenciais'
    Assert-RequiredProperties $Config.logging @('habilitado','arquivo') 'logging'
    if ($Config.deployment.mode -notin @('validation','silent')) { throw 'deployment.mode deve ser validation ou silent (join continua interativo).' }
    foreach ($value in @($Config.deployment.pauseAtCheckpoints,$Config.computador.validarSerial,$Config.rede.usarDhcp,$Config.logging.habilitado)) { if ($value -isnot [bool]) { throw 'Opção booleana deve usar true/false, sem aspas.' } }
    foreach ($path in @($Config.deployment.stateFile,$Config.logging.arquivo)) { if ($path -notmatch '^[A-Za-z]:\\' -or $path -match '["\r\n]') { throw "Log/estado devem usar caminho local absoluto: $path" } }
    if ($Config.deployment.stateFile -ieq $Config.logging.arquivo) { throw 'Log e estado não podem usar o mesmo arquivo.' }
    if ($Config.rede.mode -notin @('8021x','preparation')) { throw 'Defina rede.mode: 8021x ou preparation (rede de preparação previamente autorizada).' }
    if ($Config.rede.timeoutSeconds -isnot [ValueType] -or $Config.rede.timeoutSeconds -lt 10 -or $Config.rede.timeoutSeconds -gt 600) { throw 'rede.timeoutSeconds deve estar entre 10 e 600.' }
    if ([string]::IsNullOrWhiteSpace($Config.rede.interface) -or $Config.rede.interface -match '["*?\r\n]') { throw 'Informe o nome exato da interface, sem curingas.' }
    if ($Config.empresa.unidade -notmatch '^[A-Za-z0-9-]+$' -or $Config.computador.nomePattern -notmatch '\{SERIAL\}') { throw 'Unidade ou padrão de hostname inválido.' }
    foreach ($name in @($Config.dominio.fqdn,$Config.dominio.controlador)) { if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$' -or $name -match '__') { throw "Nome de domínio/DC inválido: $name" } }
    if ($Config.dominio.credenciais.modo -ne 'prompt' -or [string]::IsNullOrWhiteSpace($Config.dominio.credenciais.usuarioPadrao) -or $Config.dominio.credenciais.usuarioPadrao -match '^EMPRESA\\|__') { throw 'Defina a conta real de ingresso; credenciais.modo deve ser prompt.' }
    if ($Config.dominio.controlador -notmatch '^[A-Za-z0-9-]+\.[A-Za-z0-9.-]+$') { throw 'dominio.controlador deve ser o FQDN real do DC, exigido pelo ingresso nas versões atuais do Windows.' }
    foreach ($obsolete in @('validarDns','validarDc','validarSecureChannel')) { if ($null -ne $Config.dominio.PSObject.Properties[$obsolete]) { throw "Remova dominio.${obsolete}: as validações AD são obrigatórias." } }
    if ($null -ne $Config.computador.PSObject.Properties['verificarDuplicidadeNoAd']) { throw 'Remova verificarDuplicidadeNoAd: essa opção não tinha implementação.' }
    if ($Config.rede.mode -eq '8021x') {
        Assert-RequiredProperties $Config.rede @('authMode','ssoMode','perfil8021x','authenticationSuccessPatterns') 'rede'
        if ($Config.rede.perfil8021x -notmatch '^Network[\\/].+\.xml$') { throw 'perfil8021x deve apontar para um XML em Network.' }
        $profile = Resolve-PayloadPath $Root $Config.rede.perfil8021x
        if (-not (Test-Path -LiteralPath $profile -PathType Leaf)) { throw "Perfil 802.1X ausente: $profile" }
        $text = Get-Content -LiteralPath $profile -Raw -Encoding UTF8
        if ($text -match 'EXPORTAR_PERFIL_REAL') { throw 'Substitua LAN.xml pelo perfil 802.1X autorizado.' }
        try { [xml]$xml = $text } catch { throw 'LAN.xml não é XML válido.' }
        if ($null -eq $xml.DocumentElement -or $xml.DocumentElement.LocalName -ne 'LANProfile' -or $xml.DocumentElement.NamespaceURI -ne 'http://www.microsoft.com/networking/LAN/profile/v1') { throw 'LAN.xml não contém LANProfile no namespace esperado.' }
        $enabled = $xml.SelectSingleNode("//*[local-name()='OneXEnabled']")
        if ($null -eq $enabled -or $enabled.InnerText -cne 'true') { throw 'LAN.xml deve habilitar OneXEnabled=true.' }
        foreach ($field in @('authMode','ssoMode')) {
            $query = if ($field -eq 'ssoMode') { "//*[local-name()='singleSignOn']/*[local-name()='type']" } else { "//*[local-name()='OneX']/*[local-name()='authMode']" }
            $nodes = @($xml.SelectNodes($query))
            if ($nodes.Count -ne 1 -or $nodes[0].InnerText -cne $Config.rede.$field) { throw "LAN.xml diverge de rede.$field." }
        }
        if (@($Config.rede.authenticationSuccessPatterns).Count -eq 0) { throw 'Informe padrões de autenticação validados com netsh real.' }
        foreach ($pattern in $Config.rede.authenticationSuccessPatterns) { if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Padrão de autenticação vazio.' }; $null = [regex]::new($pattern) }
    }
    if ($Config.aplicativos -isnot [array]) { throw 'aplicativos deve ser uma lista JSON, inclusive quando vazia: [].' }
    $seen = @{}
    foreach ($app in $Config.aplicativos) {
        Assert-RequiredProperties $app @('arquivo','argumentos','codigosSaidaEsperados','timeoutSeconds','validacao') 'aplicativos[]'
        Assert-RequiredProperties $app.validacao @('tipo','caminho') 'aplicativos[].validacao'
        if ($app.arquivo -match '(^|[\\/])\.\.([\\/]|$)|:') { throw 'Instalador deve permanecer dentro de Temp.' }
        if ($seen.ContainsKey($app.arquivo)) { throw "Instalador duplicado: $($app.arquivo)" }; $seen[$app.arquivo] = $true
        $installer = Resolve-PayloadPath $Root ('Temp\' + $app.arquivo)
        if ($app.arquivo -match '^Aplicativo0[12]\.exe$' -or -not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Entregue instalador real ou remova da lista: $($app.arquivo)" }
        if ([IO.Path]::GetExtension($installer) -ine '.exe') { throw 'Nesta versão, use instaladores EXE; MSI precisa de wrapper explícito e homologado.' }
        if ($app.argumentos -isnot [array]) { throw 'argumentos deve ser uma lista de strings.' }
        foreach ($argument in $app.argumentos) { if ($argument -isnot [string] -or $argument -match '[\r\n]') { throw 'Argumento de instalador inválido.' } }
        if ($app.codigosSaidaEsperados -isnot [array] -or @($app.codigosSaidaEsperados).Count -eq 0 -or $app.codigosSaidaEsperados -contains 1641) { throw 'Configure códigos de saída; 1641 (reboot iniciado pelo instalador) não é suportado. Use supressão de reboot.' }
        foreach ($code in $app.codigosSaidaEsperados) { if ($code -isnot [int] -and $code -isnot [long]) { throw 'Códigos de saída devem ser números inteiros.' } }
        if (($app.timeoutSeconds -isnot [int] -and $app.timeoutSeconds -isnot [long]) -or $app.timeoutSeconds -lt 1 -or $app.timeoutSeconds -gt 14400) { throw 'timeoutSeconds do instalador deve estar entre 1 e 14400.' }
        if ($app.validacao.tipo -ne 'file' -or $app.validacao.caminho -notmatch '^[A-Za-z]:\\') { throw 'Cada aplicativo precisa de validação file com caminho local absoluto para retomada segura.' }
    }
}

function Assert-PowerShellFiles {
    param([string]$Root)
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.ps1') {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -lt 3 -or [BitConverter]::ToString($bytes[0..2]) -ne 'EF-BB-BF') { throw "Script sem UTF-8 BOM: $($file.FullName)" }
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if ($errors.Count -gt 0) { throw "Erro de sintaxe em $($file.Name): $($errors[0].Message)" }
    }
}

function Assert-PackageManifest {
    param([string]$Root)
    $manifest = Read-DeployConfig (Join-Path $Root 'manifest.json')
    Assert-RequiredProperties $manifest @('packageId','files') 'manifest'
    if ($manifest.packageId -notmatch '^[a-f0-9]{32}$') { throw 'Identificador do pacote inválido.' }
    $seen = @{}
    foreach ($entry in $manifest.files) {
        Assert-RequiredProperties $entry @('path','sha256') 'manifest.files[]'
        if ($seen.ContainsKey($entry.path)) { throw 'Manifesto possui caminhos duplicados.' }; $seen[$entry.path] = $true
        $path = Resolve-PayloadPath $Root $entry.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.sha256) { throw "Arquivo ausente ou alterado: $($entry.path). Reconstrua/recopie o pacote completo." }
    }
    foreach ($required in @('Deploy.ps1','Bootstrap.ps1','config.json','Scripts\Preflight.ps1','Scripts\Runtime.ps1','Scripts\Orchestrator.ps1','Scripts\Computer.ps1','Scripts\Network.ps1','Scripts\Software.ps1','Scripts\Domain.ps1','Scripts\Validation.ps1',('package-' + $manifest.packageId + '.marker'))) { if (-not $seen.ContainsKey($required)) { throw "Manifesto incompleto: $required" } }
}
