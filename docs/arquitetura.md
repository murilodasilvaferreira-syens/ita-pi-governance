# Arquitetura

## Visão geral

```
[MÁQUINA COM PI SDK]                          [NUVEM]

Power Automate Desktop (unattended, agendado)
        │
        ├─► PowerShell + AF SDK (read-only)
        │        └─► CSV datado
        │              D:\PI_Inventory\raw\<yyyy-MM-dd>\
        │
        ├─► copia p/ OneDrive sincronizado ──► SharePoint
        │                                          │
        └─► exit 0 ─► Power Automate cloud ─► Dataflow Gen2
                                                   │
                                                   ▼
                                       Microsoft Fabric Lakehouse
                                         bronze → silver → gold
                                                   │
                                                   ▼
                                             Power BI
                                    (relatório + embed SharePoint)
```

O padrão *file-drop* via OneDrive elimina a necessidade de On-premises Data Gateway.
O Fabric nunca alcança o PI diretamente, e nenhuma credencial nova é introduzida.

## Disparo do Dataflow: por evento, não por horário

Agendar o Dataflow Gen2 por horário cria uma corrida: se o PAD atrasar, o Dataflow lê pasta vazia
ou parcial. A cadeia correta é event-driven — mas a **direção é o contrário do intuitivo**: não é o
PAD que chama a nuvem, é a nuvem que chama o PAD.

```
Fluxo cloud (gatilho: agendamento)
  └─► "Run a flow built with Power Automate for desktop" (unattended)
        └─► recebe o exit code como variável de saída
              └─► 0 ou 2 → Refresh do Dataflow Gen2 → notebook 01_bronze_ingest
              └─► 1     → notifica e encerra
```

É o padrão nativo do Power Automate: sem endpoint HTTP a proteger, com retry e tratamento de erro
prontos, e o exit code chega tipado em vez de serializado.

> Exit code `2` **não** barra a ingestão. O bronze descarta apenas os datasets que falharam;
> impedir o ciclo inteiro por um dataset degradado perderia os outros dez.

**Fallback aceitável:** se a ação de fluxo desktop não estiver disponível na licença, agendamento
por horário funciona, porque o `01_bronze_ingest` valida o `_manifest.json` e descarta run parcial.
O pior caso vira um ciclo perdido, não dado corrompido — e o ciclo seguinte reprocessa, já que a
ingestão é idempotente por `run_id`.

Detalhes de configuração em [pad/README.md](../pad/README.md).

## Frequências de coleta

| Coleta | Frequência | Racional |
|---|---|---|
| **Metadata** (estrutura) | 1x/dia | muda pouco |
| **Health** (estado) | 2–4x/dia | muda o tempo todo |

## Artefatos de controle

Cada execução produz dois arquivos JSON com papéis deliberadamente separados.

### `_manifest.json` — viaja junto com os dados

Consumido pelo `01_bronze_ingest` para decidir se o run é íntegro.

```jsonc
{
  "run_id": "...",
  "run_type": "metadata",
  "snapshot_date": "2026-08-06",
  "module_version": "0.1.0",
  "datasets": [
    { "dataset": "pipoints", "status": "success", "row_count": 1987,
      "duration_ms": 4120, "file": "pipoints__20260806T060312.csv", "error": null },
    { "dataset": "attributes", "status": "success", "row_count": 14302,
      "duration_ms": 51880, "metrics": { "resolution_rate": 0.97, "parse_status_counts": { } } }
  ]
}
```

### `_transfer.json` — **nunca sai da máquina**

Registra o resultado da cópia para o OneDrive. É a **única** fonte que autoriza
`Remove-ExpiredSnapshot` a apagar um snapshot local.

A separação existe porque o `_manifest.json` é copiado *antes* de a transferência terminar — se o
status da cópia morasse nele, a versão que chega ao SharePoint carregaria `pending` para sempre.

### O manifesto também é um dataset

O `01_bronze_ingest` ingere o próprio `_manifest.json` como `bronze_run_manifest`, alimentando
`gold_vw_run_performance`. Duração só vira detecção de degradação se for série temporal: num JSON
local, ninguém percebe o dia em que o carregamento em lote parou de funcionar — percebe seis meses
depois, quando o PAD começar a estourar a janela de execução.

## Camadas no Fabric (medallion)

| Camada | Conteúdo |
|---|---|
| **bronze** | CSV bruto convertido para Delta, particionado por `snapshot_date`, append-only, nunca alterado |
| **silver** | tipado e limpo — `silver_dim_pipoint`, `silver_dim_element`, `silver_dim_attribute`, join AF↔PI via `resolved_tag` |
| **gold** | `fact_tag_health` e as views de diagnóstico abaixo |

Lakehouse: `lh_pi_governance`. Prefixos de tabela: `bronze_*`, `silver_dim_*`, `gold_*`.

### Objetos gold

Materializados pelo notebook `03_gold_views` (exigem janela sobre a série histórica):

| Tabela | Conteúdo |
|---|---|
| `gold_snapshot_pair` | pares de snapshots consecutivos, com `gap_hours` e `delta_status` |
| `gold_fact_tag_health` | estado de cada tag cruzado com metadados e cobertura no AF |
| `gold_delta_tag_criada` | tags novas entre dois snapshots |
| `gold_delta_tag_removida` | tags ausentes, com `removal_status` |
| `gold_delta_atributo_alterado` | mudança de ConfigString, DR, UOM ou tipo |
| `gold_attribute_public` / `gold_attribute_full` | superfícies de consumo do dataset de atributos |
| `gold_run_performance` | duração por dataset com média móvel e flag de degradação |

Views T-SQL em `fabric/sql/gold_views.sql` (filtros sobre o snapshot atual):

| View | Sinal |
|---|---|
| `gold_vw_tags_orfas` | PI Point sem nenhum atributo AF apontando para ele |
| `gold_vw_tags_stale` | sem update há mais de `staleThresholdHours` |
| `gold_vw_interface_suspeita` | proporção de tags stale por pointsource acima da própria base histórica |
| `gold_vw_tags_sem_dados` | nunca recebeu dado (**heurístico**, sem alerta) |
| `gold_vw_dr_quebrado` | atributo AF apontando para tag inexistente |
| `gold_vw_tag_renomeada` | point id resolve para tag de nome diferente do ConfigString |
| `gold_vw_analysis_erro` | analysis em erro ou parada |
| `gold_vw_cobertura_reator` | atributos ligados vs. total por reator `K#####` |
| `gold_vw_delta_tag_criada` | tag nova |
| `gold_vw_delta_tag_removida` | **só `confirmed`** — alerta forte |
| `gold_vw_coleta_instavel` | tags que sumiram e voltaram: falha de pipeline, não de tag |
| `gold_vw_delta_atributo_alterado` | mudança estrutural no AF |
| `gold_vw_lacunas_de_coleta` | intervalos sem snapshot |
| `gold_vw_run_performance` | degradação de coleta |
| `gold_vw_alertas` | feed consolidado, ordenado por custo de não perceber |

**A divisão é intencional:** o que precisa de `LAG`/`LEAD` sobre a série inteira é calculado em
Spark e materializado; o que é filtro sobre o snapshot atual vira view T-SQL, mais barata de
manter e direta no Power BI.

## O join AF ↔ PI

É a peça que sustenta metade das views. O `ConfigString` de um atributo com Data Reference
`PI Point` contém o nome da tag. O formato real deste AF não é o óbvio `\\SERVER\TAG`:

```
\\ITA_NOVECARE?349d4525-1be3-4497-8004-1dced4a16d14\K21000.Pressão_PV?29
  \__ servidor _/ \_______ GUID do servidor ________/ \___ tag ___/ \id/
```

O parser (`ConvertFrom-AFConfigString`) usa o **último** `\` para separar servidor de tag e trata
`?` como delimitador de sufixo — esse caractere é ilegal em nome de tag do PI. Quando o sufixo é
numérico, é o **PI Point ID**, capturado em `resolved_point_id`.

**A resolução real do Data Reference nunca é feita no PowerShell** — chamar `$attr.PIPoint` faria
round-trip por atributo e lançaria exceção em DR quebrado, que é justamente o que queremos *medir*,
não sofrer. A detecção de órfão e de DR quebrado é um `LEFT JOIN` no silver.

### Duas chaves de join, nesta ordem

| Chave | Liga | Vantagem |
|---|---|---|
| `resolved_point_id` ↔ `pointid` | atributo AF ↔ PI Point | **sobrevive a rename da tag** |
| `resolved_tag` ↔ `name` | atributo AF ↔ PI Point | funciona quando o DR não guarda o ID |

Divergir entre as duas é sinal em si: se o `point_id` resolve para uma tag com **nome diferente** do
`resolved_tag`, alguém renomeou a tag e o AF ainda carrega o nome antigo no ConfigString.

### `resolution_rate` — a falha mais provável do projeto

Se o parser não cobrir algum formato de `ConfigString` presente no seu AF, as views de tags órfãs e
DR quebrado ficam **silenciosamente erradas**. Por isso a taxa de resolução é medida em toda
execução e gravada no manifesto:

```
resolution_rate = atributos com parse_status 'resolved'
                  ÷ atributos com Data Reference 'PI Point' e ConfigString não vazio
```

Estratégia em duas etapas:

1. **Enquanto `thresholds.resolutionRateBaseline` for `null`** — usa o absoluto
   `minResolutionRate: 0.9` e `resolutionRateSeverity: "warn"`. O objetivo do primeiro run é
   *descobrir o número real*, não falhar.
2. **Depois de conhecer a taxa** — fixe `resolutionRateBaseline` com o valor observado. O alarme
   passa a ser **queda relativa maior que 2 pontos percentuais**, e a severidade pode virar `"fail"`
   (exit code 2).

Quando a taxa cai abaixo do limite, o log **amostra 10 `ConfigString` que falharam no parse**. Sem
essa amostra você sabe que quebrou, mas não o quê — e teria que reproduzir manualmente.

O `parse_status` distingue os motivos, para que "não resolveu" não seja confundido com "parser com bug":

| `parse_status` | Significado |
|---|---|
| `resolved` | tag extraída — entra no numerador |
| `dynamic_tag` | contém substituição `%…%` não expandida |
| `not_pi_point` | DR de outro tipo (Formula, Table Lookup, String Builder…) |
| `empty` | sem `ConfigString` |
| `unparsed` | formato não reconhecido — **é este que indica bug no parser** |

Medição da primeira execução real (2026-08-06): `resolution_rate = 0,9941`, com 3.349 resolvidos de
3.369, 20 `dynamic_tag` legítimos, 9 `not_pi_point` e nenhum `unparsed`.

> Cuidado com o `%`: nem todo por cento é substituição do AF. Tags como `K21000.BatchStep_MCA70%`
> são válidas. Ver [armadilha 10](armadilhas.md).

## Regras de delta

Delta é o que entrega o valor de "monitoramento contínuo", e também o que mais facilmente vira
alarme que ninguém lê. Três guardas:

1. **Dois snapshots consecutivos são obrigatórios.** Nunca calcular delta contra o vazio. Sem isso o
   primeiro run marca 2.000 tags como criadas e o dashboard nasce desacreditado.
2. **Gap fica visível.** Intervalo entre snapshots maior que `maxDeltaGapHours` (48h) marca
   `delta_status = 'gap'` em vez de ser ignorado — a lacuna aparece no Power BI, não vira buraco
   silencioso na série.
3. **Remoção exige confirmação dupla.** Tag ausente em um snapshot é `candidate`; ausente em dois
   consecutivos é `confirmed`. **Só `confirmed` alerta.** Uma tag que sumiu e voltou era falha de
   coleta, não remoção.

Três sinais separados (`tag_criada`, `tag_removida`, `atributo_alterado`) em vez de um delta único:
misturá-los produz um alerta genérico que ninguém consegue acionar.

## `has_ever_received_data` é heurístico — leia antes de usar
> ⚠️ **Este sinal não é garantia.** Ele combina o estado de sistema `Pt Created` no snapshot com a
> comparação entre `snapshot_ts` e `creationdate`. Ambos os sinais **falham** nestes casos:
>
> - PI restaurado de backup — timestamps e estados são reescritos
> - tag que recebeu dado uma vez, há muito tempo, e foi abandonada
> - tag realimentada depois de um período parado
>
> **Nunca delete uma tag baseado apenas nesta view.** Delete apaga o histórico e é irreversível.
> `gold_vw_tags_sem_dados` nasce **sem alerta conectado**, de propósito: primeiro meça a distribuição
> do primeiro run, depois decida se vira alerta.

Medir primeiro, alertar depois.

## `is_stale` não é o mesmo que interface parada

Na primeira leitura, **1.792 das 3.472 tags (52%) apareceram como stale** com limite de 24 h.
Isso não significa metade da planta parada.

O snapshot do PI guarda o último valor **arquivado**. Com compressão ligada, uma tag estável pode
legitimamente passar dias sem gravar nada — e ainda assim a interface está viva. `is_stale` sozinho
confunde "tag parada" com "tag quieta".

O sinal confiável de interface parada é **agregado, no gold**, não por tag:

```
interface suspeita = pointsource onde a proporcao de tags stale
                     e' muito maior que a media historica desse mesmo pointsource
```

Por isso o export entrega `is_stale`, `age_hours` e `pointsource` crus e **não decide nada**.
A regra fica no Fabric, onde dá para comparar contra a linha de base de cada pointsource e reescrever
sem tocar no PI. Calibrar `staleThresholdHours` por pointsource tende a ser mais útil que um limite
único global.

## Campos sensíveis

`exdesc`, `instrumenttag` e `ConfigString` podem conter caminhos internos, IPs ou strings de conexão.

A decisão é **manter o valor e sinalizar**, não mascarar: mascarar o `ConfigString` destruiria o
join AF↔PI, que é o ativo central do projeto. A coluna `has_sensitive_hint` marca a linha quando
qualquer padrão de `sensitiveHints.patterns` casa.

O controle acontece na **superfície de consumo**, não no dado:

| Objeto gold | `config_string` cru | Uso |
|---|---|---|
| `gold_attribute_public` | ❌ ausente | relatório publicado, embed no SharePoint |
| `gold_attribute_full` | ✅ presente | diagnóstico, acesso restrito |

O relatório publicado consome `gold_attribute_public`. O dado bruto continua existindo no silver
para quem precisa diagnosticar um DR mal configurado — mas não aparece para quem abre o dashboard.

## Alertas prioritários

Ordenados por custo de não perceber:

| Alerta | Origem | Severidade |
|---|---|---|
| Tag removida (confirmada) | `gold_vw_delta_tag_removida` | 🔴 delete apaga histórico |
| Tag stale | `gold_vw_tags_stale` | 🟠 interface parada |
| Analysis em erro | `gold_vw_analysis_erro` | 🟠 falha silenciosa muito comum |
| DR quebrado | `gold_vw_dr_quebrado` | 🟡 |
| Tag nova não catalogada | `gold_vw_delta_tag_criada` | 🟡 criada fora do processo |
| Degradação de coleta | `gold_vw_run_performance` | 🟡 |

Entrega via Power BI Data Alert ou Power Automate.
