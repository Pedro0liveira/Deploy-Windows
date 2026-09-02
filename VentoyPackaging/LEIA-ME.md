# Empacotamento no Ventoy

Este pacote não altera o Ventoy nem as ISOs. Ele usa os plugins nativos **Auto Install** e **Injection**.

## Preparar o payload

1. Ajuste manualmente `Deploy/config.json` para o cliente/unidade do teste.
2. Substitua `Deploy/Network/LAN.xml` pelo perfil exportado da referência. Não edite o marcador entregue como se fosse um perfil utilizável.
3. Coloque os executáveis declarados em `config.json` dentro de `Deploy/Temp/` e defina seus argumentos e códigos de saída reais.
4. Complete e valide `Deploy/Autounattend/autounattend.xml` em VM para a ISO escolhida. Os campos `__EDITAR_ANTES_DE_USAR__` impedem uso seguro sem esta adaptação.
5. Compacte a pasta `Deploy` inteira, preservando-a na raiz do arquivo. Exemplo visual esperado no arquivo `deploy-payload.7z`:

   ```text
   Deploy/
     config.json
     Deploy.ps1
     Scripts/
     Network/
     Temp/
   ```

6. Copie o arquivo compactado para `/ventoy/deploy/deploy-payload.7z` e copie o autounattend ajustado para `/ventoy/deploy/autounattend.xml`.
7. No VentoyPlugson, aplique o conteúdo de `ventoy.json` deste diretório. O arquivo final deve ficar em `/ventoy/ventoy.json` na unidade Ventoy.

## ISOs por cliente/unidade

Quando uma ISO precisar de um payload próprio, troque `parent` por `image` nos dois blocos. Exemplo:

```json
{
  "image": "/ISO/Cliente-A-Windows11.iso",
  "archive": "/ventoy/deploy/deploy-payload-cliente-a.7z"
}
```

Repita o mesmo `image` no bloco `auto_install`. Assim cada ISO recebe apenas seu `config.json`, instaladores e perfil compatíveis.

## Reinicializações e checkpoints

O orquestrador reinicia uma vez após renomear o computador e uma vez depois do Join AD. Ele registra uma retomada única em `HKLM\\...\\RunOnce`; após cada reboot, entre com um usuário local administrativo caso a ISO não possua logon automático. A retomada mantém os checkpoints visíveis no modo `validation`.

O Join AD é o último passo de configuração. A verificação AD seguinte apenas confirma domínio, DC, DNS, Netlogon e Secure Channel. Mover a máquina para a OU final continua sendo uma tarefa manual.
