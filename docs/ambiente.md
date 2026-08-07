# Ambiente real — site Itatiba

Todos os valores abaixo foram validados na prática. Use-os exatamente como estão.

## Topologia: Ring 0 e Ring 1

A empresa organiza o PI em duas camadas permanentes que coexistem por desenho.
**Não é migração** — não há lado "legado" nem prazo para desligar nada.

- **Ring 0 — Site**: servidor no chão de fábrica, escopo de um site
- **Ring 1 — Cloud**: infraestrutura corporativa, agrega todos os sites Novecare; alimenta PI Vision e SEEQ

| Ambiente | `tier` | Data Archive | AF Server | AF Database |
|---|---|---|---|---|
| `ita-site` | `site` | `ITA_NOVECARE` | `BRITAMS01-SV01` | `ITA_NOVECARE` |
| `ita-cloud` | `cloud` | `ASEW1PSTEKPDA01` | `asew1pstekpAF02` | `ITA_NOVECARE` |

### GUIDs — a identidade que vale

| Objeto | GUID |
|---|---|
| DA `ITA_NOVECARE` | `349d4525-1be3-4497-8004-1dced4a16d14` |
| DA `ASEW1PSTEKPDA01` | `55d60fe8-a621-4d05-b286-49da429d87c7` |
| AF `BRITAMS01-SV01` | `136b3cdd-46b5-4094-bc1c-5ee37000f4c3` |
| AF `asew1pstekpAF02` | `ec1a3fec-7153-43cb-b4d4-d5dc78ef1613` |
| DB `ITA_NOVECARE` (site) | `9d02f7c2-6822-4dbe-a90e-a965a31ce2b9` |
| DB `ITA_NOVECARE` (cloud) | `58ec8775-f566-46c6-b3c2-a7e0aecaf283` |

> ⚠️ **Os dois `ITA_NOVECARE` não são réplica.** Os GUIDs são diferentes: são objetos independentes
> que evoluíram separadamente — 391 analyses no site contra 420 na cloud. O diagrama corporativo
> descreve a intenção arquitetural; o GUID descreve a realidade. **Confie no GUID.**

> ⚠️ **`Configuration` tem o mesmo GUID (`dee1a62d…`) nos dois AF Servers.** Nem GUID de database é
> globalmente único — só o par `(af_server_id, af_database_id)` desempata.

## Versões e permissões

| Item | `ita-site` | `ita-cloud` |
|---|---|---|
| Versão do Data Archive | `3.4.460.29` | `3.4.445.688` |
| Versão do AF | `2.10.12.73` | `2.10.9.593` |
| Host do DA | `britams01-sv01.oxo.priv` | `ASEW1PSTEKPDA01` |
| Identities no AF | `MES-Admin`, `MES-PIVision-Publishers`, `MES-PIVision-Explorers`, `World` | `ITA_NOV_standard`, `ITA_NOV_advanced` |

Usuário: `oxo\dasi0558`. Autenticação **integrada do Windows** — nunca colocar credenciais em arquivo.

Cliente instalado: PI System Explorer 2023 Patch 2 (64-bit), AF SDK 3.0.2.5, módulo `OSIsoft.PowerShell`.
Assembly em `C:\Program Files (x86)\PIPC\AF\PublicAssemblies\4.0\OSIsoft.AFSDK.dll`.

> ⚠️ `MES-Admin` **pode deletar PI Points**, e deletar apaga o histórico de forma irreversível.
> É por isso que este repositório é read-only. Ver a regra no [README](../README.md).

> ⚠️ O **Default PI System da máquina aponta para `asew1pstekpAF02`** (Ring 1). Nunca use
> `DefaultPISystem`. Ver [armadilha 6](armadilhas.md).

## Degradação declarada

| Ambiente | Dataset | Sinal | Motivo |
|---|---|---|---|
| `ita-cloud` | `analyses` | `FallbackListOnly` | `QueryRuntimeInformation` falha com *"A call to SSPI failed"*. O inventário é coletado, mas sem status de runtime. |

Fica visível no dado pela coluna `status_source` e **não eleva o exit code** — está declarado em
`knownDegradations` no settings.json. Degradação nova, não declarada, continua gerando exit 2.

## Volume e desempenho medidos

Coleta completa dos dois ambientes em 2026-08-07: **15,6 min**, exit code 0.

| Dataset | `ita-site` | tempo | `ita-cloud` | tempo |
|---|---:|---:|---:|---:|
| `pipoints` | 3.472 | 17 s | 3.150 | 24 s |
| `digitalsets` | 536 | 9 s | 383 | 4 s |
| `elements` | 106 | 9 s | 93 | 8 s |
| `attributes` | 3.485 | 17 s | 2.674 | 24 s |
| `templates` | 212 | 8 s | 211 | 7 s |
| `eventframes` (30 d) | 13.589 | 173 s | **31.429** | **379 s** |
| `analyses` | 391 | 109 s | 420 | 114 s |
| `analysis_outputs` | 639 | 4 s | 645 | 7 s |
| `enumsets` | 57 | 2 s | 58 | 2 s |
| `uom` | 208 | 0,1 s | 256 | 0,1 s |
| `tables` | 1 | 0,6 s | 1 | 0,5 s |
| **Total** | **22.696** | **356 s** | **38.920** | **577 s** |

> `eventframes` e `analyses` consomem **~78% do tempo**. Se a janela do PAD apertar, é neles que se
> mexe — reduzindo a janela de EF **nos dois ambientes**, nunca em um só, senão os números ficam
> incomparáveis.

## Qualidade do parser de ConfigString

| Ambiente | `resolution_rate` |
|---|---|
| `ita-site` | **0,9941** (3.349 de 3.369) |
| `ita-cloud` | **0,9984** (2.570 de 2.574) |

Nenhum `unparsed` nos dois. Com esses números conhecidos, dá para fixar `resolutionRateBaseline`
por ambiente e alarmar em queda relativa em vez de limite absoluto.

## Referência cruzada entre camadas

Medido no `ita-cloud`:

| `resolved_server_id` | Atributos | Significado |
|---|---:|---|
| `55d60fe8…` | 2.247 | apontam para o próprio DA da cloud |
| `349d4525…` | **323** | **apontam para o DA do site** |

Exemplos: `Alarmes.CALDEIRA<22%`, `Alarmes.EMERGÊNCIA_K21`.

É a razão de `source_server_id` e `resolved_server_id` serem colunas distintas — a divergência é
sinal, não erro. Ver [arquitetura.md](arquitetura.md).

## Escopo e candidatas à fase 2

Escopo atual: apenas o par `ita-site` + `ita-cloud`, ambos sobre o database `ITA_NOVECARE`.

Databases com conteúdo real ainda fora de escopo, todas no AF `asew1pstekpAF02`:

| Database | Raízes | Templates | Analyses | Observação |
|---|---:|---:|---:|---|
| `OSP_NOVECARE_v2` | 8 | 88 | 166 | maior candidata |
| `CMY_NOVECARE_LECL` | 2 | 36 | 96 | |
| `Standard` | 0 | 271 | 0 | biblioteca de templates; provavelmente nunca entra |

Fora de escopo por natureza: `AF-MES` e `Configuration` (infraestrutura),
`Base de données1-to delete` e `Test sur AF02` (vazias),
`frcivas41.oxo.priv` (Data Archive com **acesso negado**).

Adicionar qualquer uma delas é uma entrada nova em `environments` no settings.json — sem tocar em código.

## Estrutura

| Item | `ita-site` | `ita-cloud` |
|---|---|---|
| Elements raiz | `Itatiba`, `Systems` | `Itatiba`, `Systems` |
| Element templates | 6 | 5 |
| Event Frame templates | 25 | 26 |

Exemplo de path: `Itatiba\Produção\Reactors\K21000`. Reatores seguem o padrão `K21000`, `K28000`.

> ⚠️ O template `BatchsheetTriggers` citado no levantamento inicial **não existe** em nenhum dos
> dois. Os reais incluem `Phase`, `Reaction-Batch`, `PIUnitBatch`, `CMA_batch`. Ver
> [armadilha 16](armadilhas.md).

## Estado da planta na primeira leitura

| Sinal | `ita-site` |
|---|---|
| Analyses em `Error` | **30 de 391** |
| Analyses em `Stopped` | 19 |
| Tags que nunca receberam dado | 87 |
| Tags com snapshot ruim | 186 |
| Tags stale (> 24 h) | 1.792 |

O `ita-cloud` não tem status de runtime de analyses por causa da degradação declarada acima.

> ⚠️ **52% de tags stale não significa 52% de interfaces paradas.** Ver a ressalva sobre compressão
> em [arquitetura.md](arquitetura.md).

## Sinais de que algo mudou no ambiente

Pare e revalide antes de confiar nos dados se aparecer:

- versão de DA ou AF diferente das tabeladas acima
- contagem de PI Points distante de 3.472 (site) ou 3.150 (cloud)
- `duration_ms` de qualquer dataset subindo em ordem de grandeza — indica que o carregamento em
  lote parou de funcionar
- `resolution_rate` caindo mais de 2 pontos percentuais do baseline
- GUID de servidor ou database diferente dos tabelados — significa servidor recriado, não atualizado
