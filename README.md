# Deploy-Windows

Automação desatendida de instalação, formatação e deployment de Windows 11 via Ventoy + Autounattend.xml + PowerShell.

**Status:** em validação — bloqueios abertos em `ANALISE.md` §4  
**Erro em investigação:** `0x8007000D - 0x40030` (etapa de disco do setup 24H2)

---

## ⚡ Problema Identificado (Error 0x8007000D)

A instalação do Windows 11 falha com `0x8007000D - 0x40030` na etapa de disco do instalador novo (24H2, `SetupPrep.exe`).

- `0x8007000D` = `ERROR_INVALID_DATA` (dado inválido/corrompido lido pelo setup).
- `0x40030` = fase 4, operação `0x30`, não documentada pela Microsoft. Os vizinhos `0x4002C`/`0x4002F` são a etapa "verificando o disco" do 24H2 e quase sempre envolvem **Ventoy desatualizado**.

**Ordem de ataque:** (1) atualizar Ventoy para 1.1.17 e validar o SHA256 da ISO; (2) se persistir, coletar `X:\Windows\Panther\setuperr.log` via `Shift+F10`; (3) só então trocar o XML.

**Nota:** o `autounattend.xml` original não tem `DiskConfiguration`/`ImageInstall`. Isso **não** gera erro (o setup pergunta na tela). O defeito real do XML é outro: a cópia do payload roda no pass `windowsPE`, antes do particionamento, então `C:\Deploy` nunca chega ao Windows instalado. `autounattend-fixed.xml` move a cópia para o `specialize`.

Detalhes, evidências e os 10 defeitos da varredura: `ANALISE.md`.

---

## 🚀 Quick Start

### 1. Preparar ISO e Ventoy

```bash
# Download ISO Windows 11
# Criar USB Ventoy (https://www.ventoy.net/)
# Copiar Deploy-Windows/ para a raiz do pendrive Ventoy como \Deploy\ (o specialize varre D:..Z: por \Deploy\Deploy.ps1)
# Copiar autounattend-fixed.xml para entoy\deployutounattend.xml e ventoy.json para entoyentoy.json
```

### 2. Ajustar Autounattend.xml

```xml
<!-- Copiar autounattend-fixed.xml → autounattend.xml -->
<!-- Revisar campos obrigatórios: -->
```

| Campo | Localização | Ajuste |
|-------|-------------|--------|
| **Edição Windows** | `ImageInstall/OSImage/InstallFrom/MetaData[@Key="/IMAGE/INDEX"]` | 1=Home, 2=Pro, 3=Enterprise (conforme sua ISO) |
| **Particionamento** | `DiskConfiguration/Disk/CreatePartitions` | Layout de disco esperado (EFI/MBR) |
| **Nome/Org** | `UserData/FullName`, `Organization` | Seu nome/empresa |
| **Linguagem** | `International-Core-WinPE` | pt-BR (ou seu idioma) |

### 3. Validar config.json

```json
{
  "empresa": { "unidade": "NP4" },                    // Código da unidade
  "dominio": {
    "fqdn": "gruponp.local",                          // FQDN do seu domínio AD
    "controlador": "AD-MATRIZ-01",                    // Nome do DC
    "credenciais": { "usuarioPadrao": "EMPRESA\\deploy.join" }
  },
  "aplicativos": [                                    // Instaladores opcionais
    { "arquivo": "Aplicativo01.exe" }
  ],
  "rede": {
    "interface": "Ethernet",                          // Adaptador alvo
    "perfil8021x": "Network\\LAN.xml"                 // Perfil 802.1X (AJUSTAR)
  }
}
```

### 4. Configurar Perfil 802.1X (LAN.xml)

```bash
# Em máquina de referência com acesso 802.1X:
netsh lan export profile folder=C:\Export

# Copiar perfil exportado para Network/LAN.xml
# Substituir marcador "EXPORTAR_PERFIL_REAL" no script
```

### 5. Testar em VM

```bash
# 1. Boot ISO (Ventoy) em VM — UEFI ou BIOS conforme Autounattend.xml
# 2. Setup executa Autounattend.xml automaticamente
# 3. Após 2 reboots, Deploy.ps1 dispara automaticamente
# 4. Revisar logs:
#    - C:\Deploy_copy_status.txt (specialize — letra do pendrive de onde copiou)
#    - C:\Deploy_schtasks_status.txt (specialize)
#    - C:\ProgramData\Deploy\deploy.log (Deploy.ps1)
```

### 6. Deploy em Produção

```bash
# 1. Boot USB Ventoy em máquina-alvo
# 2. Deixar Setup executar até completar
# 3. Após reboots, Deploy.ps1 executa automaticamente
# 4. Ingresso no AD: inserir credenciais quando solicitado
# 5. Mover máquina para OU final no AD (manual)
```

---

## 📁 Estrutura

```
Deploy-Windows/
├── Deploy.ps1                      Orquestrador principal (4 fases)
├── config.json                     Configuração centralizada
├── README.md                        Este arquivo
├── ANALISE.md                       Análise técnica do erro
├── Autounattend/
│   ├── autounattend.xml           original (cópia do payload no pass errado — ver ANALISE.md §4 #1)
│   └── autounattend-fixed.xml     revisão 3 (cópia no specialize + DiskConfiguration + ImageInstall)
├── Scripts/
│   ├── Computer.ps1               Identificação + rename de computador
│   ├── Network.ps1                DHCP, 802.1X, validação de rede/DNS/DC
│   ├── Software.ps1               Instalação de aplicativos
│   ├── Domain.ps1                 Ingresso no AD (Add-Computer)
│   └── Validation.ps1             Checks pré/pós-AD
├── Network/
│   └── LAN.xml                    Perfil 802.1X (TEMPLATE — ajustar)
├── Temp/                          (Opcional) Instaladores e recursos
└── VentoyPackaging/
    └── ventoy.json                Configuração Ventoy
```

---

## 🔄 Fluxo de Execução

### Fase 1: Identificação + Rede
1. **windowsPE (Autounattend)**: idioma, disco, imagem, EULA
2. **specialize (Autounattend)**: copia \Deploy do pendrive Ventoy para C:\Deploy e cria a tarefa agendada "DeployBootstrap"
3. **Próximo logon admin**: Deploy.ps1 executa
   - Identifica serial BIOS → calcula hostname
   - Valida adaptador Ethernet (link ativo)
   - Configura DHCP + 802.1X
   - Valida DNS, DC, LDAP
   - **Reboot** (rename do computador em andamento)

### Fase 2: Software + Ingresso AD
4. **Após reboot**: Deploy.ps1 resume
   - Valida hostname aplicado
   - Instala aplicativos (se houver)
   - Valida pré-AD (rede, DNS, DC)
   - Ingressa no domínio (Add-Computer) + **Reboot**

### Fase 3: Validação Pós-AD
5. **Após reboot**: Deploy.ps1 resume
   - Valida membro do domínio
   - Valida Netlogon, Secure Channel
   - **Concluído** (máquina pronta)

Todas as falhas registram logs em `C:\ProgramData\Deploy\deploy.log`.

---

## ⚙️ Configuração Avançada

### Modo de Deployment

```json
"deployment": {
  "mode": "validation",          // "validation" = pausa em checkpoints (interativo)
  "pauseAtCheckpoints": true,    // "silent" = sem pausas (totalmente automático)
  "stateFile": "C:\\ProgramData\\Deploy\\state.json"
}
```

### Validações Adicionais

```json
"computador": {
  "validarSerial": true,          // Rejeita seriais genéricos
  "verificarDuplicidadeNoAd": false // (Futuro) verificar hostname duplicado no AD
},
"dominio": {
  "validarDns": true,             // Valida resolvabilidade do FQDN
  "validarDc": true,              // Valida conectividade ao DC
  "validarSecureChannel": true    // Valida Secure Channel pós-AD
}
```

### Instaladores de Aplicativos

```json
"aplicativos": [
  {
    "arquivo": "SetupApp.exe",
    "argumentos": ["/quiet", "/norestart"],
    "codigosSaidaEsperados": [0, 3010],
    "validacao": {
      "tipo": "file",
      "caminho": "C:\\Program Files\\App\\app.exe"
    }
  }
]
```

---

## 🐛 Troubleshooting

### Setup falha com 0x8007000D - 0x40030 na etapa de disco
- Atualizar Ventoy (1.1.17); família 0x400xx no 24H2 é quase sempre Ventoy antigo
- Validar SHA256 da ISO; trocar pendrive/porta
- `Shift+F10` → `diskpart` → `list disk`: disco ausente/dinâmico = BIOS em RAID/VMD ou disco a limpar
- Coletar `X:\Windows\Panther\setuperr.log` antes de mexer no XML (ANALISE.md §3)

### C:\Deploy_copy_status.txt diz ERRO_DEPLOY_NAO_ENCONTRADO_EM_NENHUMA_UNIDADE
- A pasta \Deploy precisa estar na raiz da partição de dados do pendrive Ventoy
- Pendrive foi removido antes do 1º boot do Windows instalado? Precisa ficar até o specialize terminar

### Deploy.ps1 não dispara após instalação
- Verificar C:\Deploy_schtasks_status.txt → se houver ERRO_*, revisar condições
- Testar logon com conta administradora local
- Revisar que C:\Deploy\Deploy.ps1 foi copiado corretamente

### Falha 802.1X — "não autenticado"
- Validar LAN.xml tem credenciais/certificados corretos
- Revisar que authMode/ssoMode no config.json correspondem ao perfil LAN.xml
- Aumentar timeout em Network.ps1 (loop 12 × 5s = 60s) se switch demorar

### Ingresso no AD falha — "credenciais inválidas"
- Verificar conta deploy.join tem permissão Add-Computer no AD
- Revisar FQDN/DC no config.json são acessíveis (nslookup/nltest)
- Testar credencial manualmente em máquina de referência

### Deploy não retoma após reboot — "estado perdido"
- Verificar C:\ProgramData\Deploy\state.json existe e é legível
- Revisar que tarefa agendada "DeployBootstrap" não foi removida
- Logon com conta administradora

---

## 📋 Checklist Pré-Produção

- [ ] autounattend.xml ajustado (DiskConfiguration, ImageInstall, linguagem)
- [ ] config.json preenchido (domínio, unidade, interfaces)
- [ ] LAN.xml com perfil 802.1X real (não marcador EXPORTAR_PERFIL_REAL)
- [ ] ISO Windows 11 validada (hash, não corrompida)
- [ ] Ventoy configurado corretamente
- [ ] Deploy-Windows/ injetado em Ventoy
- [ ] Testado em VM (ambos BIOS e UEFI se possível)
- [ ] Conta deploy.join criada no AD com permissões
- [ ] Máquinas-alvo têm conectividade 802.1X validada

---

## 🔒 Segurança

- **Credenciais**: mode "prompt" (usuário insere manualmente em runtime) — nunca armazenadas em config.json
- **Tarefa agendada**: contexto SYSTEM (elevado automaticamente)
- **Logs**: sensíveis (contêm hostname, serial, domínio) — proteger acesso a C:\ProgramData\Deploy\
- **Autounattend**: sensível (inclui linguagem, layout de disco) — não usar template direto em produção

---

## 📝 Licença

Seu projeto. Documentado via Deploy-Windows v1.

---

## 📞 Suporte

Veja `ANALISE.md` para detalhes técnicos de erro 0x8007000D.

Dúvidas de implementação:
1. Consultar comentários em `Deploy.ps1` (Orchestrator)
2. Revisar scripts em `Scripts/` (cada função documentada)
3. Testar em VM antes de produção

---

**Versão:** 1.0 (corrigida)  
**Última atualização:** 2026-09-14  
**Autores:** Pedro Oliveira, Documentação/Análise
