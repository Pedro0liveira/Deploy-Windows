# Deploy-Windows

Instalação de Windows 11 via Ventoy, seguida de configuração interativa de rede, nome, aplicativos e ingresso no Active Directory.

**Revisão 6 — em validação.** Scripts e empacotamento têm testes no Windows PowerShell 5.1. A Dell, a ISO, os logons/reboots, o RADIUS e os instaladores reais ainda precisam de homologação. O erro original `0x8007000D-0x40030` não tem causa isolada; não está declarado resolvido.

## Antes de preparar a mídia

O repositório é um modelo e recusa a configuração incompleta entregue. Defina:

1. **Rede inicial:** `rede.mode` deve ser `8021x` ou `preparation`. Esta última significa porta/VLAN de preparação previamente autorizada; não desativa autenticação configurada na máquina/switch. Ainda não foi confirmado qual cenário estará disponível na Dell.
2. **802.1X, quando exigido:** perfil LAN autorizado, certificados/credenciais necessários no computador novo e método que funcione antes do ingresso no AD. Importar o perfil sozinho não instala certificados nem cria identidade de máquina no domínio.
3. **Identidade:** unidade, padrão de hostname, conta real de ingresso e **FQDN real do DC** em `dominio.controlador`. O nome curto `AD-MATRIZ-01` do modelo precisa ser completado com o domínio DNS confirmado. Versões atuais do Windows exigem FQDN ao especificar o servidor de ingresso ([Microsoft](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/add-computer?view=powershell-5.1#-server)). O nome final do computador deve caber em 15 caracteres; seriais não são truncados silenciosamente.
4. **Aplicativos:** EXEs reais em `Temp`, argumentos oficiais de instalação sem reboot, timeout, códigos de saída e arquivo de detecção confiável. Para um piloto explicitamente sem aplicativos, use `"aplicativos": []`.
5. **ISO/equipamento:** hash/origem da ISO, índice real da edição compatível com AD, idioma pt-BR do template, UEFI e drivers de SSD/rede. O pacote espera Windows em `C:`. Não selecione Home.
6. **Operador:** conta administrativa local disponível após cada reboot, inclusive depois do ingresso no AD. Use a mesma conta em todas as retomadas; a tarefa é vinculada ao SID dela.

Mantenha configurações reais em `config.local.json` e perfis em `Network/*.local.xml` (ignorados pelo Git). Não publique credenciais, certificados privados ou instaladores no repositório. O perfil marcador `Network/LAN.xml` permanece apenas como instrução.

## Preparar um pacote

Use **Windows PowerShell 5.1 (`powershell.exe`)**, sem necessidade de privilégios administrativos para o build. Não copie o template XML diretamente para o USB. Não use o procedimento antigo com injeção 7z.

```powershell
# Examine a imagem da ISO montada; pode ser install.esd em vez de install.wim.
dism /Get-WimInfo /WimFile:D:\sources\install.wim

# Informe o índice observado na SUA imagem, sem presumir numeração de edições.
$indiceConfirmado = [int](Read-Host 'Índice da edição compatível com AD')
.\VentoyPackaging\Build-VentoyPayload.ps1 `
    -ConfigPath .\config.local.json `
    -OutputDirectory C:\Pacotes\Deploy-Dell-01 `
    -ImageIndex $indiceConfirmado `
    -IsoPath '/ISO/Windows11.iso'
```

Use uma saída nova, fora do repositório. O build valida configuração, perfil, arquivos, BOM/parser, manifesto e comprimento dos comandos. Ele **não abre a ISO nem valida o índice contra seu WIM/ESD**: essa conferência é a etapa DISM acima. O XML ainda deve ser validado com Windows SIM/ADK compatível com a imagem e testado no equipamento.

O resultado contém:

```text
Deploy/                         scripts, configuração e recursos
  manifest.json                 hashes SHA256 de integridade
  package-<id>.marker            identifica o pacote procurado pelo XML
ventoy/
  ventoy.json                   auto_install para uma ISO exata
  deploy/autounattend.xml        resposta gerada
package-info.json               índice, ISO, modo de disco e identificador
```

Copie `Deploy/` e a configuração gerada de `ventoy/` para a raiz da partição de dados do USB. Se já usa `ventoy.json`, integre a entrada `auto_install` preservando as demais configurações. A ISO deve estar no caminho exato passado em `IsoPath`. Esta versão prepara um pacote ativo por USB; não oferece payloads diferentes por ISO.

Mantenha o USB conectado até terminar `specialize`. O Windows instalado procura a pasta persistente de D: a Z:, pelo identificador do pacote, e a copia para `C:\Deploy`. O manifesto detecta cópia incompleta/alteração acidental; não é uma assinatura de procedência.

### Disco: seleção manual por padrão

Sem opções adicionais, o XML gerado **não contém `DiskConfiguration`/`InstallTo`**. O operador escolhe o disco/partição no Setup e confirma a formatação ali. Isso evita apagar automaticamente o primeiro disco não-Ventoy.

Para apagamento automático em equipamento previamente conferido, o build exige simultaneamente `-TargetDiskId <ID_CONFIRMADO_NO_WINPE>` e `-ConfirmDiskErase`. O ID deve ser o observado no ambiente de instalação da máquina alvo, nunca o ID de disco do computador que gerou o pacote. Desconecte discos extras quando possível. Conferir `list disk` não altera a seleção definida no XML.

O layout automático usa GPT/UEFI, EFI 300 MB, MSR 16 MB e Windows. Não reserva partição dedicada WinRE; validar `reagentc /info` e a política de recuperação faz parte do aceite. BIOS legado requer outro layout e não é suportado por esse template.

## Execução e retomadas

```text
Ventoy/Setup -> specialize copia pacote -> primeiro logon administrativo
  Bootstrap.ps1 -> valida manifesto/parser -> Deploy.ps1
  Start -> rede -> RenamePending -> rename confirmado -> reboot
  AfterHostnameReboot -> aplicativos -> JoinPending -> join confirmado -> reboot
  AfterDomainJoinReboot -> validações AD -> Completed
```

- O **primeiro** logon usa `HKLM RunOnce / DeployBootstrap`.
- O deploy cria uma tarefa `EmpresaDeployResume`, no SID do administrador atual, com logon `Interactive` e privilégio `Highest`. Ela mantém os prompts visíveis, não roda como SYSTEM, permanece após falhas e é removida ao concluir.
- Entre com a **mesma conta administrativa local** após cada reboot. Um usuário de domínio comum não dispara essa retomada.
- Configuração alternativa em `-ConfigPath` é preservada; scripts continuam relativos à pasta da aplicação. No pacote gerado, a configuração selecionada no build é copiada como `Deploy/config.json`.
- `RenamePending` e `JoinPending` podem ser repetidos/reconciliados. Cancelar uma credencial não promove a máquina a pós-AD.
- O estado registra o boot anterior. Executar novamente antes do reboot exigido solicita esse reboot em vez de validar cedo demais.
- `deployment.mode: silent` desativa checkpoints; **o pedido de credenciais de AD continua interativo**. Não há modo SYSTEM totalmente desatendido.

### Aplicativos

Exemplo de formato; substitua todos os dados pelo instalador homologado:

```json
{
  "arquivo": "SetupApp.exe",
  "argumentos": ["/quiet", "/norestart"],
  "codigosSaidaEsperados": [0, 3010],
  "timeoutSeconds": 1800,
  "validacao": {
    "tipo": "file",
    "caminho": "C:\\Program Files\\App\\App.exe"
  }
}
```

`argumentos: []` é aceito. Cada string representa um argumento, sem aspas externas manuais; espaços e aspas internas são escapados ao montar a linha de comando. Homologue parâmetros especiais do fornecedor. Toda a pasta `Temp` é copiada quando há aplicativos, preservando CABs/arquivos auxiliares.

A retomada usa detecção e progresso por aplicativo. Um A concluído não é reinstalado quando B falha. Alterar instalador/configuração de aplicativo já registrado exige reconciliação, não atualização silenciosa. Detecção por arquivo não comprova versão/configuração; escolha um arquivo que indique conclusão real.

Código 3010 é persistido como necessidade de reboot antes de seguir. Código 1641 não é aceito: configure o fornecedor para não iniciar o reboot por conta própria. Em timeout, o processo **não é morto**; a próxima tentativa verifica PID/hora de início para evitar uma segunda instalação concorrente. A espera acompanha o processo lançado: EXEs que iniciam filhos e saem imediatamente precisam de wrapper síncrono homologado; MSI direto não é suportado nesta versão.

## Recuperar uma falha

Preserve o erro e `state.json`. Corrija primeiro a causa. Para configuração/arquivos alterados, reconstrua e recopie o pacote completo, pois o manifesto rejeita alterações avulsas.

Abra Windows PowerShell **como administrador** na mesma conta e execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Deploy\Bootstrap.ps1
```

Se usa configuração externa, passe o mesmo `-ConfigPath`. Não apague o estado para tentar “do zero”: confira nome atual/pendente, associação ao domínio, boot e aplicativos. Estados da revisão 5 não são migrados automaticamente porque podem indicar sucesso de operações que falharam; precisam de reconciliação manual. A tarefa continua disponível após falhas posteriores ao seu registro; erros anteriores ao primeiro registro exigem a entrada manual acima.

| Arquivo | O que comprova |
|---|---|
| `C:\Deploy_copy_status.txt` | Resultado da cópia e letra da origem; não comprova execução |
| `C:\Deploy_copy.log` | Saída/erros do xcopy |
| `C:\Deploy_bootstrap_status.txt` | Registro inicial do gatilho; não comprova sucesso do PowerShell |
| `C:\ProgramData\Deploy\bootstrap.log` | Transcrição do bootstrap, inclusive erros iniciais |
| `C:\ProgramData\Deploy\deploy.log` | Eventos estruturados do deploy (caminho configurável) |
| `C:\ProgramData\Deploy\state.json` | Etapa/progresso/identidade (caminho configurável) |
| `C:\Windows\debug\NetSetup.log` | Diagnóstico do ingresso no domínio, inclusive restrições de reutilização de conta |

Se o Setup falhar, use Shift+F10 e preserve `setupact.log`/`setuperr.log` nos caminhos existentes em `X:\Windows\Panther`, `C:\Windows\Panther` ou `C:\$WINDOWS.~BT\Sources\Panther`. Registre fase, versão do Ventoy e hash da ISO. Isole mudanças; não atribua automaticamente o erro ao Ventoy. Histórico: [ANALISE.md](ANALISE.md).

## Testes e aceite

```powershell
powershell.exe -NoProfile -File .\Tests\Run-Tests.ps1
```

Testes sem Pester/dependências externas: parser/BOM do 5.1, pré-requisitos, estados, reboot, configuração alternativa, isolamento da interface, ordem 802.1X/DHCP, argumentos vazios, aplicativos parciais, código 3010, timeout, manifesto e geração dos dois modos de disco. Rede, serviços, rename, tarefas, join e reboot são simulados. O teste grava apenas fixtures/resultados em pasta temporária e consulta `hostname.exe`. GitHub Actions executa a mesma suíte em Windows.

Antes de considerar a Dell pronta:

- Validar XML no Windows SIM e instalar a ISO real, com disco alvo inequívoco.
- Confirmar bootstrap e prompts administrativos em cada logon/reboot.
- Confirmar rede inicial e pós-AD no switch/RADIUS real, inclusive certificados.
- Testar falha de credencial e retomada sem avanço indevido.
- Validar instaladores, drivers, ativação, atualizações e WinRE conforme política.
- Confirmar domínio/canal seguro e mover a máquina para a OU final manualmente.

As validações DNS/DC/canal seguro são obrigatórias; as antigas opções sem efeito foram removidas. O servidor `dominio.controlador` é usado tanto nas verificações quanto em `Add-Computer`.
