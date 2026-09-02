# Decisões de implementação — V1

## Escopo aplicado

- `Discovery.ps1` não foi gerado e não há seção de discovery. A V1 usa somente as informações de referência presentes na especificação: unidade `NP4`, padrão `NP4-PE0F7VPV`, rede Ethernet/DHCP/802.1X PEAP Machine/User PreLogon, domínio `empresa.local` e DC `AD-MATRIZ-01`.
- Valores específicos de teste ou cliente ficam em `config.json`, `Network/LAN.xml`, instaladores em `Temp/` e no `autounattend.xml`; eles devem ser ajustados manualmente antes de cada teste.
- A automação não move a máquina de OU e não faz nenhuma configuração relevante após o Join AD.

## Join AD

O método escolhido é `Add-Computer -DomainName ... -Credential ... -Restart`.

Motivo: é nativo do Windows PowerShell, não exige instalação/disponibilidade de `netdom` e permite controlar a reinicialização que conclui o ingresso. O Join é precedido por validação pré-AD e a execução é interrompida a qualquer falha.

## Credenciais

O mecanismo é prompt interativo por `Get-Credential`, com o usuário padrão (sem senha) opcionalmente preenchido por `dominio.credenciais.usuarioPadrao`.

Nenhuma senha é armazenada no JSON, nos scripts ou no payload. Como o modo `validation` requer confirmação humana, o prompt é compatível com a V1. O processo deve ser executado por conta local administrativa e por uma conta de AD autorizada a criar/ingressar computadores.

## Aplicativos

Cada item de `aplicativos` no `config.json` é a tabela de instalação: `arquivo`, `argumentos`, `codigosSaidaEsperados` e `validacao` opcional de arquivo.

Os parâmetros silenciosos não foram presumidos: os dois itens fornecidos são marcadores e devem ser substituídos por argumentos documentados pelo respectivo instalador. O código só avança quando o executável existe e retorna um código esperado; se houver uma validação por arquivo configurada, ela também precisa passar.

## Propriedades definitivas do config.json

- `deployment.mode`, `deployment.pauseAtCheckpoints`, `deployment.stateFile`
- `empresa.unidade`
- `computador.nomePattern`, `computador.validarSerial`, `computador.serialsInvalidos`, `computador.verificarDuplicidadeNoAd`
- `rede.interface`, `rede.usarDhcp`, `rede.authMode`, `rede.ssoMode`, `rede.perfil8021x`, `rede.authenticationSuccessPatterns`
- `dominio.fqdn`, `dominio.controlador`, `dominio.validarDns`, `dominio.validarDc`, `dominio.validarSecureChannel`, `dominio.credenciais`
- `aplicativos[]` e `logging`

## Perfil 802.1X e autounattend

O XML 802.1X não foi reconstruído sem os certificados e parâmetros reais: `Network/LAN.xml` é um marcador que deliberadamente interrompe o deploy até ser substituído pelo arquivo exportado via `netsh lan export profile`.

O `autounattend.xml` é um modelo seguro, sem escolhas inventadas de disco, índice/edição ou idioma. Os campos identificados devem ser completados e validados em uma VM para cada ISO. Isso evita a formatação automática de um disco incorreto ou a seleção de uma imagem errada.

## Retomada após reboot

O deployment persiste o estado em `deployment.stateFile` e usa `HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce` para retomar em logon administrativo após o reboot do rename e do Join AD. O valor RunOnce é consumido pelo Windows na execução, por isso não deixa uma tarefa de pós-Join em execução contínua.
