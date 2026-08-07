# Power Automate Desktop — configuração do fluxo unattended

Este documento descreve como agendar a coleta na máquina que tem o PI SDK.

> **READ-ONLY.** Os scripts chamados aqui não escrevem nada no PI System. Ver [README](../README.md).

---

## Pré-requisitos na máquina

| Item | Verificação |
|---|---|
| PI System Explorer / AF SDK | `tests\Test-Connectivity.ps1` reporta a versão do SDK |
| Módulo `OSIsoft.PowerShell` | idem |
| Repositório clonado localmente | ex.: `C:\ita-pi-governance` |
| Pasta de saída gravável | `Test-Connectivity` valida e classifica o drive |
| Pasta OneDrive sincronizada | `Test-Connectivity` valida |

Rode o teste **com a conta que o PAD vai usar**, não com a sua:

```powershell
.\tests\Test-Connectivity.ps1
```

---

## Três armadilhas da sessão unattended

Estas quebram o fluxo mesmo quando tudo funciona na sessão interativa.

### 1. Drive de rede mapeado não existe

Se `output.baseDir` apontar para uma letra mapeada (`Z:\`), a sessão unattended não a enxerga —
o mapeamento pertence ao usuário interativo. Use caminho **UNC** ou **local**.

`Test-Connectivity.ps1` classifica o drive e avisa explicitamente quando detecta `DriveType = 4`.

### 2. A pasta do OneDrive é do perfil do usuário

`C:\Users\<usuario>\Syensqo SA\...` só existe para aquele usuário. **O PAD precisa rodar com a
mesma conta** que sincroniza a biblioteca. Rodar com uma conta de serviço genérica faz a
transferência falhar todo dia — e, por desenho, o snapshot local nunca é apagado quando a
transferência falha, então o disco cresce até alguém perceber.

### 3. O OneDrive precisa estar rodando

Copiar o arquivo para a pasta não é o mesmo que sincronizar. Se o cliente do OneDrive não estiver
em execução na sessão, os arquivos ficam parados no disco. Confirme que o OneDrive inicia com a
sessão da conta de serviço.

---

## Estrutura do fluxo

Use a ação **Run application** (não "Execute PowerShell script"): ela expõe o código de saída,
que é o contrato entre o script e o fluxo.

| Campo | Valor |
|---|---|
| Application path | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` |
| Command line arguments | `-NoProfile -ExecutionPolicy Bypass -File "C:\ita-pi-governance\src\Invoke-MetadataSnapshot.ps1"` |
| Working folder | `C:\ita-pi-governance` |
| Window style | Hidden |
| Wait for completion | **Sim** |

A ação devolve a variável de código de saída (`AppExitCode` ou equivalente na sua versão).

### Tratamento do código de saída

```
Se AppExitCode = 0
    → coleta íntegra. Segue para a atualização do Dataflow Gen2.

Senão se AppExitCode = 2
    → há dados, mas algo merece atenção (dataset falhou, transferência parcial,
      resolution_rate abaixo do limite).
      Segue para a atualização do Dataflow Gen2 E notifica o time.
      Ignorar o 2 é perder justamente o alerta que o sistema existe para dar.

Senão (1 ou qualquer outro)
    → falha fatal, nenhum dado produzido. NÃO atualiza o Dataflow.
      Notifica e encerra.
```

> Repare que `2` **não** impede a ingestão. O bronze valida o manifesto e descarta apenas os
> datasets que falharam; barrar o ciclo inteiro por um dataset degradado perderia os outros dez.

### Log da execução

O script grava log estruturado em `<baseDir>\logs\<yyyy-MM-dd>\<runtype>__<stamp>.log`
(uma linha JSON por evento). Anexe esse caminho na notificação de erro — ele contém a amostra
de `ConfigString` que falhou no parse, que é o que permite diagnosticar sem reproduzir.

---

## Agendamento

| Fluxo | Script | Frequência | Janela sugerida |
|---|---|---|---|
| Metadata | `Invoke-MetadataSnapshot.ps1` | 1x/dia | madrugada, 10 min de folga |
| Health | `Invoke-HealthSnapshot.ps1` | 2–4x/dia | a cada 6 h, 3 min de folga |

**Sobre a folga:** a coleta de metadados foi medida entre 140 s e 281 s em execuções idênticas,
com o dataset `analyses` variando de 8 s a 125 s. Dimensione com margem e acompanhe a evolução em
`gold_vw_run_performance` — é exatamente para isso que a duração por dataset vai para o manifesto.

Os dois fluxos podem rodar na mesma máquina; cada execução grava com timestamp próprio e não
colide com as outras na pasta datada.

---

## Encadeamento com o Fabric

O objetivo é eliminar a corrida: se o Dataflow rodar por horário e o PAD atrasar, o Dataflow lê
pasta vazia ou parcial.

### Recomendado — o fluxo cloud orquestra

Em vez de o PAD chamar a nuvem, é a nuvem que chama o PAD. É o padrão nativo do Power Automate e
não exige expor nenhum endpoint:

```
Fluxo cloud (gatilho: agendamento)
  └─► ação "Run a flow built with Power Automate for desktop"  (modo unattended)
        └─► recebe a variável de saída com o exit code
              └─► se 0 ou 2: ação "Refresh a dataflow" (Dataflow Gen2)
                    └─► o Dataflow dispara o notebook 01_bronze_ingest
              └─► se 1: notifica e encerra
```

Vantagens sobre o PAD chamar a nuvem: sem endpoint HTTP para proteger, retry e tratamento de erro
nativos, e o exit code chega como variável tipada em vez de precisar ser serializado.

Para isso o script precisa devolver o código como **variável de saída** do fluxo desktop: crie uma
variável de saída no PAD e atribua a ela o `AppExitCode`.

### Alternativa aceitável — agendamento por horário

Se a ação de fluxo desktop não estiver disponível na sua licença, agendar o Dataflow para depois
da janela do PAD funciona. O `01_bronze_ingest` valida o manifesto e descarta run parcial, então o
pior caso é **um ciclo perdido, não dado corrompido** — e o ciclo seguinte reprocessa, porque a
ingestão é idempotente por `run_id`.

---

## Verificação depois de configurar

1. Rode o fluxo manualmente e confirme `RESULTADO: success | exit 0` no log.
2. Confira que os CSVs e o `_manifest__*.json` chegaram na pasta datada do SharePoint.
3. Confirme que **`_transfer__*.json` NÃO** aparece no SharePoint — ele é local por desenho e é a
   única coisa que autoriza a purga a apagar o snapshot.
4. Force uma falha (renomeie o AF Database no `settings.json`) e confirme que o fluxo trata o
   código 2 sem parar o pipeline.
5. Depois de 60 dias, confirme que a purga está removendo pastas antigas — se não estiver,
   procure no log a linha "Snapshot vencido preservado", que diz o motivo.
