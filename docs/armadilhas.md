# Armadilhas conhecidas

Todas foram descobertas na prática **neste ambiente**. Violar qualquer uma quebra o script.
Antes de "consertar" algo que parece errado no código, confira se não está resolvendo uma destas.

---

## 1. Carregue o AF SDK no topo de todo script

**Sintoma:** `Unable to find type [OSIsoft.AF.PISystems]` numa sessão nova de PowerShell.

Sessão nova não tem o tipo carregado. Nunca assuma que outro script já carregou.

```powershell
Import-Module OSIsoft.PowerShell -ErrorAction Stop
```

Com fallback para o assembly:

```powershell
Add-Type -Path 'C:\Program Files (x86)\PIPC\AF\PublicAssemblies\4.0\OSIsoft.AFSDK.dll'
```

No módulo isto está encapsulado em `Import-PISdk`, que tenta os dois caminhos e reporta qual usou.

---

## 2. Prefira o AF SDK direto aos cmdlets do módulo

Nesta instalação os cmdlets de `OSIsoft.PowerShell` são menos confiáveis que o SDK.

```powershell
# preferir
$af = (New-Object OSIsoft.AF.PISystems)['BRITAMS01-SV01']

# evitar
Connect-AFServer -AFServer BRITAMS01-SV01
```

O módulo `OSIsoft.PowerShell` continua sendo importado — mas apenas porque importá-lo carrega o
assembly do SDK. Os cmdlets em si não são usados.

---

## 3. `Get-AFDatabase -Name` retorna null

**Sintoma:** variável vazia, sem erro. É a pior classe de falha: silenciosa.

```powershell
# não funciona
$db = Get-AFDatabase -AFServer $af -Name 'ITA_NOVECARE'

# funciona
$db = $af.Databases['ITA_NOVECARE']
```

Sempre teste o resultado contra `$null` logo depois.

---

## 4. `Find-AFEventFrame` não aceita `-TemplateName`

Nesta versão do módulo o parâmetro não existe. Use a classe de busca do SDK:

```powershell
$search = New-Object OSIsoft.AF.Search.AFEventFrameSearch($afDb, 'EFSearch', "template:'BatchsheetTriggers'")
$frames = $search.FindObjects()
```

---

## 5. Cmdlets não aceitam sintaxe de tempo do PI

**Sintoma:** `*-30d` interpretado como string literal ou erro de conversão.

```powershell
# não funciona em cmdlet
Get-PIValue -StartTime '*-30d'

# funciona
$start = (Get-Date).AddDays(-30)
```

**Exceção importante:** dentro de *query strings* do AF Search a sintaxe do PI funciona normalmente.

```powershell
# válido — é query string, não parâmetro de cmdlet
$query = "template:'BatchsheetTriggers' start:>'*-30d'"
```

---

## 6. Acesse servidores por nome explícito, nunca pelo Default

**Sintoma:** o script conecta com sucesso — no servidor **errado**.

O Default PI System desta máquina ainda aponta para `asew1pstekpAF02`, um servidor antigo.
Um script que use `DefaultPISystem` roda sem erro e produz um inventário de outro ambiente.

```powershell
$pi = (New-Object OSIsoft.AF.PI.PIServers)['ITA_NOVECARE']
$af = (New-Object OSIsoft.AF.PISystems)['BRITAMS01-SV01']
```

Os nomes vêm de `config/settings.json`, nunca hardcoded.

---

## 7. Pré-carregue em lote para não fazer round-trip por objeto

**Sintoma:** o script funciona, mas leva 40 minutos em vez de 2.

Cada leitura de atributo não pré-carregado é uma ida ao servidor. Com 2.000 tags e ~25 atributos
por ponto, são 50 mil round-trips.

```powershell
# PI Points: carrega os atributos junto com a busca
[OSIsoft.AF.PI.PIPoint]::FindPIPoints($pi, '*', $null, [string[]]$attributeNames)

# AF: carrega elementos e atributos em lote
[OSIsoft.AF.Asset.AFElement]::LoadElements($elements)
[OSIsoft.AF.Asset.AFElement]::LoadAttributes($elements)
```

O `duration_ms` gravado no `_manifest.json` existe justamente para detectar o dia em que isso parar
de funcionar — uma degradação de ordem de grandeza é fácil de ver na série temporal e quase
impossível de perceber olhando uma execução isolada.

---

## 8. Salve todo arquivo `.ps1` / `.psm1` como UTF-8 **com BOM**

**Sintoma:** o script executa, não dá erro nenhum, e simplesmente **pula um bloco inteiro de
código**. Acentos aparecem como `VersÃo`, `configuraçÃ£o`.

O PowerShell 5.1 lê arquivos sem BOM usando a code page ANSI (Windows-1252), não UTF-8. O travessão
`—` (bytes `E2 80 94`) vira `â€”`, e `0x94` em Windows-1252 é **aspa dupla tipográfica de fechamento**
(`”`) — que o PowerShell aceita como delimitador de string.

Resultado: uma string com travessão **termina no meio**, a aspa seguinte abre uma nova string, e o
parser engole as próximas dezenas de linhas até encontrar outra aspa. Sem erro de sintaxe, sem
exceção, sem nada no `$Error`.

Foi assim que `Test-Connectivity.ps1` executou 1 verificação das 15 e reportou sucesso.

Para conferir:

```powershell
[System.IO.File]::ReadAllBytes('script.ps1')[0..2]   # deve ser 239 187 191
```

Para corrigir:

```powershell
$noBom = New-Object System.Text.UTF8Encoding($false)
$withBom = New-Object System.Text.UTF8Encoding($true)
$text = [System.IO.File]::ReadAllText($path, $noBom)
[System.IO.File]::WriteAllText($path, $text, $withBom)
```

> Atenção à assimetria: o **código-fonte** precisa de BOM, a **saída CSV** não pode ter BOM.

---

## 9. O ConfigString deste AF tem GUID de servidor e ID de ponto

O formato real predominante não é `\\SERVER\TAG`:

```
\\ITA_NOVECARE?349d4525-1be3-4497-8004-1dced4a16d14\K21000.Pressão_PV?29
  \_____ servidor ____/ \________ GUID do servidor ________/ \__ tag __/ \id/
```

Um parser que corte no **primeiro** `?` devolve `ITA_NOVECARE` — o **nome do servidor** — como se
fosse a tag, com `parse_status = 'resolved'`. Falso positivo silencioso: a `resolution_rate` marca
100% e todas as views de tags órfãs e DR quebrado ficam erradas.

Regras corretas:

- o **último** `\` separa servidor de tag (o segmento do servidor contém barras em referências dinâmicas)
- `?` é **ilegal em nome de tag do PI**, então sempre delimita sufixo
- sufixo puramente numérico é o **PI Point ID** — vale capturar em `resolved_point_id`

O `resolved_point_id` é uma chave de join melhor que o nome: sobrevive a rename.

---

## 10. `%` nem sempre é parâmetro de substituição

**Sintoma:** tags válidas classificadas como `dynamic_tag` e excluídas do join.

Estas tags são reais e o `%` é sinal de porcentagem:

```
Alarmes.CALDEIRA<22%
R10900.Válvula_Manual_Recebimento_KOH_45%_ZSL
K21000.BatchStep_MCA70%
```

Estas são substituições de verdade:

```
sy.io.%@Primary Station%.%Element%
%Server%-OPCInt_ReadOnly_%@ID%_%@Point Source%_UFO2_Heartbeat_1
```

Testar `Contains('%')` marcou 5 tags válidas como dinâmicas. Use o padrão pareado
`$script:AFSubstitutionPattern`, que exige `%@...%`, `%..\...%` ou uma palavra-chave conhecida
entre por cento.

---

## 11. `GetAttributes(String[])` refaz a consulta no servidor

**Sintoma:** o script funciona, mas leva 137 s em vez de 15 s para 3.472 tags.

Mesmo depois de `FindPIPoints` pré-carregar os atributos, o método **plural** vai ao servidor de novo.
O **singular** lê do cache.

```powershell
$point.GetAttributes($names)   # ~39 ms por ponto
$point.GetAttribute($name)     # ~0,2 ms por leitura
```

---

## 12. Nem todo PI Point expõe todos os atributos

Pontos de classe especial (tags de sincronização do ACE, tags de analysis) lançam exceção em
`GetAttribute('instrumenttag')`. Neste ambiente são 14 dos 3.472.

Um `try/catch` em volta do ponto inteiro **descarta a linha toda** e você perde tags do inventário.
O módulo cai para leitura individual por atributo e deixa vazio só o campo ausente.

---

## 13. `AFElement.LoadAttributes` exige dois argumentos

Nesta versão a sobrecarga de um argumento não existe, e passar `$null` como lista de templates
lança `Value cannot be null. Parameter name: templates`.

Use o carregador de árvore, que traz elementos e atributos numa chamada:

```powershell
[OSIsoft.AF.Asset.AFElement]::LoadElementsToDepth($rootElements, $true, 64, 200000)
```

---

## 14. `-f` dentro de chamada de método: a vírgula muda de dono

**Sintoma:** `Error formatting a string: Index (zero based) must be greater than or equal to zero...`

```powershell
$list.Add('[{0}] {1}' -f $status, $sample)     # ERRADO
$list.Add(('[{0}] {1}' -f $status, $sample))   # certo
```

No primeiro caso a vírgula é lida como separador de argumentos do método: o `-f` recebe só um valor
para duas posições. Vale para qualquer `.Metodo(... -f ...)`.

---

## 15. `FindObjects` com `fullLoad = $false` custa 3,5x

**Sintoma:** a coleta de event frames leva 5 minutos em vez de 1,5.

Com `$false`, cada acesso a `Template`, `ReferencedElements` ou `PrimaryReferencedElement` vira
round-trip por objeto. Com 13 mil event frames a conta explode.

```powershell
$search.FindObjects(0, $true, 1000)   # 84 s
$search.FindObjects(0, $false, 1000)  # 294 s
```

Cuidado ao medir isto: o AF mantém cache de sessão. Rodar duas estratégias no mesmo processo faz a
segunda parecer 10x mais rápida. **Sempre meça em processo novo.**

---

## 16. `BatchsheetTriggers` não existe neste AF

O levantamento inicial apontava `BatchsheetTriggers` como o Event Frame Template em uso. Ele **não
existe** no banco. Há 25 EF templates reais, entre eles `Phase`, `Reaction-Batch`, `PIUnitBatch`,
`CMA_batch`, `UnitProcedure`.

Pior: um template inexistente **derruba a busca inteira** com
`The object for 'X' in search criteria was not found` — não devolve zero resultados, lança exceção.

Por isso o export coleta **todos os templates** por padrão e traz `template_name` como coluna, para
o Fabric segmentar. `pi.eventFrameTemplates` no settings.json permite restringir; cada template
vira uma busca separada e uma falha isolada não derruba as demais.

---

## 17. A query do Analysis Service quase não aceita curinga

**Sintoma:** `Invalid query: Invalid symbol '*' at position 5.`

```powershell
$af.AnalysisService.QueryRuntimeInformation('path:*', $fields)     # falha
$af.AnalysisService.QueryRuntimeInformation('name:*', $fields)     # falha
$af.AnalysisService.QueryRuntimeInformation('status:*', $fields)   # falha
$af.AnalysisService.QueryRuntimeInformation("path:'*'", $fields)   # funciona
```

O curinga precisa estar **entre aspas simples**. Campos válidos vêm de
`$af.AnalysisService.RuntimeInformationFields`.

O retorno traz mais posições do que os campos pedidos, então mapear por índice só é seguro do
início para o fim, e conferindo `Count` antes.

---

## 18. `@()` sobre `List[T]` pode lançar exceção ou devolver vazio

**Sintoma:** `System.ArgumentException: Argument types do not match` numa linha que só embrulha uma
coleção em array. Em outra execução, a mesma linha devolve **zero itens** sem erro nenhum.

```powershell
$datasets = @($Context.Datasets)      # instavel com List[object]
$datasets = $Context.Datasets.ToArray()   # deterministico
```

O operador `@()` tenta usar `CopyTo` da coleção para um array cujo tipo de elemento nem sempre
bate. `ToArray()` é chamada .NET direta e não depende da coerção do PowerShell.

O erro é **não-terminante**: o script segue e grava o arquivo, então passa despercebido. Foi
detectado porque apareceu no console do orquestrador entre duas linhas de log normais.

Use `ToArray()` sempre que a origem for `List[T]`, `HashSet[T]` ou outra coleção genérica.

---

## 19. `Get-ChildItem -LiteralPath` ignora `-Include`

**Sintoma:** um script que deveria varrer só `*.ps1` processa **todos** os arquivos do repositório.

```powershell
Get-ChildItem -LiteralPath $p -Recurse -File -Include '*.ps1'   # -Include ignorado

Get-ChildItem -LiteralPath $p -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }  # confiável
```

Isto aconteceu aqui: `Test-SourceEncoding.ps1 -Fix` adicionou BOM em `.gitignore`, `settings.json`
e `lint.yml`. **BOM em `.gitignore` invalida a primeira regra** e em YAML pode quebrar o parser.

O mesmo defeito no guarda read-only faria a varredura pegar `README.md` e `docs/`, onde os termos
proibidos aparecem de propósito, gerando falsos positivos.

---

## 20. Variável local colidindo com parâmetro tipado converte seu objeto em silêncio

**Sintoma:** um objeto atribuído a uma variável vira string vazia, sem erro. O acesso a qualquer
propriedade depois disso devolve nada.

Nomes de variável em PowerShell são **case-insensitive**: `$Environment` e `$environment` são a
**mesma variável**. Se o parâmetro declara um tipo, a restrição vale para toda atribuição posterior.

```powershell
function Initialize-PIConnection {
    param([string] $Environment)          # parametro tipado

    $environment = Resolve-Environment    # MESMA variavel: o objeto vira string
    $environment.id                       # vazio, sem erro
}
```

Foi assim que os dois ambientes falharam com `Index operation failed; the array index evaluated to
null` — o nome do servidor chegava vazio em `$piServers[$nome]`.

No módulo a variável local se chama `$environmentConfig` justamente por isso, com comentário no
código para não ser "simplificada" de volta.

> Regra prática: nunca use como variável local o nome de um parâmetro, nem variando maiúsculas.

---

## 21. `AnalysisRule.GetOutputs()` devolve placeholder, não a saída real

**Sintoma:** um dataset de saídas de analyses que *parece* completo e tem 98% de lixo.

Em 245 de 248 saídas o método devolveu um `AFAttribute` chamado `Output`, **sem `Element` e sem
`DataReferencePlugIn`** — o placeholder da variável de saída não ligada a um atributo. Só 3 eram
atributos reais.

O mapeamento verdadeiro está em `SimplifiedVariableMapping`:

```
vBatchStep_1631E50||BatchName_K27|BatchStep_163125;
```

Formato `variavel||Elemento|Atributo`, entradas separadas por `;`. Em `VariableMapping` (a versão
completa) aparecem também `[GUID]||{guid};` para as entradas e `[GUID]||[UNSET];` para saídas
não mapeadas — ambas devem ser descartadas.

O módulo grava o mapeamento **cru** (`variable_name`, `mapped_target`, `mapping_raw`) e não resolve
o caminho relativo. Três motivos:

- **Reprocessável.** Caminho relativo do AF é cheio de casos de borda. Errando no notebook, você
  corrige e reprocessa o bronze; errando no extrator, cada correção exige nova janela de acesso ao PI.
- **Auditável.** Com `mapping_raw` preservado dá para provar de onde veio cada resolução. No silver
  uma resolução errada é detectável; no extrator ela vira dado silenciosamente errado.
- **Barato.** Nenhuma chamada extra ao SDK por analysis.

> Este é o modo de falha mais perigoso do projeto: **dado plausível e falso é pior que dado ausente.**
> Sempre confira a taxa de preenchimento de um dataset novo antes de confiar nele.

---

## Armadilhas de saída (descobertas fora do PI)

Não são do PI System, mas quebram o pipeline do mesmo jeito.

### CSV com BOM corrompe a primeira coluna no Spark

`Export-Csv -Encoding UTF8` no PowerShell 5.1 grava BOM (`EF BB BF`). O Spark lê o BOM como parte do
nome da primeira coluna, que vira `snapshot_date` com lixo invisível na frente.

O módulo escreve via `StreamWriter` com `UTF8Encoding($false)`. Para conferir:

```powershell
Get-Content <arquivo>.csv -Encoding Byte -TotalCount 3
```

Deve retornar os bytes do primeiro caractere real, nunca `239 187 191`.

### Timestamps misturando `Z` e `-03:00`

O PI devolve uns campos com `DateTimeKind.Utc` (`creationdate`, `changedate`) e outros sem Kind.
Formatar com `K` sem normalizar produz `2021-10-11T12:37:48.000Z` e `2026-08-06T15:51:58.205-03:00`
**no mesmo arquivo** — e `to_timestamp` com padrão fixo no Spark quebra.

O gravador converte tudo para horário local com offset explícito. Para conferir, extraia todos os
offsets do arquivo e confirme que há um valor só.

> **`-02:00` junto de `-03:00` é esperado, não é defeito.** O Brasil teve horário de verão até 2019,
> então `creationdate` de tags antigas cai em `-02:00`. O que importa é o **formato** do offset ser
> sempre `±hh:mm`; aí `to_timestamp(col, "yyyy-MM-dd'T'HH:mm:ss.SSSXXX")` lê os dois. O que quebra
> é misturar `Z` (1 caractere) com `±hh:mm` (6 caracteres).

### Formatar campo por chamada de função custa caro

Gravar 3.500 linhas × 25 colunas chamando uma função de formatação levava 9 s; o acesso dinâmico
às propriedades levava 0,27 s. O custo era a **chamada de função do PowerShell**, ~0,1 ms cada,
87 mil vezes.

Por isso a formatação está inline dentro do laço de `Write-InventoryOutput`, com `StringBuilder`.
Não extraia para uma função "para organizar" sem medir antes.

### Quebra de linha dentro de campo texto

`descriptor`, `exdesc` e `ConfigString` podem conter CR/LF. Sem tratamento, o Spark precisa de
`multiLine=true`, que é lento e frágil. O módulo substitui CR/LF/TAB por espaço na escrita.

### Drive de rede mapeado não existe em sessão unattended

Se `output.baseDir` apontar para uma letra mapeada (ex.: `Z:\`), o PAD rodando unattended não a
enxerga — a sessão não tem o mapeamento do usuário interativo. Use caminho **UNC** ou **local**.

`Test-Connectivity.ps1` classifica o drive e avisa explicitamente quando detecta `DriveType = 4`.
