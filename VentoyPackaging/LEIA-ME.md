# Empacotamento rev. 6

O procedimento único está no [README](../README.md#preparar-um-pacote).

Execute `Build-VentoyPayload.ps1` no Windows PowerShell 5.1, informando configuração real, saída nova fora do repositório, índice conferido via DISM e caminho exato da ISO no USB.

O build produz `Deploy/` descompactado, `ventoy/ventoy.json`, `ventoy/deploy/autounattend.xml` e `package-info.json`. Copie o payload para a raiz do USB e integre a entrada Ventoy gerada. Mantenha o USB conectado até acabar o pass specialize.

Não há mais `deploy-payload.7z`, plugin `injection` ou XML antigo para copiar. Uma pasta injetada em X: não persiste automaticamente no Windows instalado. O template `Autounattend/autounattend-fixed.xml` contém marcadores e só deve ser consumido pelo build.

Por padrão, o disco é escolhido no Setup. Para apagamento automático, `-TargetDiskId` e `-ConfirmDiskErase` são obrigatórios em conjunto; conferir o ID no WinPE do equipamento alvo antes de iniciar. O build não consegue confirmar o disco da Dell a partir de outro computador.

O pacote tem um identificador para evitar selecionar uma pasta Deploy antiga em outra unidade e um manifesto SHA256 para detectar cópia incompleta. Não edite arquivos avulsos depois de gerar; reconstrua o pacote. O manifesto verifica integridade, não substitui uma assinatura de procedência.

Leia também o [procedimento de recuperação](../README.md#recuperar-uma-falha). As retomadas exigem a mesma conta administrativa local. O build e os testes não constituem homologação da ISO, do hardware, da autenticação ou dos instaladores reais.
