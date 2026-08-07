# Ambiente real — site Itatiba

Todos os valores abaixo foram validados na prática. Use-os exatamente como estão.

## PI Data Archive

| Item | Valor |
|---|---|
| Nome | `ITA_NOVECARE` |
| Versão | `3.4.460.29` (PI DA 2018 SP3 Patch 2) |
| Default PI Server da máquina | sim |

> ⚠️ O PI Data Archive tem o **mesmo nome** do AF Database (`ITA_NOVECARE`). São coisas diferentes.
> Ao ler código ou log, confira sempre se o contexto é DA ou AF.

## PI AF Server

| Item | Valor |
|---|---|
| Nome | `BRITAMS01-SV01` |
| Versão | `2.10.12.73` (AF 2018 SP3 P1) |
| AF Database | `ITA_NOVECARE` |
| Caminho | `\\BRITAMS01-SV01\ITA_NOVECARE` |

> ⚠️ O nome termina em **S01** — letra **S** seguida de zero-um. Não é "501".

> ⚠️ O **Default PI System da máquina ainda aponta para o servidor antigo** `asew1pstekpAF02`.
> Por isso **nunca** use `DefaultPISystem`. Ver [armadilha 6](armadilhas.md).

## Usuário e permissões

| Item | Valor |
|---|---|
| Usuário | `oxo\dasi0558` |
| Identity no PI DA | `MES-Admin` |
| Identities no AF | `MES-Admin`, `MES-PIVision-Publishers`, `MES-PIVision-Explorers`, `World` |
| Autenticação | integrada do Windows |

> ⚠️ `MES-Admin` **pode deletar PI Points**. Deletar apaga o histórico de forma irreversível.
> É exatamente por isso que este repositório é read-only. Ver a regra no [README](../README.md).

**Nunca coloque credenciais em arquivo.** Toda conexão usa autenticação integrada do Windows.

## Cliente instalado

| Item | Valor |
|---|---|
| PI System Explorer | 2023 Patch 2 (64-bit) |
| AF SDK | 3.0.2.5 (.NET 4.0.30319) |
| Módulo PowerShell | `OSIsoft.PowerShell` |
| Assembly | `C:\Program Files (x86)\PIPC\AF\PublicAssemblies\4.0\OSIsoft.AFSDK.dll` |

## Escopo e volume

Números medidos na coleta completa de metadados (2026-08-06):

| Dataset | Linhas | Tempo |
|---|---:|---:|
| `pipoints` | 3.472 | 15,4 s |
| `pipoint_health` | 3.472 | 6,4 s |
| `digitalsets` | 536 | 0,2 s |
| `elements` | 106 | 1,4 s |
| `attributes` | 3.485 | 18,1 s |
| `templates` | 212 | 1,6 s |
| `eventframes` (30 d) | 13.408 | 84,4 s |
| `analyses` | 391 | 8,0 s |
| `enumsets` | 57 | 0,1 s |
| `uom` | 208 | 0,2 s |
| `tables` | 1 | 0,1 s |
| **Total** | **~35 mil** | **~140 s** |

> ⚠️ A contagem real de tags é **3.472**, 73% acima da estimativa inicial de ~2.000. Vale entender
> de onde vem a diferença antes de dimensionar alertas por volume.

### Estado da planta na primeira leitura

| Sinal | Valor |
|---|---|
| Tags stale (> 24 h sem update) | **1.792 de 3.472 (52%)** |
| Tags com snapshot ruim | 186 |
| Tags que nunca receberam dado | 87 |
| Analyses em `Error` | **30 de 391** |
| Analyses em `Stopped` | 19 |
| Atributos com DR `PI Point` | 3.369 |

> ⚠️ **52% de tags stale não significa 52% de interfaces paradas.** Ver a ressalva sobre
> compressão em [arquitetura.md](arquitetura.md).

| Item | Valor |
|---|---|
| Site | Itatiba |
| Elements raiz do AF DB | `Itatiba`, `Systems` |
| Exemplo de path | `Itatiba\Produção\Reactors\K21000` |
| Padrão de reatores | `K21000`, `K28000`, … |
| Element templates | 6 |
| Event Frame templates | 25 (`Phase`, `Reaction-Batch`, `PIUnitBatch`, `CMA_batch`…) |

> ⚠️ O template `BatchsheetTriggers` citado no levantamento inicial **não existe** neste banco.
> Ver [armadilha 16](armadilhas.md).

Com ~35 mil linhas por coleta diária, o bronze acumula cerca de **12,8 milhões de linhas por ano** —
volume ainda confortável para o Fabric.

## Sinais de que algo mudou no ambiente

Se qualquer um destes aparecer, pare e revalide antes de confiar nos dados:

- `Test-Connectivity.ps1` reportando versão de DA ou AF diferente das acima
- contagem de PI Points muito distante de 3.472
- `duration_ms` do dataset `attributes` subindo em ordem de grandeza — indica que o carregamento em
  lote (`LoadElementsToDepth`) parou de funcionar
- `resolution_rate` caindo abaixo de 0,99 — indica formato novo de `ConfigString` não coberto

## Referências que apontam para o AF Server como se fosse PI

Parte dos `ConfigString` usa `\\BRITAMS01-SV01\...` e `\\britams01-sv01.ita.br.solvay.com\...` no
lugar de `\\ITA_NOVECARE\...` para referenciar PI Points. São três grafias diferentes para o mesmo
alvo, incluindo FQDN.

O join AF↔PI usa `resolved_tag` e `resolved_point_id`, não o nome do servidor, então isso não quebra
nada hoje. Mas se algum dia o join passar a considerar servidor, normalize antes.
