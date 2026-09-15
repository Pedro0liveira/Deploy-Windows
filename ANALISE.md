# Análise — erro `0x8007000D - 0x40030` no Windows 11 Setup

Data: 2026-09-14 (atualizado 2026-09-15 com incidente real, ver §0). Base: código do repo (commit `7b78f73`), foto da tela, documentação Microsoft/Ventoy e issues públicas (fontes no fim).

## 0. Atualização 2026-09-15 — causa real encontrada em campo (rev. 4) + revisão adversarial (rev. 5)

A revisão 3 do `autounattend-fixed.xml` (proposta em §4/§5 abaixo) foi testada na máquina real e **quebrou de outro jeito**: tela genérica "computador foi reiniciado de forma inesperada", sem código hex. Log coletado via `Shift+F10` → `type X:\Windows\Panther\setuperr.log`:

```
[setup.exe] SMI data results dump: Source = Name: Microsoft-Windows-Deployment, ...
  Settings/RunSynchronousCommand/[Order="1"]/Path
[setup.exe] SMI data results dump: Description = O valor é inválido.
  Settings/RunSynchronousCommand/[Order="2"]/Path
[setup.exe] SMI data results dump: Description = O valor é inválido.
[0x060565] IBS Callback_Unattend_InitEngine: The provided unattend file
  [C:\WINDOWS\Panther\unattend.xml] is not a valid unattended Setup answer file;
  hr = 0x1, hrResult = 0x80220005
```

**Causa:** o campo `Path` de `RunSynchronousCommand` (componente `Microsoft-Windows-Deployment`) tem **limite de 259 caracteres**. Os dois comandos da revisão 3 estouravam isso:

| Comando (rev. 3) | Tamanho | Limite |
|---|---|---|
| Order 1 — cópia com loop `for %d in (D E F ... Z) do ...` | 359 chars | 259 |
| Order 2 — `schtasks /create ...` com redirecionamentos embutidos | 306 chars | 259 |

Com qualquer `Path` acima do limite, o Setup rejeita o `unattend.xml` **inteiro** (`hr = 0x80220005`, WMIConfig "the value is invalid") já dentro do pass `specialize` — ou seja, depois de particionar e aplicar a imagem, o que produz a tela genérica de erro fatal em vez de um erro específico do comando.

**Correção (revisão 4, arquivo já atualizado):** o loop `for` foi desmembrado em **22 `RunSynchronousCommand` curtos**, um por letra de unidade candidata (`D:` a `Z:`, pulando `C:` que é sempre o destino), cada um guardado por `if not exist C:\Deploy_copy_status.txt` para não repetir trabalho após achar a certa. O comando de `schtasks` foi encurtado e separado do registro de status. Todos os 26 comandos resultantes foram validados programaticamente — o maior tem 180 caracteres, folga de ~80 contra o limite.

Isso **não estava nos 10 defeitos originais listados em §4** porque a revisão 3 nunca tinha sido testada contra o limite de tamanho do schema — só contra a lógica (qual pass roda quando). Fica registrado aqui como aprendizado: **todo `Path`/`CommandLine` de unattend precisa ser medido, não só revisado visualmente.**

### 0.1 Revisão adversarial (Codex `gpt-5.6-sol`, 2026-09-15) — revisão 5

A revisão 4 passou por revisão adversarial independente. Cinco achados; quatro procedem e estão corrigidos na revisão 5.

| # | Sev | Achado | Veredito | Correção |
|---|---|---|---|---|
| 1 | P1 | Aspas simples quebrariam o `/tr` do `schtasks` | **Falso positivo.** Artefato do transporte: as aspas duplas foram trocadas por simples só para passar o prompt pela linha de comando do PowerShell. O arquivo real sempre teve aspas duplas. | nenhuma |
| 2 | P1 | A tarefa agendada roda como SYSTEM, não na sessão do usuário | **Procede, e invalida uma premissa minha.** `RunSynchronous` do `specialize` roda como SYSTEM; `schtasks` sem `/ru` herda esse principal. `Read-Host`/`Get-Credential` não têm UI ali: trava indefinidamente. | `schtasks` → `RunOnce` em HKLM |
| 3 | P1 | `VT_WINDOWS_DISK_1ST_NONVTOY` pode apontar para o disco errado | **Procede.** A variável garante "primeiro disco que não é o Ventoy", não "o disco de sistema". Com um HD de dados presente, `WillWipeDisk=true` o apagaria. | Não é corrigível no XML: virou aviso em destaque no cabeçalho + pré-requisito operacional (conferir `list disk` ou desconectar os demais discos) |
| 4 | P2 | `xcopy` falho ainda gravava `OK` e bloqueava as letras seguintes | **Procede.** `&` é separador incondicional. | `&` → `&&` antes do `echo OK` |
| 5 | P2 | Letra `X:` fora da varredura | **Procede.** Ficou de fora por ser o RAM disk do WinPE, mas no `specialize` o WinPE já não existe e o volume pode receber `X:`. | `X:` incluída (27 comandos agora) |

Nota de método: o sandbox do Codex bloqueia processos locais, então ele não conseguiu ler o repo nem rodar `git diff` — o XML teve que ir embutido no prompt. Um review que dependesse da leitura do disco teria voltado vazio e parecido aprovação.

## 1. O que o código diz

| Parte | Decodificação | Fonte |
|---|---|---|
| `0x8007000D` | HRESULT Win32. Últimos 4 dígitos `000D` = 13 = `ERROR_INVALID_DATA` ("Os dados são inválidos"). Setup leu um dado malformado ou corrompido: imagem (`install.wim/esd`, `boot.wim`), arquivo de resposta ou metadados de disco. | MS "Windows Setup error codes" §Result codes |
| `0x40030` | Extend code = fase `4` + operação `0x30`. A tabela pública da Microsoft (versão 1607) só vai até a operação `0x20`; `0x30` não está documentada. | MS "Windows Setup error codes" §Extend codes |
| Tela | Janela "Instalação do Windows 11", rodapé "Suporte / Ofício" = instalador novo (ConX / `SetupPrep.exe`) presente a partir do **24H2**. O instalador clássico mostra "Instalação do Windows". | elevenforum, NTLite |

**Contexto da família `0x400xx` no 24H2**: os códigos vizinhos `0x4002C` e `0x4002F` (com `0x80070001`, `0x80042444`, `0x8007000D`) são reportados exatamente na etapa **"verificando o disco / seleção de disco"** do instalador novo, e a maior parte dos relatos envolve **pendrive Ventoy**. `0x40030` é a operação imediatamente seguinte → mesma etapa (disco/destino). Isso é inferência por vizinhança, não mapeamento oficial.

## 2. Causas prováveis (ordem de probabilidade)

### 2.1 Ventoy desatualizado × instalador novo do 24H2 — **mais provável**
- Ventoy 1.0.99 quebrava o setup 24H2 na descoberta de disco (issues ventoy#2887, ventoy#3010, thread NTLite). Ventoy **1.1.04** (22/02/2025) corrigiu o `0x80070001` ao instalar Windows 11. Versão atual: **1.1.17** (24/07/2026).
- A assinatura é idêntica ao caso aqui: ISO 24H2, Ventoy, erro `0x400xx` antes de copiar arquivos.
- **Verificar**: versão do Ventoy no pendrive (`Ventoy2Disk` mostra) e se o pendrive é MBR+exFAT (padrão) — relatos de sucesso após NTFS ou MBR.
- **Ação**: atualizar Ventoy para 1.1.17 (Ventoy2Disk → Update, não apaga a partição de dados). Se persistir, testar o mesmo ISO com Rufus/Media Creation Tool no mesmo hardware: se instalar, é Ventoy; se não, é ISO ou hardware.

### 2.2 ISO ou pendrive corrompido — clássico do `ERROR_INVALID_DATA`
- Validar SHA256 da ISO contra o valor do site da Microsoft (`Get-FileHash .\Win11.iso -Algorithm SHA256`).
- Trocar de pendrive/porta USB. Relatos frequentes de o mesmo ISO funcionar em outro pendrive.

### 2.3 Disco alvo em estado que o setup novo rejeita
- Disco dinâmico, RAID/Intel VMD sem driver (setup não lista nenhum disco), tabela de partição inconsistente.
- Na tela de erro: `Shift+F10` → `diskpart` → `list disk` / `list vol`. Se o disco não aparece ou aparece como dinâmico, é isso. Corrigir: BIOS em AHCI (não RAID), `clean` no disco via diskpart.

### 2.4 `autounattend.xml` rejeitado pelo `SetupPrep.exe`
- O instalador 24H2 é mais rígido com o arquivo de resposta que o 23H2 (relatos: mesmo XML funciona no 23H2 e falha no 24H2).
- O arquivo do repo é sintaticamente válido e mínimo. **Ausência de `DiskConfiguration`/`ImageInstall` não causa erro** — o setup simplesmente pergunta disco/edição na tela. Isso foi afirmado como causa raiz numa versão anterior desta análise e está **retirado**.
- Teste de isolamento: bootar o mesmo ISO pelo Ventoy **sem** `auto_install` (remover a entrada do `ventoy.json`). Se instala, o XML está envolvido; se falha igual, não está.

## 3. Como fechar o diagnóstico (evidência, não chute)

Na tela de erro, `Shift+F10` abre `cmd`:

```cmd
notepad X:\Windows\Panther\setupact.log
notepad X:\Windows\Panther\setuperr.log
dir X:\Deploy
diskpart
list disk
list vol
```

Se o setup já chegou a tocar o disco: `C:\$WINDOWS.~BT\Sources\Panther\setupact.log`. Ler de baixo pra cima; a última linha com `0x8007000D` antes do "cleanup" diz o componente exato. Copiar os dois logs pra um pendrive e anexar no card.

## 4. Defeitos encontrados na varredura do repo (bloqueiam a automação, independentes da tela)

| # | Onde | Problema | Efeito | Correção |
|---|---|---|---|---|
| 1 | `autounattend.xml` pass `windowsPE`, `RunSynchronous` ordem 90 | Comandos `RunSynchronous` do `windowsPE` rodam **antes** do particionamento e da cópia da imagem (doc MS "How configuration passes work"). O comentário "C: deve existir após a configuração de disco" está errado. `C:\` naquele momento é o Windows antigo (que será apagado) ou não existe. | Payload nunca chega ao Windows instalado → `specialize` grava `ERRO_DEPLOY_PS1_AUSENTE` → automação morre. | Copiar no pass `specialize`, varrendo letras em busca do pendrive Ventoy (partição exFAT monta com letra no Windows instalado). Implementado em `autounattend-fixed.xml`. |
| 2 | `VentoyPackaging/` | Só tem `ventoy.json`. Nada gera `deploy-payload.7z` nem copia `autounattend.xml` para `/ventoy/deploy/`. O `injection` extrai o 7z na raiz de `X:\`, então o 7z precisa conter a pasta `Deploy\` na raiz. | Sem empacotamento reproduzível, `X:\Deploy` pode nunca existir. | Script `Build-VentoyPayload.ps1` (a criar) que monta o 7z com `Deploy\` na raiz e copia para `<USB>:\ventoy\deploy\`. Com a correção #1 o 7z vira opcional: basta a pasta `Deploy\` na raiz do pendrive. |
| 3 | `autounattend.xml` pass `specialize` | ~~`schtasks` sem `/ru SYSTEM` roda no contexto do usuário que loga~~ — **esta afirmação estava errada** (ver §0.1). `RunSynchronous` do `specialize` executa como SYSTEM, e `schtasks /create` sem `/ru` herda o principal de quem criou: SYSTEM. A tarefa rodaria sem UI e os prompts do `Deploy.ps1` travariam para sempre. | Deploy trava no primeiro logon, sem erro visível. | **Resolvido na rev. 5**: `schtasks` trocado por `RunOnce` em HKLM, que dispara na sessão interativa do primeiro usuário, com o token dele. |
| 4 | `Deploy.ps1` + `config.json` | `mode: validation` usa `Read-Host`; `Domain.ps1` usa `Get-Credential`. Ambos exigem sessão interativa. Sob `/ru SYSTEM` não há UI → trava para sempre. | Conflito de design: tarefa em background × prompts interativos. | Decidir: (a) tarefa `onlogon` no usuário admin, interativa, mantém prompts; ou (b) SYSTEM + `mode: silent` + credencial de join vinda de cofre/LAPS. Recomendo (a) para V1. |
| 5 | `Deploy.ps1` `Register-DeploymentResume` | Grava `RunOnce` **e** a tarefa `onlogon` continuava existindo → após o reboot duas instâncias do `Deploy.ps1` disputavam `state.json`. | Estágio pode ser executado duas vezes (rename, join). | **Resolvido na rev. 5**: com o bootstrap também em `RunOnce`, existe um único mecanismo. `RunOnce` se autoapaga ao disparar, então não há tarefa residual (isso também resolve o #6). |
| 6 | `Deploy.ps1` estado `Completed` | Tarefa `onlogon` nunca é removida → script roda a cada logon pra sempre (só loga). | Ruído; risco se alguém apagar `state.json`. | Mesmo fix do #5. |
| 7 | `config.json` `aplicativos` + `Temp/` | Lista `Aplicativo01.exe`/`Aplicativo02.exe`; `Temp/` só tem `.gitkeep`. `Invoke-SoftwareStep` lança "Instalador não encontrado" na fase 2. | Deploy para depois do 1º reboot. | Lista vazia `[]` ou instaladores reais em `Temp\`. |
| 8 | `Network/LAN.xml` | Marcador `EXPORTAR_PERFIL_REAL` → `Invoke-NetworkStep` lança de propósito. | Bloqueio intencional, mas bloqueia. | Exportar perfil da máquina de referência (comando no próprio arquivo). |
| 9 | `Computer.ps1` hostname | Padrão `NP4-{SERIAL}` limitado a 15 chars → serial > 11 chars (ex.: alguns Lenovo/HP) lança "Hostname inválido para NetBIOS". | Falha na identificação. | Truncar serial (`-replace` + `Substring`) ou definir regra de encurtamento no `config.json`. |
| 10 | `autounattend.xml` `DiskConfiguration` (ausente) | Sem `DiskConfiguration`, o setup pergunta o disco (não erra). Mas ao adicionar, `DiskID 0` pode ser o **próprio pendrive** em alguns firmwares. | Risco de apagar o Ventoy. | Usar a variável do Ventoy `$$VT_WINDOWS_DISK_1ST_NONVTOY$$` no `DiskID` (auto_install ≥ 1.0.77). Aplicado em `autounattend-fixed.xml`. |

## 5. Ordem de ataque recomendada

1. Atualizar Ventoy → 1.1.17. Validar SHA256 da ISO. Rebootar e ver se o `0x8007000D - 0x40030` some. (§2.1, §2.2)
2. Se persistir: coletar `setupact.log`/`setuperr.log` (§3) antes de mexer em XML.
3. Só então trocar `autounattend.xml` pelo `autounattend-fixed.xml` (corrige #1, #10; completa disco/imagem). Testar em VM com um disco virtual **e** o pendrive Ventoy anexado, pra provar a cópia no `specialize`.
4. Resolver #3/#4 (decisão de design: interativo vs SYSTEM).
5. Resolver #5–#9 no `Deploy.ps1`/`config.json` antes de rodar em máquina real.

## Fontes

- Microsoft — Windows Setup error codes (result/extend): https://learn.microsoft.com/en-us/troubleshoot/windows-client/deployment/windows-10-upgrade-error-codes
- Microsoft — How configuration passes work (RunSynchronous do windowsPE roda antes da cópia da imagem): https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/how-configuration-passes-work
- Ventoy — release notes (1.1.04 corrige 0x80070001 no Win11; 1.1.17 atual): https://www.ventoy.net/en/doc_news.html
- Ventoy — auto_install plugin (variável `VT_WINDOWS_DISK_1ST_NONVTOY`): https://www.ventoy.net/en/plugin_autoinstall.html
- Ventoy — injection plugin (extrai em `X:\` do WinPE): https://www.ventoy.net/en/plugin_injection.html
- ventoy/Ventoy#2887 — 24H2 `0x80070001-0x4002f` na seleção de disco, UEFI/GPT, marcado Fixed: https://github.com/ventoy/Ventoy/issues/2887
- ventoy/Ventoy#3010 — 24H2 sem discos na descoberta, Ventoy 1.0.99: https://github.com/ventoy/Ventoy/issues/3010
- NTLite — 24H2 `0x4002F` (Ventoy), `0x400xx` na fase de disco/OOBE, legacy setup via boot.wim: https://ntlite.com/community/threads/windows-11-24h2-setup-error-0x800700001-0x4002f-ventoy.4529/
- Microsoft Q&A — `0x8007000D - 0x4002C` em instalação limpa (mídia): https://learn.microsoft.com/en-us/answers/questions/3112111/what-is-windows-error-code-0x8007000d-0x4002c
- elevenforum — 24H2 `SetupPrep.exe` mais rígido com autounattend: https://www.elevenforum.com/t/autounattend-not-working-for-new-windows-11-24h2.29237/
