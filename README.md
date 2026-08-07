# ita-pi-governance

Monitoramento contínuo do inventário de metadados do PI System (OSIsoft/AVEVA) do site **Itatiba**,
nas duas camadas da topologia corporativa: **Ring 0 (site)** e **Ring 1 (cloud)**.

Extrai diariamente PI Points do Data Archive e Elements/Attributes do AF Server de cada camada,
deposita snapshots datados em SharePoint/OneDrive e alimenta um Lakehouse no Microsoft Fabric
(bronze → silver → gold), visualizado em Power BI.

| Ambiente | `tier` | Data Archive | AF Server | AF Database |
|---|---|---|---|---|
| `ita-site` | `site` | `ITA_NOVECARE` | `BRITAMS01-SV01` | `ITA_NOVECARE` |
| `ita-cloud` | `cloud` | `ASEW1PSTEKPDA01` | `asew1pstekpAF02` | `ITA_NOVECARE` |

> Os dois `ITA_NOVECARE` têm **GUIDs diferentes**: não são réplica, são bases independentes que
> evoluíram em separado. Ver [docs/ambiente.md](docs/ambiente.md).

**Princípio central:** *extração burra, análise esperta*. Os scripts PowerShell não interpretam nada —
apenas despejam dados tabulares. Toda a inteligência (tags órfãs, stale, DR quebrado, escrita
concorrente entre camadas) vive no Fabric, para poder ser reescrita sem tocar no PI.

---

> # ⚠️ REGRA INVIOLÁVEL — ESTE REPOSITÓRIO É READ-ONLY SOBRE O PI SYSTEM
>
> O usuário de execução possui a identity **`MES-Admin`** no PI Data Archive. Isso significa que ele
> **pode deletar PI Points — e deletar apaga o histórico de forma irreversível**.
>
> **Nenhum arquivo de código deste repositório pode conter chamadas de escrita no PI**, nem sequer
> comentadas ou em exemplo. As seguintes operações são proibidas:
>
> | Categoria | Operações banidas |
> |---|---|
> | Criação de PI Point | `CreatePIPoint`, `CreatePIPoints` |
> | Remoção de PI Point | `DeletePIPoint` |
> | Persistência no AF | `.CheckIn()`, `.ApplyChanges()` |
> | Escrita de valores | `UpdateValue`, `UpdateValues`, `.SetValue` |
> | Remoção de objetos | `.Delete()` |
> | Qualquer criação/alteração | elementos, atributos, templates, analyses, event frames |
>
> Scripts de **criação** de tags vivem em **outro repositório**, separado e com outro controle de acesso.
> Se você precisa criar algo no PI, você está no repositório errado.
>
> **Aplicação automatizada:** `tests/Test-ReadOnlyGuard.ps1` varre o código-fonte procurando essas
> chamadas e falha o build. O guarda ignora `README.md` e `docs/`, porque a documentação precisa
> nomear o que está proibido para que a regra seja compreensível — a proibição vale para **código**.

---

## Arquitetura

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
        └─► exit code ─► Power Automate cloud ─► Dataflow Gen2
                                                   │
                                                   ▼
                                       Microsoft Fabric Lakehouse
                                         bronze → silver → gold
                                                   │
                                                   ▼
                                             Power BI
```

O padrão *file-drop* via OneDrive elimina a necessidade de On-premises Data Gateway.
**O Fabric nunca alcança o PI diretamente.**

Detalhes completos em [docs/arquitetura.md](docs/arquitetura.md).

## Estrutura

```
src/           módulo PowerShell e orquestradores
config/        settings.json (versionado) + settings.local.json (override de máquina, ignorado)
tests/         conectividade, guarda read-only e verificação de encoding
fabric/        notebooks e SQL do Lakehouse
pad/           configuração do fluxo Power Automate Desktop
docs/          ambiente, armadilhas e arquitetura
```

## Como rodar

### Antes de tudo

Sempre valide o ambiente antes de qualquer coleta:

```powershell
cd <repo>
.\tests\Test-Connectivity.ps1
```

O script reporta versões, conectividade, permissões e — importante — classifica o drive de saída
como local, de rede ou inexistente. Drive de **rede mapeado não existe em sessão unattended do PAD**;
se aparecer esse aviso, troque por caminho UNC ou local no `config/settings.json`.

Códigos de saída: `0` tudo certo · `1` falha crítica · `2` apenas avisos.

### Coleta

Os dois pontos de entrada do Power Automate Desktop:

```powershell
.\src\Invoke-MetadataSnapshot.ps1    # estrutura, 1x/dia
.\src\Invoke-HealthSnapshot.ps1      # estado, 2–4x/dia
```

Cada um percorre **todos os ambientes habilitados**, com isolamento de falha: se um servidor estiver
fora do ar, o outro é coletado normalmente e o run termina com exit 2, nunca 1.

Parâmetros úteis: `-Environment ita-cloud` para rodar só uma camada, `-Dataset attributes` para só
um dataset, `-SkipTransfer` e `-SkipRetention` para teste local.

Para uso manual do módulo:

```powershell
Import-Module .\src\PIInventory.psd1 -Force
Get-InventoryEnvironment | Format-Table id, name, tier, dataArchive, afServer

$ctx = Initialize-PIConnection -Environment ita-site
Export-PIPointInventory      -Context $ctx
Export-AFAttributeInventory  -Context $ctx
$ctx.Datasets | Format-Table dataset, status, row_count, duration_ms
```

Nenhum export lança exceção: uma falha vira `status = 'failed'` naquele dataset e os demais seguem.

### Verificações do repositório

```powershell
.\tests\Test-ReadOnlyGuard.ps1       # falha se houver escrita no PI em qualquer .ps1
.\tests\Test-SourceEncoding.ps1      # falha se algum .ps1 estiver sem BOM UTF-8
```

As duas rodam no CI a cada PR, junto com PSScriptAnalyzer e a validação do manifesto do módulo.

## Configuração

Tudo fica em `config/settings.json` — **nada é hardcoded nos scripts** e **não há credenciais em
lugar nenhum** (autenticação integrada do Windows).

Para ajustes específicos da sua máquina, crie `config/settings.local.json` com apenas as chaves que
quer sobrescrever; ele tem precedência e é ignorado pelo Git.

| Chave | Papel |
|---|---|
| `environments[]` | um por camada: `id`, `name`, `tier`, `site`, `siteName`, servidores, `enabled` |
| `environments[].id` | `^[a-z0-9-]+$` e único — vira segmento de nome de arquivo e chave no Lakehouse |
| `environments[].knownDegradations` | degradação esperada que **não** eleva o exit code |
| `output.baseDir` / `output.fallbackBaseDir` | destino local; o fallback é usado com WARN se o principal falhar |
| `transfer.oneDrivePath` | pasta OneDrive sincronizada com o SharePoint |
| `thresholds.*` | stale, retenção, taxa de resolução, janela de delta |
| `sensitiveHints.patterns` | regex que marcam `has_sensitive_hint` |

Os servidores são sempre resolvidos por **nome explícito**; `DefaultPISystem` nunca é usado, porque
o default desta máquina aponta para o AF da cloud. Ver [armadilha 6](docs/armadilhas.md).

## Datasets

Coleta completa dos **dois ambientes** em 2026-08-07: **15,6 min**, exit code 0.

| Dataset | Origem | `ita-site` | `ita-cloud` | Frequência |
|---|---|---:|---:|---|
| `pipoints` | PI Data Archive | 3.472 | 3.150 | diária |
| `pipoint_health` | PI Data Archive | 3.472 | 3.150 | 2–4x/dia |
| `digitalsets` | PI Data Archive | 536 | 383 | diária |
| `elements` | AF | 106 | 93 | diária |
| `attributes` | AF | 3.485 | 2.674 | diária |
| `templates` | AF | 212 | 211 | diária |
| `eventframes` | AF (janela de 30 d) | 13.589 | 31.429 | diária |
| `analyses` | AF + Analysis Service | 391 | 420 | diária |
| `analysis_outputs` | AF | 639 | 645 | diária |
| `enumsets` / `uom` / `tables` | AF | 57 / 208 / 1 | 58 / 256 / 1 | diária |

O dataset **`attributes` é o mais importante**: o `ConfigString` de um PI Point Data Reference é a
única ponte entre o AF e o Data Archive. Dele saem `resolved_tag`, `resolved_point_id` e
`resolved_server_id`, que permitem detectar tags órfãs, DRs quebrados e referência cruzada entre camadas.

### Colunas de identidade

Todo dataset carrega onze colunas de origem. Duas delas parecem iguais e não são:

| Coluna | Significado |
|---|---|
| `source_server_id` | GUID do Data Archive **de onde a linha foi extraída** |
| `resolved_server_id` | GUID do Data Archive **para onde o ConfigString aponta** |

Divergir entre as duas é **sinal, não erro**: 323 atributos do `ita-cloud` apontam para o Data
Archive do `ita-site`. Ver [docs/arquitetura.md](docs/arquitetura.md).

### Compatibilidade com snapshots anteriores

Os arquivos gerados antes do suporte a múltiplos ambientes usam dois segmentos e não têm
`environment`:

```
pipoints__20260806T193126.csv        (antigo)
pipoints__ita-site__20260807T153018.csv   (atual)
```

Todos vieram do `britams01`, então são tratados como **`ita-site`** no Lakehouse.
**Não é preciso reprocessar** — uma linha no Power Query resolve a convivência.

## Estado da implementação

| Fase | Escopo | Estado |
|---|---|---|
| 0 | Scaffolding e documentação | ✅ |
| 1 | Conexão, `pipoints`, `attributes`, teste de conectividade | ✅ validado contra o PI real |
| 2 | `pipoint_health`, `elements`, `templates`, `eventframes`, `analyses`, apoio | ✅ validado contra o PI real |
| 3 | Orquestradores, manifesto, transferência, retenção, guardas e CI | ✅ validado ponta a ponta |
| 4 | Notebooks do Fabric, views gold, fluxo PAD | ✅ escrito — **pendente de execução no Fabric** |

> A Fase 4 é a única ainda não exercitada contra o ambiente real: os notebooks e o SQL foram
> escritos a partir do esquema efetivamente gerado, mas nunca rodaram num Lakehouse. Espere ajustes
> na primeira execução.

Coleta completa de metadados (2026-08-06), contra `ITA_NOVECARE` e `BRITAMS01-SV01`:
**11 datasets, ~35 mil linhas, 140 s**, `resolution_rate` **0,9941** sem nenhum `unparsed`.

O que a primeira leitura já revelou sobre a planta:

| Sinal | Valor |
|---|---|
| Analyses em `Error` | **30 de 391** |
| Tags que nunca receberam dado | 87 |
| Tags com snapshot ruim | 186 |
| Tags stale (> 24 h) | 1.792 — ver a ressalva sobre compressão em [docs/arquitetura.md](docs/arquitetura.md) |

Como `resolutionRateBaseline` ainda está `null`, o limite em vigor é o absoluto `0.9` e a severidade
é `warn`. Com a taxa real conhecida, fixe `resolutionRateBaseline: 0.9941` e o alarme passa a ser
queda relativa de 2 pontos percentuais.

## Lado do Fabric

Ordem de execução no Lakehouse `lh_pi_governance`:

```
Dataflow Gen2 (conector SharePoint folder)  →  Files/landing/PI_System/<data>/
        ↓
fabric/notebooks/01_bronze_ingest.ipynb     →  bronze_*  (texto cru, append-only)
        ↓
fabric/notebooks/02_silver_transform.ipynb  →  silver_*  (tipado, join AF↔PI)
        ↓
fabric/notebooks/03_gold_views.ipynb        →  gold_*    (fatos, deltas, superfícies)
        ↓
fabric/sql/gold_views.sql                   →  gold_vw_* (views para o Power BI)
```

O relatório publicado deve consumir **`gold_attribute_public`**, nunca `gold_attribute_full`: o
`config_string` cru pode conter caminho interno, IP ou string de conexão. O dado continua existindo
para diagnosticar DR mal configurado, mas não aparece para quem abre o dashboard.

## Documentação

- [docs/ambiente.md](docs/ambiente.md) — mapeamento completo do ambiente real
- [docs/armadilhas.md](docs/armadilhas.md) — 19 armadilhas descobertas na prática
- [docs/arquitetura.md](docs/arquitetura.md) — fluxo, camadas, alertas e regras de delta
- [pad/README.md](pad/README.md) — configuração do fluxo unattended
