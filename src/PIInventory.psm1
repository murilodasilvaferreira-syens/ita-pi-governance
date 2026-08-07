#Requires -Version 5.1

<#
    PIInventory — extração read-only de metadados do PI System (Data Archive + AF).

    REGRA INVIOLÁVEL: este módulo NUNCA escreve no PI System.
    Nenhuma criação, alteração ou remoção de PI Point, elemento, atributo ou template.
    Ver README.md e tests/Test-ReadOnlyGuard.ps1.
#>

$script:InventoryModuleVersion = '0.1.0'
$script:InventoryModuleRoot = $PSScriptRoot
$script:InventoryLogFile = $null

# Distingue parâmetro de substituição do AF (%Element%, %@ID%, %..\Attr%) de '%' usado como
# sinal de porcentagem em nome de tag (K21000.BatchStep_MCA70%). Testar apenas Contains('%')
# classificaria dezenas de tags válidas como dinâmicas e as excluiria do join AF<->PI.
$script:AFSubstitutionPattern = '%(@[^%]*|\.{1,2}[\\|][^%]*|Element|Server|Attribute|Database|System|ID|Name|Description|Template|UOM|TimeZone|PIServer|Root|Parent|Path|Model|Time|StartTime|EndTime)%'

#region ---------------------------------------------------------------- privados

function ConvertTo-InventoryDateTime {
    param([object] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    if ($Value.GetType().FullName -eq 'OSIsoft.AF.Time.AFTime') {
        try { return $Value.LocalTime } catch { return $null }
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-SafeName {
    param([object] $Object)

    if ($null -eq $Object) { return $null }
    try { return [string]$Object.Name } catch { return $null }
}

function Join-CategoryName {
    param([object] $Categories)

    if ($null -eq $Categories) { return $null }
    try {
        $names = @($Categories | ForEach-Object { $_.Name })
        if ($names.Count -eq 0) { return $null }
        return ($names -join '|')
    }
    catch { return $null }
}

function Test-SensitiveHint {
    param(
        [string[]] $Value,
        [string[]] $Pattern
    )

    if ($null -eq $Pattern -or $Pattern.Count -eq 0) { return $false }

    foreach ($v in $Value) {
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        foreach ($p in $Pattern) {
            try {
                if ($v -match $p) { return $true }
            }
            catch { }
        }
    }
    return $false
}

function Merge-InventoryConfig {
    param(
        [psobject] $Base,
        [psobject] $Override
    )

    foreach ($prop in $Override.PSObject.Properties) {
        $existing = $Base.PSObject.Properties[$prop.Name]

        $bothObjects = $false
        if ($null -ne $existing -and $null -ne $existing.Value -and $null -ne $prop.Value) {
            $bothObjects = ($existing.Value.GetType().Name -eq 'PSCustomObject') -and ($prop.Value.GetType().Name -eq 'PSCustomObject')
        }

        if ($bothObjects) {
            Merge-InventoryConfig -Base $existing.Value -Override $prop.Value
        }
        elseif ($null -ne $existing) {
            $existing.Value = $prop.Value
        }
        else {
            Add-Member -InputObject $Base -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
        }
    }
}

function Get-InventoryConfiguration {
    param([string] $ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $repoRoot = Split-Path -Parent $script:InventoryModuleRoot
        $ConfigPath = Join-Path $repoRoot 'config\settings.json'
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Arquivo de configuração não encontrado: $ConfigPath"
    }

    $config = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json

    $localPath = Join-Path (Split-Path -Parent $ConfigPath) 'settings.local.json'
    if (Test-Path -LiteralPath $localPath) {
        $local = (Get-Content -LiteralPath $localPath -Raw -Encoding UTF8) | ConvertFrom-Json
        Merge-InventoryConfig -Base $config -Override $local
        Add-Member -InputObject $config -MemberType NoteProperty -Name 'localOverridePath' -Value $localPath -Force
    }

    Add-Member -InputObject $config -MemberType NoteProperty -Name 'sourcePath' -Value $ConfigPath -Force
    return $config
}

function Resolve-InventoryBaseDir {
    param([string[]] $Candidate)

    foreach ($c in $Candidate) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $c)) {
                New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop | Out-Null
            }
            $probe = Join-Path $c ('.write_probe_{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $probe -Value 'probe' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $c
        }
        catch { }
    }
    return $null
}

function Assert-InventoryEnvironmentList {
    param([psobject] $Config)

    if (-not $Config.PSObject.Properties['environments']) {
        throw 'settings.json não define "environments". Ver README.'
    }

    $all = @($Config.environments)
    if ($all.Count -eq 0) { throw 'A lista "environments" está vazia no settings.json.' }

    $issues = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    for ($i = 0; $i -lt $all.Count; $i++) {
        $environment = $all[$i]
        $label = "environments[$i]"

        $id = $null
        if ($environment.PSObject.Properties['id']) { $id = [string]$environment.id }

        if ([string]::IsNullOrWhiteSpace($id)) {
            $issues.Add("$label não tem 'id'.")
        }
        else {
            $label = "environments[$i] ('$id')"
            # O id vira segmento de nome de arquivo e chave no Lakehouse: nada de espaço,
            # maiúscula ou acento, que quebrariam o parsing do Dataflow.
            if ($id -cnotmatch '^[a-z0-9-]+$') {
                $issues.Add("$label tem id inválido; use apenas minúsculas, dígitos e hífen.")
            }
            if (-not $seen.Add($id)) {
                $issues.Add("$label tem id duplicado.")
            }
        }

        foreach ($required in 'dataArchive', 'afServer', 'afDatabase') {
            $value = $null
            if ($environment.PSObject.Properties[$required]) { $value = [string]$environment.$required }
            if ([string]::IsNullOrWhiteSpace($value)) {
                $issues.Add("$label não define '$required'.")
            }
        }
    }

    if ($issues.Count -gt 0) {
        throw ("Configuração de ambientes inválida:" + [Environment]::NewLine + '  - ' + ($issues.ToArray() -join ([Environment]::NewLine + '  - ')))
    }

    return $all
}

function Resolve-InventoryEnvironment {
    param(
        [psobject] $Config,
        [string]   $Id
    )

    $all = Assert-InventoryEnvironmentList -Config $Config

    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        $match = @($all | Where-Object { $_.id -eq $Id })
        if ($match.Count -eq 0) {
            throw ("Ambiente '{0}' não existe. Disponíveis: {1}" -f $Id, (($all | ForEach-Object { $_.id }) -join ', '))
        }
        return $match[0]
    }

    $enabled = @($all | Where-Object { $_.enabled })
    if ($enabled.Count -eq 0) { throw 'Nenhum ambiente habilitado no settings.json.' }
    return $enabled[0]
}

function Get-DatasetSourceKind {
    param([string] $Dataset)

    # Datasets que vem so do Data Archive: as colunas de AF ficam vazias neles, porque preenche-las
    # sugeriria uma relação com o AF Server que a linha não tem.
    if ($Dataset -in @('pipoints', 'pipoint_health', 'digitalsets')) { return 'da' }
    return 'af'
}

function Get-KnownDegradation {
    param(
        [psobject] $Context,
        [string]   $Dataset,
        [string]   $Signal
    )

    if (-not $Context.EnvironmentConfig.PSObject.Properties['knownDegradations']) { return $null }

    foreach ($declared in @($Context.EnvironmentConfig.knownDegradations)) {
        if ($declared.dataset -eq $Dataset -and $declared.signal -eq $Signal) { return $declared }
    }
    return $null
}

function Add-DatasetResult {
    param(
        [psobject] $Context,
        [string]   $Dataset,
        [string]   $Status,
        [int]      $RowCount,
        [long]     $DurationMs,
        [string]   $File,
        [string]   $ErrorMessage,
        [hashtable] $Metrics
    )

    $record = [pscustomobject]@{
        dataset     = $Dataset
        status      = $Status
        row_count   = $RowCount
        duration_ms = $DurationMs
        file        = $File
        error       = $ErrorMessage
        metrics     = $Metrics
    }

    $Context.Datasets.Add($record) | Out-Null
    return $record
}

#endregion

#region ---------------------------------------------------------------- públicos

function Get-InventoryEnvironment {
    <#
        .SYNOPSIS
            Lista os ambientes definidos no settings.json, validando a definição.
        .DESCRIPTION
            Cada ambiente é uma camada da topologia (Ring 0 site, Ring 1 cloud) com seu par
            Data Archive + AF Database, coletada de forma independente. Uma falha num ambiente
            não interrompe os demais.

            Lança exceção descrevendo todos os problemas de uma vez se algum `id` estiver ausente,
            fora do padrão `^[a-z0-9-]+$` ou duplicado — o id vira segmento de nome de arquivo e
            chave no Lakehouse.
        .PARAMETER ConfigPath
            Caminho do settings.json.
        .PARAMETER IncludeDisabled
            Inclui também os ambientes com `enabled: false`.
        .OUTPUTS
            Lista de objetos de ambiente.
    #>
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [switch] $IncludeDisabled
    )

    $config = Get-InventoryConfiguration -ConfigPath $ConfigPath
    $all = Assert-InventoryEnvironmentList -Config $config
    if ($IncludeDisabled) { return $all }
    return @($all | Where-Object { $_.enabled })
}

function Import-PISdk {
    <#
        .SYNOPSIS
            Carrega o AF SDK na sessão atual.
        .DESCRIPTION
            Tenta primeiro o módulo OSIsoft.PowerShell e cai para Add-Type sobre o assembly.
            Sessão nova de PowerShell não tem o tipo carregado — ver armadilha 1 em docs/armadilhas.md.
        .PARAMETER AssemblyPath
            Caminhos candidatos do OSIsoft.AFSDK.dll, em ordem de preferência.
        .OUTPUTS
            PSCustomObject com Method, Version e Path do assembly efetivamente carregado.
    #>
    [CmdletBinding()]
    param(
        [string[]] $AssemblyPath = @(
            'C:\Program Files (x86)\PIPC\AF\PublicAssemblies\4.0\OSIsoft.AFSDK.dll',
            'C:\Program Files\PIPC\AF\PublicAssemblies\4.0\OSIsoft.AFSDK.dll'
        )
    )

    $method = $null

    if ('OSIsoft.AF.PISystems' -as [type]) {
        $method = 'AlreadyLoaded'
    }

    if (-not $method) {
        try {
            Import-Module OSIsoft.PowerShell -ErrorAction Stop
            if ('OSIsoft.AF.PISystems' -as [type]) { $method = 'OSIsoft.PowerShell' }
        }
        catch {
            Write-Verbose "Import-Module OSIsoft.PowerShell falhou: $($_.Exception.Message)"
        }
    }

    if (-not $method) {
        foreach ($path in $AssemblyPath) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            try {
                Add-Type -Path $path -ErrorAction Stop
                if ('OSIsoft.AF.PISystems' -as [type]) {
                    $method = "Add-Type:$path"
                    break
                }
            }
            catch {
                Write-Verbose "Add-Type falhou em '$path': $($_.Exception.Message)"
            }
        }
    }

    if (-not $method) {
        throw 'AF SDK não pôde ser carregado. Verifique a instalação do PI System Explorer / AF SDK.'
    }

    $assembly = [OSIsoft.AF.PISystems].Assembly

    return [pscustomobject]@{
        method  = $method
        version = $assembly.GetName().Version.ToString()
        path    = $assembly.Location
    }
}

function Write-InventoryLog {
    <#
        .SYNOPSIS
            Grava uma entrada de log estruturada (JSON lines) e ecoa no console.
        .DESCRIPTION
            O arquivo de destino é definido por Initialize-PIConnection. Antes disso, a saída vai
            apenas para o console. WARN e ERROR são sempre visíveis — o PAD captura o console.
        .PARAMETER Message
            Texto da mensagem.
        .PARAMETER Level
            DEBUG, INFO, WARN ou ERROR.
        .PARAMETER Dataset
            Dataset relacionado, quando aplicável.
        .PARAMETER Data
            Pares chave/valor adicionais serializados junto da entrada.
        .PARAMETER LogFile
            Sobrescreve o arquivo de log da sessão.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Message,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',

        [string] $Dataset,

        [hashtable] $Data,

        [string] $LogFile
    )

    $timestamp = Get-Date
    $entry = [ordered]@{
        ts      = $timestamp.ToString("yyyy-MM-dd'T'HH:mm:ss.fffK")
        level   = $Level
        message = $Message
    }
    if ($Dataset) { $entry['dataset'] = $Dataset }
    if ($Data) { $entry['data'] = $Data }

    $target = if ($PSBoundParameters.ContainsKey('LogFile')) { $LogFile } else { $script:InventoryLogFile }
    if (-not [string]::IsNullOrWhiteSpace($target)) {
        try {
            $json = $entry | ConvertTo-Json -Compress -Depth 6
            $encoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::AppendAllText($target, $json + [Environment]::NewLine, $encoding)
        }
        catch {
            Write-Warning "Falha ao gravar log em '$target': $($_.Exception.Message)"
        }
    }

    $prefix = if ($Dataset) { "[$Dataset] " } else { '' }
    $line = '{0} {1,-5} {2}{3}' -f $timestamp.ToString('HH:mm:ss'), $Level, $prefix, $Message

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Warning ($prefix + $Message) }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }
}

function Write-InventoryOutput {
    <#
        .SYNOPSIS
            Grava um dataset no formato de saída configurado.
        .DESCRIPTION
            Ponto único de escrita do módulo — trocar CSV por Parquet significa alterar apenas esta
            função. Grava CSV UTF-8 SEM BOM via StreamWriter, porque Export-Csv -Encoding UTF8 do
            PowerShell 5.1 emite BOM e corrompe o nome da primeira coluna no Spark.
        .PARAMETER InputObject
            Linhas a gravar. Pode ser vazio se -Column for informado.
        .PARAMETER Dataset
            Nome lógico do dataset; define o nome do arquivo.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .PARAMETER Column
            Ordem autoritativa das colunas. Se omitido, deriva da primeira linha.
        .OUTPUTS
            PSCustomObject com dataset, file, path, row_count e write_ms.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Dataset,

        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [string[]] $Column
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = $Column
    if (-not $columns -or $columns.Count -eq 0) {
        if ($InputObject.Count -gt 0) {
            $columns = @($InputObject[0].PSObject.Properties.Name)
        }
    }

    if (-not $columns -or $columns.Count -eq 0) {
        Write-InventoryLog -Level WARN -Dataset $Dataset -Message 'Dataset vazio e sem esquema declarado; nenhum arquivo gravado.'
        $stopwatch.Stop()
        return [pscustomobject]@{
            dataset   = $Dataset
            file      = $null
            path      = $null
            row_count = 0
            write_ms  = $stopwatch.ElapsedMilliseconds
        }
    }

    $delimiter = ','
    if ($Context.Config.output.PSObject.Properties['delimiter']) {
        $delimiter = [string]$Context.Config.output.delimiter
    }

    $fileName = '{0}__{1}__{2}.csv' -f $Dataset, $Context.Environment, $Context.SnapshotStamp
    $path = Join-Path $Context.SnapshotPath $fileName

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $dateFormat = "yyyy-MM-dd'T'HH:mm:ss.fffK"
    $whitespace = [char[]]@("`r", "`n", "`t")
    $special = [char[]]@('"', $delimiter[0])

    $snapshotTs = $Context.SnapshotTime
    if ($snapshotTs -is [datetime]) {
        if ($snapshotTs.Kind -eq [System.DateTimeKind]::Unspecified) {
            $snapshotTs = [datetime]::SpecifyKind($snapshotTs, [System.DateTimeKind]::Local)
        }
        elseif ($snapshotTs.Kind -eq [System.DateTimeKind]::Utc) {
            $snapshotTs = $snapshotTs.ToLocalTime()
        }
        $snapshotTs = $snapshotTs.ToString($dateFormat)
    }

    # Identidade da origem, repetida em toda linha. Nome é rótulo, GUID é chave: neste ambiente
    # dois AF Databases distintos se chamam ITA_NOVECARE e o mesmo Data Archive aparece escrito
    # de quatro formas diferentes nos ConfigStrings.
    $isAfDataset = (Get-DatasetSourceKind -Dataset $Dataset) -eq 'af'
    $identityColumns = @(
        'environment', 'tier', 'site', 'snapshot_date', 'snapshot_ts',
        'source_server', 'source_server_id',
        'source_af_server', 'source_af_server_id',
        'source_af_database', 'source_af_database_id'
    )
    $identityValues = @(
        $Context.Environment
        $Context.Tier
        $Context.Site
        $Context.SnapshotDate
        $snapshotTs
        $Context.SourceServer
        $Context.SourceServerId
        $(if ($isAfDataset) { $Context.SourceAFServer } else { '' })
        $(if ($isAfDataset) { $Context.SourceAFServerId } else { '' })
        $(if ($isAfDataset) { $Context.SourceAFDatabase } else { '' })
        $(if ($isAfDataset) { $Context.SourceAFDatabaseId } else { '' })
    ) | ForEach-Object {
        $text = [string]$_
        if ($text.IndexOfAny($special) -ge 0) { '"' + $text.Replace('"', '""') + '"' } else { $text }
    }

    $rowPrefix = $identityValues -join $delimiter

    # A formatação é inline de propósito: como função, o custo de chamada do PowerShell dominava
    # a gravação (~9 s para 87 mil campos contra ~1 s aqui).
    $builder = New-Object System.Text.StringBuilder
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($path, $false, $encoding)
    try {
        $writer.WriteLine((($identityColumns + $columns) -join $delimiter))

        foreach ($item in $InputObject) {
            [void]$builder.Clear()
            [void]$builder.Append($rowPrefix)

            foreach ($column in $columns) {
                [void]$builder.Append($delimiter)

                $value = $item.$column
                if ($null -eq $value) { continue }

                if ($value -is [string]) {
                    $text = $value
                }
                elseif ($value -is [datetime]) {
                    # Tudo vira horário local com offset explícito: o PI devolve uns campos em UTC
                    # e outros sem Kind, e misturar 'Z' com '-03:00' na mesma coluna quebra
                    # to_timestamp com padrão fixo no Spark.
                    if ($value.Kind -eq [System.DateTimeKind]::Unspecified) {
                        $value = [datetime]::SpecifyKind($value, [System.DateTimeKind]::Local)
                    }
                    elseif ($value.Kind -eq [System.DateTimeKind]::Utc) {
                        $value = $value.ToLocalTime()
                    }
                    $text = $value.ToString($dateFormat)
                }
                elseif ($value -is [bool]) {
                    $text = if ($value) { 'true' } else { 'false' }
                }
                elseif ($value -is [double] -or $value -is [single] -or $value -is [decimal]) {
                    $text = $value.ToString($invariant)
                }
                else {
                    $text = [string]$value
                }

                if ($text.Length -eq 0) { continue }

                # Quebra de linha em campo obrigaria multiLine=true no Spark. Ver docs/armadilhas.md.
                if ($text.IndexOfAny($whitespace) -ge 0) {
                    $text = $text.Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
                }
                if ($text.IndexOfAny($special) -ge 0) {
                    $text = '"' + $text.Replace('"', '""') + '"'
                }

                [void]$builder.Append($text)
            }

            $writer.WriteLine($builder.ToString())
        }
    }
    finally {
        $writer.Flush()
        $writer.Close()
        $writer.Dispose()
    }

    $stopwatch.Stop()

    return [pscustomobject]@{
        dataset   = $Dataset
        file      = $fileName
        path      = $path
        row_count = $InputObject.Count
        write_ms  = $stopwatch.ElapsedMilliseconds
    }
}

function ConvertFrom-AFConfigString {
    <#
        .SYNOPSIS
            Extrai servidor e nome de tag do ConfigString de um PI Point Data Reference.
        .DESCRIPTION
            É a única ponte entre AF e Data Archive. A resolução real do Data Reference NÃO é feita
            aqui de propósito: chamar $attr.PIPoint faria round-trip por atributo e lançaria exceção
            justamente nos DRs quebrados, que são o que queremos medir. O join fica no Fabric.

            Formato predominante neste AF (2018 SP3), com GUID do servidor e ID do ponto:
              \\ITA_NOVECARE?349d4525-...\K21000.Pressão_PV?29

            Demais formatos cobertos:
              \\ITA_NOVECARE\K21000.PV
              ITA_NOVECARE\K21000.PV
              K21000.PV
              \\ITA_NOVECARE\K21000.PV;ptclassname=classic
              \\%Server%\%Element%.PV        -> parse_status 'dynamic_tag'

            O caractere '?' é ilegal em nome de tag do PI, então sempre delimita sufixo: ou o GUID
            do servidor, ou o ID do ponto, ou parâmetros. Nunca faz parte do nome.

            `resolved_server_id` é a chave confiável de servidor. O mesmo Data Archive aparece
            escrito de quatro formas neste ambiente (nome PI, hostname, FQDN e FQDN alternativo),
            mas o GUID é sempre o mesmo. Com mais de um Data Archive coletado, comparar por nome
            produziria join errado.
        .PARAMETER ConfigString
            Valor bruto do ConfigString.
        .PARAMETER DataReference
            Nome do plug-in de Data Reference. Só 'PI Point' é interpretado.
        .OUTPUTS
            PSCustomObject com resolved_server, resolved_server_id, resolved_tag,
            resolved_point_id, is_dynamic_reference e parse_status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ConfigString,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $DataReference
    )

    $result = [pscustomobject]@{
        resolved_server      = $null
        resolved_server_id   = $null
        resolved_tag         = $null
        resolved_point_id    = $null
        is_dynamic_reference = $false
        parse_status         = 'empty'
    }

    if (-not [string]::IsNullOrWhiteSpace($DataReference) -and $DataReference -notmatch '^\s*PI\s*Point\s*$') {
        $result.parse_status = 'not_pi_point'
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($ConfigString)) {
        return $result
    }

    $text = $ConfigString.Trim()
    $result.is_dynamic_reference = [bool]($text -match $script:AFSubstitutionPattern)

    # Parâmetros de criação de ponto não fazem parte da referência.
    $semicolon = $text.IndexOf(';')
    if ($semicolon -ge 0) { $text = $text.Substring(0, $semicolon).Trim() }

    if ($text.StartsWith('\\')) { $text = $text.Substring(2) }
    $text = $text.TrimEnd('\').Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        $result.parse_status = 'unparsed'
        return $result
    }

    # O último '\' separa servidor de tag; o segmento do servidor pode conter GUID e barras.
    $lastSlash = $text.LastIndexOf('\')
    if ($lastSlash -ge 0) {
        $serverSegment = $text.Substring(0, $lastSlash)
        $tagSegment = $text.Substring($lastSlash + 1)
    }
    else {
        $serverSegment = ''
        $tagSegment = $text
    }

    if (-not [string]::IsNullOrWhiteSpace($serverSegment)) {
        $queryIndex = $serverSegment.IndexOf('?')
        if ($queryIndex -ge 0) {
            $result.resolved_server = $serverSegment.Substring(0, $queryIndex)
            $suffix = $serverSegment.Substring($queryIndex + 1)
            if ($suffix -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
                $result.resolved_server_id = $Matches[0].ToLowerInvariant()
            }
        }
        else {
            $result.resolved_server = $serverSegment
        }
    }

    $queryIndex = $tagSegment.IndexOf('?')
    if ($queryIndex -ge 0) {
        $suffix = $tagSegment.Substring($queryIndex + 1)
        $tagSegment = $tagSegment.Substring(0, $queryIndex)
        if ($suffix -match '^\d+$') { $result.resolved_point_id = $suffix }
    }
    $tagSegment = $tagSegment.Trim()

    if ([string]::IsNullOrWhiteSpace($tagSegment)) {
        $result.parse_status = 'unparsed'
    }
    elseif ($tagSegment -match $script:AFSubstitutionPattern) {
        $result.parse_status = 'dynamic_tag'
    }
    else {
        $result.resolved_tag = $tagSegment
        $result.parse_status = 'resolved'
    }

    return $result
}

function Initialize-PIConnection {
    <#
        .SYNOPSIS
            Carrega o AF SDK, conecta PI Data Archive e AF Server por nome explícito e prepara a saída.
        .DESCRIPTION
            Nunca usa DefaultPISystem: o Default desta máquina ainda aponta para o servidor antigo
            asew1pstekpAF02 e um script que o use roda sem erro contra o ambiente errado.

            Se output.baseDir não estiver acessível, cai para output.fallbackBaseDir e emite WARN
            visível — silenciar faria o próximo dev não entender por que os arquivos mudaram de lugar.
        .PARAMETER ConfigPath
            Caminho do settings.json. Padrão: <repo>\config\settings.json.
        .PARAMETER RunType
            'metadata' (diário) ou 'health' (intradiário). Define nome de log e pasta.
        .PARAMETER SnapshotTime
            Instante lógico do snapshot. Padrão: agora.
        .OUTPUTS
            PSCustomObject de contexto, consumido por todas as funções Export-*.
        .EXAMPLE
            $ctx = Initialize-PIConnection
            Export-PIPointInventory -Context $ctx
    #>
    [CmdletBinding()]
    param(
        [string] $ConfigPath,

        [string] $Environment,

        [ValidateSet('metadata', 'health')]
        [string] $RunType = 'metadata',

        [datetime] $SnapshotTime = (Get-Date)
    )

    $config = Get-InventoryConfiguration -ConfigPath $ConfigPath

    # NAO renomear para $environment: o parametro [string] $Environment e a mesma variavel
    # (nomes sao case-insensitive) e a restricao de tipo converteria o objeto para string.
    $environmentConfig = Resolve-InventoryEnvironment -Config $config -Id $Environment

    $baseCandidates = @($config.output.baseDir, $config.output.fallbackBaseDir)
    $baseDir = Resolve-InventoryBaseDir -Candidate $baseCandidates
    if (-not $baseDir) {
        throw "Nenhum diretório de saída acessível. Testados: $($baseCandidates -join ' , ')"
    }
    $usedFallback = ($baseDir -ne $config.output.baseDir)

    $snapshotDate = $SnapshotTime.ToString('yyyy-MM-dd')
    $snapshotStamp = $SnapshotTime.ToString("yyyyMMdd'T'HHmmss")

    $snapshotPath = Join-Path (Join-Path $baseDir $config.output.rawFolderName) $snapshotDate
    $logPath = Join-Path (Join-Path $baseDir $config.output.logFolderName) $snapshotDate
    foreach ($dir in @($snapshotPath, $logPath)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
    }

    $script:InventoryLogFile = Join-Path $logPath ('{0}__{1}__{2}.log' -f $RunType, $environmentConfig.id, $snapshotStamp)

    Write-InventoryLog -Message ('Iniciando execução {0} (módulo {1})' -f $RunType, $script:InventoryModuleVersion) -Data @{
        config_path = $config.sourcePath
        user        = "$env:USERDOMAIN\$env:USERNAME"
        machine     = $env:COMPUTERNAME
    }

    if ($config.PSObject.Properties['localOverridePath']) {
        Write-InventoryLog -Level INFO -Message "Override local aplicado: $($config.localOverridePath)"
    }

    if ($usedFallback) {
        Write-InventoryLog -Level WARN -Message (
            "Diretório de saída principal '{0}' inacessível. Usando fallback '{1}'." -f $config.output.baseDir, $baseDir
        )
    }

    $sensitivePatterns = @()
    if ($config.PSObject.Properties['sensitiveHints']) {
        foreach ($pattern in @($config.sensitiveHints.patterns)) {
            try {
                [void][regex]::new($pattern)
                $sensitivePatterns += $pattern
            }
            catch {
                Write-InventoryLog -Level WARN -Message "Padrão de campo sensível inválido, ignorado: $pattern"
            }
        }
    }

    $sdk = Import-PISdk -AssemblyPath @($config.pi.afSdkAssemblyPath)
    Write-InventoryLog -Message ('AF SDK carregado via {0} (versão {1})' -f $sdk.method, $sdk.version)

    Write-InventoryLog -Message ('Ambiente: {0} — {1} (tier {2})' -f $environmentConfig.id, $environmentConfig.name, $environmentConfig.tier)

    $dataArchiveName = $environmentConfig.dataArchive
    $piServers = New-Object OSIsoft.AF.PI.PIServers
    $piServer = $piServers[$dataArchiveName]
    if ($null -eq $piServer) {
        throw "PI Data Archive '$dataArchiveName' não encontrado na lista de servidores conhecidos desta máquina."
    }
    $piServer.Connect()
    Write-InventoryLog -Message ('PI Data Archive conectado: {0} (versão {1}, id {2})' -f $piServer.Name, $piServer.ServerVersion, $piServer.ID)

    $afServerName = $environmentConfig.afServer
    $piSystems = New-Object OSIsoft.AF.PISystems
    $afServer = $piSystems[$afServerName]
    if ($null -eq $afServer) {
        throw "AF Server '$afServerName' não encontrado na lista de servidores conhecidos desta máquina."
    }
    $afServer.Connect()

    # Get-AFDatabase -Name retorna null nesta versão; a coleção funciona. Ver armadilha 3.
    $afDatabaseName = $environmentConfig.afDatabase
    $afDatabase = $afServer.Databases[$afDatabaseName]
    if ($null -eq $afDatabase) {
        throw "AF Database '$afDatabaseName' não encontrado em '$afServerName'."
    }
    Write-InventoryLog -Message ('AF conectado: {0} (versão {1}), database {2}' -f $afServer.Name, $afServer.ServerVersion, $afDatabase.Name)

    return [pscustomobject]@{
        RunId              = [guid]::NewGuid().ToString()
        RunType            = $RunType
        Environment        = [string]$environmentConfig.id
        EnvironmentName    = [string]$environmentConfig.name
        Tier               = [string]$environmentConfig.tier
        Site               = [string]$environmentConfig.site
        SiteName           = [string]$environmentConfig.siteName
        EnvironmentConfig  = $environmentConfig
        SnapshotTime       = $SnapshotTime
        SnapshotDate       = $snapshotDate
        SnapshotStamp      = $snapshotStamp
        Config             = $config
        SensitivePatterns  = $sensitivePatterns
        Sdk                = $sdk
        PIServer           = $piServer
        SourceServer       = [string]$piServer.Name
        SourceServerId     = [string]$piServer.ID
        PISystem           = $afServer
        SourceAFServer     = [string]$afServer.Name
        SourceAFServerId   = [string]$afServer.ID
        AFDatabase         = $afDatabase
        SourceAFDatabase   = [string]$afDatabase.Name
        SourceAFDatabaseId = [string]$afDatabase.ID
        BaseDir            = $baseDir
        UsedFallbackDir    = $usedFallback
        SnapshotPath       = $snapshotPath
        LogPath            = $logPath
        LogFile            = $script:InventoryLogFile
        ModuleVersion      = $script:InventoryModuleVersion
        Datasets           = (New-Object System.Collections.Generic.List[object])
    }
}

function Export-PIPointInventory {
    <#
        .SYNOPSIS
            Exporta o inventário de PI Points do Data Archive.
        .DESCRIPTION
            Pré-carrega os atributos junto da busca para evitar um round-trip por atributo
            (~50 mil chamadas com 2.000 tags). Ver armadilha 7 em docs/armadilhas.md.

            Falhas são capturadas e devolvidas como status 'failed' — nunca interrompem os
            demais exports.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .PARAMETER NameFilter
            Filtro de nome de tag. Padrão: pi.pointNameFilter do settings.json.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [string] $NameFilter
    )

    $dataset = 'pipoints'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'name', 'pointid', 'pointtype', 'ptclassname', 'descriptor', 'engunits', 'pointsource',
        'location1', 'location2', 'location3', 'location4', 'location5',
        'instrumenttag', 'exdesc', 'compressing', 'compdev', 'excdev', 'zero', 'span',
        'digitalset', 'creationdate', 'creator', 'changedate', 'changer', 'has_sensitive_hint'
    )
    # pointid é o identificador estável: distingue rename de remoção em vw_delta_tag_removida.
    $piAttributes = [string[]]@(
        'pointid', 'pointtype', 'ptclassname', 'descriptor', 'engunits', 'pointsource',
        'location1', 'location2', 'location3', 'location4', 'location5',
        'instrumenttag', 'exdesc', 'compressing', 'compdev', 'excdev', 'zero', 'span',
        'digitalset', 'creationdate', 'creator', 'changedate', 'changer'
    )

    try {
        $filter = if ($PSBoundParameters.ContainsKey('NameFilter')) { $NameFilter } else { [string]$Context.EnvironmentConfig.pointNameFilter }
        if ([string]::IsNullOrWhiteSpace($filter)) { $filter = '*' }

        Write-InventoryLog -Dataset $dataset -Message "Buscando PI Points com filtro '$filter'."

        $points = $null
        $loadMethod = $null
        try {
            $points = [OSIsoft.AF.PI.PIPoint]::FindPIPoints($Context.PIServer, $filter, $null, $piAttributes)
            $loadMethod = 'FindPIPoints com pré-carga de atributos'
        }
        catch {
            Write-InventoryLog -Level WARN -Dataset $dataset -Message "Pré-carga de atributos indisponível, leitura ficará muito mais lenta: $($_.Exception.Message)"
            $points = [OSIsoft.AF.PI.PIPoint]::FindPIPoints($Context.PIServer, $filter, $null, $null)
            $loadMethod = 'FindPIPoints sem pré-carga'
        }

        $points = @($points)
        Write-InventoryLog -Dataset $dataset -Message ('{0} PI Points encontrados via {1}.' -f $points.Count, $loadMethod)

        $patterns = $Context.SensitivePatterns
        $rows = New-Object System.Collections.Generic.List[object]
        $partial = 0

        foreach ($point in $points) {
            # GetAttribute lê do cache da pré-carga; GetAttributes(String[]) refaz a consulta no
            # servidor e custa ~6x mais. Alguns pontos não possuem todos os atributos, então o
            # caminho rápido cai para leitura individual em vez de descartar o ponto inteiro.
            $values = @{}
            try {
                foreach ($name in $piAttributes) { $values[$name] = $point.GetAttribute($name) }
            }
            catch {
                $partial++
                foreach ($name in $piAttributes) {
                    try { $values[$name] = $point.GetAttribute($name) } catch { $values[$name] = $null }
                }
            }

            $exdesc = [string]$values['exdesc']
            $instrumentTag = [string]$values['instrumenttag']
            $descriptor = [string]$values['descriptor']

            $rows.Add([pscustomobject]@{
                    name               = $point.Name
                    pointid            = $values['pointid']
                    pointtype          = [string]$values['pointtype']
                    ptclassname        = [string]$values['ptclassname']
                    descriptor         = $descriptor
                    engunits           = [string]$values['engunits']
                    pointsource        = [string]$values['pointsource']
                    location1          = $values['location1']
                    location2          = $values['location2']
                    location3          = $values['location3']
                    location4          = $values['location4']
                    location5          = $values['location5']
                    instrumenttag      = $instrumentTag
                    exdesc             = $exdesc
                    compressing        = $values['compressing']
                    compdev            = $values['compdev']
                    excdev             = $values['excdev']
                    zero               = $values['zero']
                    span               = $values['span']
                    digitalset         = [string]$values['digitalset']
                    creationdate       = ConvertTo-InventoryDateTime $values['creationdate']
                    creator            = [string]$values['creator']
                    changedate         = ConvertTo-InventoryDateTime $values['changedate']
                    changer            = [string]$values['changer']
                    has_sensitive_hint = Test-SensitiveHint -Value @($exdesc, $instrumentTag, $descriptor) -Pattern $patterns
                })
        }

        if ($partial -gt 0) {
            Write-InventoryLog -Level WARN -Dataset $dataset -Message "$partial pontos não expõem todos os atributos; campos ausentes ficaram vazios."
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()

        Write-InventoryLog -Dataset $dataset -Message ('{0} linhas gravadas em {1} ms.' -f $written.row_count, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{ load_method = $loadMethod; partial_points = $partial }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFAttributeInventory {
    <#
        .SYNOPSIS
            Exporta o inventário de atributos do AF, com o ConfigString e a tag resolvida.
        .DESCRIPTION
            É o dataset central do projeto: o ConfigString de um PI Point Data Reference é a única
            ponte entre AF e Data Archive.

            O Data Reference NÃO é resolvido aqui. A detecção de tag órfã e DR quebrado é um join
            no Fabric — extração burra, análise esperta.

            Calcula resolution_rate (proporção de atributos com DR 'PI Point' cujo ConfigString
            produziu uma tag) e grava nas metrics. Se a taxa cair abaixo do limite, registra uma
            amostra dos ConfigString que falharam: sem ela você sabe que quebrou, mas não o quê.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'attributes'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'element_path', 'element_name', 'element_template',
        'attribute_path', 'attribute_name', 'attribute_level',
        'description', 'type', 'uom', 'categories', 'template_name',
        'data_reference', 'config_string', 'resolved_server', 'resolved_server_id',
        'resolved_tag', 'resolved_point_id',
        'is_dynamic_reference', 'parse_status',
        'is_configuration_item', 'is_hidden', 'is_excluded',
        'guid', 'element_guid', 'has_sensitive_hint'
    )

    try {
        $patterns = $Context.SensitivePatterns

        $catalog = Get-AFElementCatalog -Context $Context -Dataset $dataset
        $allElements = $catalog.Entries
        $loadMethod = $catalog.LoadMethod
        $depth = $catalog.Depth

        $rows = New-Object System.Collections.Generic.List[object]
        $parseCounts = @{}
        $piPointTotal = 0
        $resolvedTotal = 0
        $sampleLimit = [int]$Context.Config.thresholds.resolutionFailureSampleSize
        if ($sampleLimit -le 0) { $sampleLimit = 10 }
        $failureSamples = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $allElements) {
            $element = $entry.Element
            $elementPath = $entry.Path
            $elementTemplate = Get-SafeName $element.Template
            $elementGuid = [string]$element.ID

            $stack = New-Object System.Collections.Stack
            try {
                foreach ($attribute in $element.Attributes) {
                    $stack.Push([pscustomobject]@{ Attribute = $attribute; Level = 1 })
                }
            }
            catch {
                Write-InventoryLog -Level WARN -Dataset $dataset -Message "Não foi possível ler atributos de '$elementPath': $($_.Exception.Message)"
                continue
            }

            while ($stack.Count -gt 0) {
                $node = $stack.Pop()
                $attribute = $node.Attribute

                # DataReferencePlugIn é metadado barato; DataReference instanciaria o plug-in.
                $dataReference = $null
                try { $dataReference = Get-SafeName $attribute.DataReferencePlugIn } catch { $dataReference = $null }

                $configString = $null
                try { $configString = [string]$attribute.ConfigString } catch { $configString = $null }

                $parsed = ConvertFrom-AFConfigString -ConfigString $configString -DataReference $dataReference

                $status = $parsed.parse_status
                if ($parseCounts.ContainsKey($status)) { $parseCounts[$status] = $parseCounts[$status] + 1 }
                else { $parseCounts[$status] = 1 }

                $isPiPoint = $false
                if (-not [string]::IsNullOrWhiteSpace($dataReference) -and -not [string]::IsNullOrWhiteSpace($configString)) {
                    $isPiPoint = $dataReference -match '^\s*PI\s*Point\s*$'
                }

                if ($isPiPoint) {
                    $piPointTotal++
                    if ($status -eq 'resolved') {
                        $resolvedTotal++
                    }
                    elseif ($failureSamples.Count -lt $sampleLimit) {
                        $sample = $configString
                        if ($sample.Length -gt 200) { $sample = $sample.Substring(0, 200) + '…' }
                        # Os parênteses externos são obrigatórios: dentro de .Add() a vírgula do -f
                        # seria lida como separador de argumentos do método.
                        $failureSamples.Add(('[{0}] {1}' -f $status, $sample))
                    }
                }

                $attributePath = $null
                try { $attributePath = $attribute.GetPath() } catch { $attributePath = $attribute.Name }

                $description = $null
                try { $description = [string]$attribute.Description } catch { }

                $uom = $null
                try { $uom = Get-SafeName $attribute.DefaultUOM } catch { }

                $typeName = $null
                try { if ($null -ne $attribute.Type) { $typeName = $attribute.Type.Name } } catch { }

                $rows.Add([pscustomobject]@{
                        element_path          = $elementPath
                        element_name          = $element.Name
                        element_template      = $elementTemplate
                        attribute_path        = $attributePath
                        attribute_name        = $attribute.Name
                        attribute_level       = $node.Level
                        description           = $description
                        type                  = $typeName
                        uom                   = $uom
                        categories            = Join-CategoryName $attribute.Categories
                        template_name         = Get-SafeName $attribute.Template
                        data_reference        = $dataReference
                        config_string         = $configString
                        resolved_server       = $parsed.resolved_server
                        resolved_server_id    = $parsed.resolved_server_id
                        resolved_tag          = $parsed.resolved_tag
                        resolved_point_id     = $parsed.resolved_point_id
                        is_dynamic_reference  = $parsed.is_dynamic_reference
                        parse_status          = $status
                        is_configuration_item = $attribute.IsConfigurationItem
                        is_hidden             = $attribute.IsHidden
                        is_excluded           = $attribute.IsExcluded
                        guid                  = [string]$attribute.ID
                        element_guid          = $elementGuid
                        has_sensitive_hint    = Test-SensitiveHint -Value @($configString, $description) -Pattern $patterns
                    })

                try {
                    foreach ($child in $attribute.Attributes) {
                        $stack.Push([pscustomobject]@{ Attribute = $child; Level = $node.Level + 1 })
                    }
                }
                catch { }
            }
        }

        $resolutionRate = if ($piPointTotal -gt 0) { [math]::Round($resolvedTotal / $piPointTotal, 4) } else { $null }

        $thresholds = $Context.Config.thresholds
        $baseline = $thresholds.resolutionRateBaseline
        if ($null -ne $baseline) {
            $limit = [double]$baseline - 0.02
            $limitMode = 'baseline'
        }
        else {
            $limit = [double]$thresholds.minResolutionRate
            $limitMode = 'absoluto'
        }

        $severity = [string]$thresholds.resolutionRateSeverity
        if ([string]::IsNullOrWhiteSpace($severity)) { $severity = 'warn' }

        $exportStatus = 'success'
        if ($null -ne $resolutionRate -and $resolutionRate -lt $limit) {
            Write-InventoryLog -Level WARN -Dataset $dataset -Message (
                'resolution_rate {0} abaixo do limite {1} ({2}). Amostra de ConfigString não resolvidos abaixo.' -f
                $resolutionRate, [math]::Round($limit, 4), $limitMode
            )
            foreach ($sample in $failureSamples) {
                Write-InventoryLog -Level WARN -Dataset $dataset -Message ('  amostra: {0}' -f $sample)
            }
            if ($severity -eq 'fail') { $exportStatus = 'degraded' }
        }
        else {
            Write-InventoryLog -Dataset $dataset -Message (
                'resolution_rate {0} ({1} de {2} atributos com DR PI Point).' -f $resolutionRate, $resolvedTotal, $piPointTotal
            )
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()

        Write-InventoryLog -Dataset $dataset -Message ('{0} linhas gravadas em {1} ms.' -f $written.row_count, $stopwatch.ElapsedMilliseconds)

        $metrics = @{
            element_count       = $allElements.Count
            max_depth           = $depth
            load_method         = $loadMethod
            pi_point_dr_count   = $piPointTotal
            resolved_count      = $resolvedTotal
            resolution_rate     = $resolutionRate
            resolution_limit    = [math]::Round($limit, 4)
            resolution_mode     = $limitMode
            resolution_severity = $severity
            parse_status_counts = $parseCounts
            failure_samples     = $failureSamples.ToArray()
        }

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status $exportStatus `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics $metrics
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Get-AFElementCatalog {
    param(
        [psobject] $Context,
        [string]   $Dataset
    )

    $database = $Context.AFDatabase
    $rootElements = New-Object 'System.Collections.Generic.List[OSIsoft.AF.Asset.AFElement]'
    foreach ($element in $database.Elements) { $rootElements.Add($element) }

    $loadMethod = 'sem pré-carga'
    $useLevelLoad = $true
    try {
        [OSIsoft.AF.Asset.AFElement]::LoadElementsToDepth($rootElements, $true, 64, 200000) | Out-Null
        $loadMethod = 'LoadElementsToDepth(fullLoad)'
        $useLevelLoad = $false
    }
    catch {
        Write-InventoryLog -Level WARN -Dataset $Dataset -Message "LoadElementsToDepth falhou, caindo para carga por nível: $($_.Exception.Message)"
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $currentLevel = $rootElements
    $depth = 0

    while ($currentLevel.Count -gt 0 -and $depth -lt 64) {
        if ($useLevelLoad) {
            try {
                [OSIsoft.AF.Asset.AFElement]::LoadElements($currentLevel)
                $loadMethod = 'LoadElements(por nível)'
            }
            catch {
                Write-InventoryLog -Level WARN -Dataset $Dataset -Message "LoadElements falhou no nível $depth : $($_.Exception.Message)"
            }
        }

        $nextLevel = New-Object 'System.Collections.Generic.List[OSIsoft.AF.Asset.AFElement]'
        foreach ($element in $currentLevel) {
            $path = $null
            try { $path = $element.GetPath() } catch { $path = $element.Name }

            $entries.Add([pscustomobject]@{
                    Element = $element
                    Level   = $depth + 1
                    Path    = $path
                })

            try {
                foreach ($child in $element.Elements) { $nextLevel.Add($child) }
            }
            catch { }
        }

        $currentLevel = $nextLevel
        $depth++
    }

    Write-InventoryLog -Dataset $Dataset -Message ('{0} elementos em {1} níveis via {2}.' -f $entries.Count, $depth, $loadMethod)

    return [pscustomobject]@{
        Entries    = $entries
        LoadMethod = $loadMethod
        Depth      = $depth
    }
}

function Export-PIPointHealth {
    <#
        .SYNOPSIS
            Exporta o estado atual (snapshot) de cada PI Point.
        .DESCRIPTION
            Dataset intradiário: detecta interface parada (tag stale) e tag criada e nunca alimentada.
            Usa PIPointList.Snapshot() para ler todos os pontos numa chamada.

            `has_ever_received_data` é HEURÍSTICO: combina o estado de sistema 'Pt Created' com a
            coincidência entre o timestamp do snapshot e a data de criação. Restore de backup e
            realimentação furam a detecção. Nunca delete uma tag com base apenas neste sinal.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .PARAMETER NameFilter
            Filtro de nome de tag. Padrão: pi.pointNameFilter do settings.json.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [string] $NameFilter
    )

    $dataset = 'pipoint_health'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'name', 'pointid', 'pointtype', 'pointsource',
        'snapshot_value', 'snapshot_status', 'snapshot_time', 'is_good',
        'age_hours', 'age_days', 'is_stale',
        'is_pt_created', 'has_ever_received_data', 'creationdate'
    )

    try {
        $filter = if ($PSBoundParameters.ContainsKey('NameFilter')) { $NameFilter } else { [string]$Context.EnvironmentConfig.pointNameFilter }
        if ([string]::IsNullOrWhiteSpace($filter)) { $filter = '*' }

        $staleHours = [double]$Context.Config.thresholds.staleThresholdHours
        if ($staleHours -le 0) { $staleHours = 24 }

        $preload = [string[]]@('pointid', 'pointtype', 'pointsource', 'creationdate')
        $points = @([OSIsoft.AF.PI.PIPoint]::FindPIPoints($Context.PIServer, $filter, $null, $preload))

        $pointList = New-Object OSIsoft.AF.PI.PIPointList
        foreach ($point in $points) { $pointList.Add($point) }

        $results = $pointList.Snapshot()
        $now = Get-Date

        $rows = New-Object System.Collections.Generic.List[object]
        $staleCount = 0
        $badCount = 0
        $neverFedCount = 0

        foreach ($value in $results) {
            $point = $value.PIPoint
            if ($null -eq $point) { continue }

            $timestamp = $null
            try { $timestamp = $value.Timestamp.LocalTime } catch { }

            $valueText = $null
            try { $valueText = [string]$value.Value } catch { }

            $isGood = $false
            try { $isGood = [bool]$value.IsGood } catch { }

            $creation = $null
            try { $creation = ConvertTo-InventoryDateTime $point.GetAttribute('creationdate') } catch { }

            $ageHours = $null
            $isStale = $false
            if ($null -ne $timestamp) {
                $ageHours = [math]::Round(($now - $timestamp).TotalHours, 3)
                $isStale = ($ageHours -gt $staleHours)
            }

            # Ponto nunca alimentado permanece no estado de sistema 'Pt Created'.
            $isPtCreated = ($valueText -eq 'Pt Created')
            $hasEverReceived = -not $isPtCreated
            if ($hasEverReceived -and $null -ne $creation -and $null -ne $timestamp) {
                if ([math]::Abs(($timestamp - $creation).TotalMinutes) -lt 1) { $hasEverReceived = $false }
            }

            if ($isStale) { $staleCount++ }
            if (-not $isGood) { $badCount++ }
            if (-not $hasEverReceived) { $neverFedCount++ }

            $rows.Add([pscustomobject]@{
                    name                   = $point.Name
                    pointid                = $(try { $point.GetAttribute('pointid') } catch { $null })
                    pointtype              = $(try { [string]$point.GetAttribute('pointtype') } catch { $null })
                    pointsource            = $(try { [string]$point.GetAttribute('pointsource') } catch { $null })
                    snapshot_value         = $valueText
                    snapshot_status        = [string]$value.Status
                    snapshot_time          = $timestamp
                    is_good                = $isGood
                    age_hours              = $ageHours
                    age_days               = $(if ($null -ne $ageHours) { [math]::Round($ageHours / 24, 3) } else { $null })
                    is_stale               = $isStale
                    is_pt_created          = $isPtCreated
                    has_ever_received_data = $hasEverReceived
                    creationdate           = $creation
                })
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()

        Write-InventoryLog -Dataset $dataset -Message (
            '{0} linhas em {1} ms. stale={2} bad={3} sem_dados={4} (limite {5} h).' -f
            $written.row_count, $stopwatch.ElapsedMilliseconds, $staleCount, $badCount, $neverFedCount, $staleHours
        )

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{
            stale_count           = $staleCount
            bad_count             = $badCount
            never_fed_count       = $neverFedCount
            stale_threshold_hours = $staleHours
        }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-PIDigitalSetInventory {
    <#
        .SYNOPSIS
            Exporta os digital states de cada digital set do Data Archive.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'digitalsets'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $columns = @('set_name', 'state_value', 'state_name')

    try {
        $rows = New-Object System.Collections.Generic.List[object]
        $setCount = 0

        foreach ($stateSet in $Context.PIServer.StateSets) {
            $setCount++
            $index = 0
            foreach ($state in $stateSet) {
                $stateValue = $index
                try { if ($null -ne $state.Value) { $stateValue = $state.Value } } catch { }

                $rows.Add([pscustomobject]@{
                        set_name    = $stateSet.Name
                        state_value = $stateValue
                        state_name  = [string]$state.Name
                    })
                $index++
            }
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()
        Write-InventoryLog -Dataset $dataset -Message ('{0} estados em {1} conjuntos, {2} ms.' -f $written.row_count, $setCount, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{ set_count = $setCount }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFElementInventory {
    <#
        .SYNOPSIS
            Exporta a hierarquia de elementos do AF Database.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'elements'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'element_path', 'element_name', 'parent_path', 'element_level',
        'template_name', 'categories', 'description',
        'child_count', 'attribute_count', 'creation_date', 'modify_date', 'guid'
    )

    try {
        $catalog = Get-AFElementCatalog -Context $Context -Dataset $dataset
        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($entry in $catalog.Entries) {
            $element = $entry.Element

            $parentPath = $null
            try { if ($null -ne $element.Parent) { $parentPath = $element.Parent.GetPath() } } catch { }

            $childCount = $null
            try { $childCount = $element.Elements.Count } catch { }

            $attributeCount = $null
            try { $attributeCount = $element.Attributes.Count } catch { }

            $rows.Add([pscustomobject]@{
                    element_path    = $entry.Path
                    element_name    = $element.Name
                    parent_path     = $parentPath
                    element_level   = $entry.Level
                    template_name   = Get-SafeName $element.Template
                    categories      = Join-CategoryName $element.Categories
                    description     = $(try { [string]$element.Description } catch { $null })
                    child_count     = $childCount
                    attribute_count = $attributeCount
                    creation_date   = $(try { ConvertTo-InventoryDateTime $element.CreationDate } catch { $null })
                    modify_date     = $(try { ConvertTo-InventoryDateTime $element.ModifyDate } catch { $null })
                    guid            = [string]$element.ID
                })
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()
        Write-InventoryLog -Dataset $dataset -Message ('{0} linhas gravadas em {1} ms.' -f $written.row_count, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{ load_method = $catalog.LoadMethod; max_depth = $catalog.Depth }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFTemplateInventory {
    <#
        .SYNOPSIS
            Exporta element templates e attribute templates com sua estrutura.
        .DESCRIPTION
            Uma linha por template (row_type 'element_template') e uma por attribute template
            (row_type 'attribute_template'). O ConfigString do template guarda o padrão com
            substituições `%Element%`, útil para comparar a intenção contra o que foi instanciado.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'templates'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'row_type', 'template_name', 'instance_type', 'base_template', 'categories', 'description',
        'attribute_template_name', 'attribute_template_path', 'attribute_level',
        'type', 'uom', 'data_reference', 'config_string',
        'resolved_tag', 'is_dynamic_reference', 'parse_status',
        'is_configuration_item', 'guid', 'has_sensitive_hint'
    )

    try {
        $patterns = $Context.SensitivePatterns
        $rows = New-Object System.Collections.Generic.List[object]
        $templateCount = 0

        foreach ($template in $Context.AFDatabase.ElementTemplates) {
            $templateCount++
            $instanceType = $null
            try { $instanceType = [string]$template.InstanceType } catch { }

            $rows.Add([pscustomobject]@{
                    row_type      = 'element_template'
                    template_name = $template.Name
                    instance_type = $instanceType
                    base_template = Get-SafeName $template.BaseTemplate
                    categories    = Join-CategoryName $template.Categories
                    description   = $(try { [string]$template.Description } catch { $null })
                    guid          = [string]$template.ID
                })

            $stack = New-Object System.Collections.Stack
            try {
                foreach ($attributeTemplate in $template.AttributeTemplates) {
                    $stack.Push([pscustomobject]@{ Item = $attributeTemplate; Level = 1 })
                }
            }
            catch {
                Write-InventoryLog -Level WARN -Dataset $dataset -Message "Attribute templates de '$($template.Name)' ilegíveis: $($_.Exception.Message)"
                continue
            }

            while ($stack.Count -gt 0) {
                $node = $stack.Pop()
                $attributeTemplate = $node.Item

                $dataReference = $null
                try { $dataReference = Get-SafeName $attributeTemplate.DataReferencePlugIn } catch { }

                $configString = $null
                try { $configString = [string]$attributeTemplate.ConfigString } catch { }

                $parsed = ConvertFrom-AFConfigString -ConfigString $configString -DataReference $dataReference

                $rows.Add([pscustomobject]@{
                        row_type                = 'attribute_template'
                        template_name           = $template.Name
                        instance_type           = $instanceType
                        attribute_template_name = $attributeTemplate.Name
                        attribute_template_path = $(try { $attributeTemplate.GetPath() } catch { $attributeTemplate.Name })
                        attribute_level         = $node.Level
                        type                    = $(try { if ($null -ne $attributeTemplate.Type) { $attributeTemplate.Type.Name } else { $null } } catch { $null })
                        uom                     = $(try { Get-SafeName $attributeTemplate.DefaultUOM } catch { $null })
                        categories              = Join-CategoryName $attributeTemplate.Categories
                        description             = $(try { [string]$attributeTemplate.Description } catch { $null })
                        data_reference          = $dataReference
                        config_string           = $configString
                        resolved_tag            = $parsed.resolved_tag
                        is_dynamic_reference    = $parsed.is_dynamic_reference
                        parse_status            = $parsed.parse_status
                        is_configuration_item   = $(try { $attributeTemplate.IsConfigurationItem } catch { $null })
                        guid                    = [string]$attributeTemplate.ID
                        has_sensitive_hint      = Test-SensitiveHint -Value @($configString) -Pattern $patterns
                    })

                try {
                    foreach ($child in $attributeTemplate.AttributeTemplates) {
                        $stack.Push([pscustomobject]@{ Item = $child; Level = $node.Level + 1 })
                    }
                }
                catch { }
            }
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()
        Write-InventoryLog -Dataset $dataset -Message ('{0} linhas de {1} templates, {2} ms.' -f $written.row_count, $templateCount, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{ template_count = $templateCount }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFEventFrameInventory {
    <#
        .SYNOPSIS
            Exporta os event frames da janela configurada.
        .DESCRIPTION
            `Find-AFEventFrame` não aceita -TemplateName nesta versão; usa-se AFEventFrameSearch.

            Por padrão coleta TODOS os templates. Filtrar por um template fixo esconderia os demais,
            e o `template` já vem como coluna para o Fabric segmentar. Para restringir, preencha
            `pi.eventFrameTemplates` no settings.json.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .PARAMETER LookbackDays
            Janela em dias. Padrão: thresholds.eventFrameLookbackDays.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [int] $LookbackDays
    )

    $dataset = 'eventframes'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'event_frame_name', 'template_name', 'start_time', 'end_time', 'duration_minutes', 'is_open',
        'primary_element', 'primary_element_path', 'referenced_element_count',
        'severity', 'categories', 'description', 'are_values_captured',
        'parent_guid', 'guid'
    )

    try {
        $days = 0
        if ($PSBoundParameters.ContainsKey('LookbackDays')) {
            $days = $LookbackDays
        }
        elseif ($Context.EnvironmentConfig.PSObject.Properties['eventFrameLookbackDays']) {
            $days = [int]$Context.EnvironmentConfig.eventFrameLookbackDays
        }
        if ($days -le 0) { $days = [int]$Context.Config.thresholds.eventFrameLookbackDays }
        if ($days -le 0) { $days = 30 }

        $templateFilter = @()
        if ($Context.EnvironmentConfig.PSObject.Properties['eventFrameTemplates']) {
            $templateFilter = @($Context.EnvironmentConfig.eventFrameTemplates) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }

        # Dentro de query string do AF Search a sintaxe de tempo do PI funciona. Ver armadilha 5.
        $queries = New-Object System.Collections.Generic.List[string]
        if ($templateFilter.Count -gt 0) {
            foreach ($templateName in $templateFilter) {
                $queries.Add(("template:'{0}' start:>'*-{1}d'" -f $templateName, $days))
            }
        }
        else {
            $queries.Add(("start:>'*-{0}d'" -f $days))
        }

        $rows = New-Object System.Collections.Generic.List[object]
        $skippedTemplates = New-Object System.Collections.Generic.List[string]

        foreach ($query in $queries) {
            $search = $null
            try {
                $search = New-Object OSIsoft.AF.Search.AFEventFrameSearch($Context.AFDatabase, 'InventoryEF', $query)
                [void]$search.GetTotalCount()
            }
            catch {
                # Template inexistente derruba a busca inteira; registra e segue.
                $skippedTemplates.Add($query)
                Write-InventoryLog -Level WARN -Dataset $dataset -Message "Busca ignorada ($query): $($_.Exception.Message)"
                continue
            }

            # fullLoad=$true é decisivo: com $false cada acesso a elemento referenciado vira
            # round-trip e a coleta passa de ~30 s para ~5 min. Ver armadilha 15.
            foreach ($frame in $search.FindObjects(0, $true, 1000)) {
                $startTime = $null
                try { $startTime = $frame.StartTime.LocalTime } catch { }

                $endTime = $null
                $isOpen = $false
                try {
                    $candidate = $frame.EndTime.LocalTime
                    if ($candidate.Year -ge 9999) { $isOpen = $true } else { $endTime = $candidate }
                }
                catch { }

                $duration = $null
                if ($null -ne $startTime -and $null -ne $endTime) {
                    $duration = [math]::Round(($endTime - $startTime).TotalMinutes, 3)
                }

                $primary = $null
                $primaryPath = $null
                $referenceCount = 0
                try {
                    $referenceCount = $frame.ReferencedElements.Count
                    $primaryElement = $frame.PrimaryReferencedElement
                    if ($null -eq $primaryElement -and $referenceCount -gt 0) {
                        $primaryElement = $frame.ReferencedElements[0]
                    }
                    if ($null -ne $primaryElement) {
                        $primary = $primaryElement.Name
                        $primaryPath = $primaryElement.GetPath()
                    }
                }
                catch { }

                $rows.Add([pscustomobject]@{
                        event_frame_name         = $frame.Name
                        template_name            = Get-SafeName $frame.Template
                        start_time               = $startTime
                        end_time                 = $endTime
                        duration_minutes         = $duration
                        is_open                  = $isOpen
                        primary_element          = $primary
                        primary_element_path     = $primaryPath
                        referenced_element_count = $referenceCount
                        severity                 = $(try { [string]$frame.Severity } catch { $null })
                        categories               = Join-CategoryName $frame.Categories
                        description              = $(try { [string]$frame.Description } catch { $null })
                        are_values_captured      = $(try { [bool]$frame.AreValuesCaptured } catch { $null })
                        parent_guid              = $(try { if ($null -ne $frame.Parent) { [string]$frame.Parent.ID } else { $null } } catch { $null })
                        guid                     = [string]$frame.ID
                    })
            }
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()

        $status = if ($skippedTemplates.Count -gt 0) { 'degraded' } else { 'success' }
        Write-InventoryLog -Dataset $dataset -Message ('{0} event frames em {1} dias, {2} ms.' -f $written.row_count, $days, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status $status `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{
            lookback_days     = $days
            template_filter   = $templateFilter
            skipped_queries   = $skippedTemplates.ToArray()
        }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFAnalysisInventory {
    <#
        .SYNOPSIS
            Exporta as analyses do AF Database com o status de execução.
        .DESCRIPTION
            A estrutura vem sempre da coleção AFDatabase.Analyses, que é confiável. O status de
            execução vem de AnalysisService.QueryRuntimeInformation, que pode exigir permissão
            adicional no serviço.

            A coluna `status_source` diz qual caminho foi usado. Sem ela o Fabric trataria uma
            simples listagem como se fosse status real e a view de analysis em erro ficaria vazia
            parecendo saudável.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'analyses'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'analysis_name', 'analysis_path', 'target_path', 'target_name', 'template_name',
        'analysis_rule', 'time_rule', 'categories', 'description',
        'configured_status', 'is_configured', 'auto_created', 'has_notification', 'priority',
        'runtime_status', 'last_evaluation_status', 'last_trigger_time',
        'error_count', 'success_count', 'skip_count', 'last_elapsed_ms',
        'status_source', 'creation_date', 'modify_date', 'guid'
    )

    try {
        $runtimeFields = @('id', 'status', 'lastevaluationstatus', 'lasttriggertime', 'errorcount', 'successcount', 'skipcount', 'lastelapsed')
        $runtimeMap = @{}
        $statusSource = 'FallbackListOnly'

        try {
            $rawRuntime = $Context.PISystem.AnalysisService.QueryRuntimeInformation("path:'*'", ($runtimeFields -join ' '))
            foreach ($record in $rawRuntime) {
                $fields = @($record)
                if ($fields.Count -lt $runtimeFields.Count) { continue }
                $key = ([string]$fields[0]).ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                $runtimeMap[$key] = $fields
            }
            if ($runtimeMap.Count -gt 0) { $statusSource = 'QueryRuntimeInformation' }
        }
        catch {
            Write-InventoryLog -Level WARN -Dataset $dataset -Message "QueryRuntimeInformation indisponível, exportando apenas a listagem: $($_.Exception.Message)"
        }

        Write-InventoryLog -Dataset $dataset -Message "Origem do status: $statusSource ($($runtimeMap.Count) registros de runtime)."

        $rows = New-Object System.Collections.Generic.List[object]
        $errorCount = 0

        foreach ($analysis in $Context.AFDatabase.Analyses) {
            $guid = [string]$analysis.ID
            $runtime = $runtimeMap[$guid.ToLowerInvariant()]

            $runtimeStatus = $null
            $lastEvaluation = $null
            $lastTrigger = $null
            $errors = $null
            $successes = $null
            $skips = $null
            $lastElapsed = $null

            if ($null -ne $runtime) {
                $runtimeStatus = [string]$runtime[1]
                $lastEvaluation = [string]$runtime[2]
                $lastTrigger = ConvertTo-InventoryDateTime $runtime[3]
                $errors = $runtime[4]
                $successes = $runtime[5]
                $skips = $runtime[6]
                $lastElapsed = $runtime[7]
                if ($runtimeStatus -eq 'Error') { $errorCount++ }
            }

            $rows.Add([pscustomobject]@{
                    analysis_name          = $analysis.Name
                    analysis_path          = $(try { $analysis.GetPath() } catch { $null })
                    target_path            = $(try { if ($null -ne $analysis.Target) { $analysis.Target.GetPath() } else { $null } } catch { $null })
                    target_name            = Get-SafeName $analysis.Target
                    template_name          = Get-SafeName $analysis.Template
                    analysis_rule          = Get-SafeName $analysis.AnalysisRulePlugIn
                    time_rule              = Get-SafeName $analysis.TimeRulePlugIn
                    categories             = Join-CategoryName $analysis.Categories
                    description            = $(try { [string]$analysis.Description } catch { $null })
                    configured_status      = $(try { [string]$analysis.Status } catch { $null })
                    is_configured          = $(try { [bool]$analysis.IsConfigured } catch { $null })
                    auto_created           = $(try { [bool]$analysis.AutoCreated } catch { $null })
                    has_notification       = $(try { [bool]$analysis.HasNotification } catch { $null })
                    priority               = $(try { [string]$analysis.Priority } catch { $null })
                    runtime_status         = $runtimeStatus
                    last_evaluation_status = $lastEvaluation
                    last_trigger_time      = $lastTrigger
                    error_count            = $errors
                    success_count          = $successes
                    skip_count             = $skips
                    last_elapsed_ms        = $lastElapsed
                    status_source          = $statusSource
                    creation_date          = $(try { ConvertTo-InventoryDateTime $analysis.CreationDate } catch { $null })
                    modify_date            = $(try { ConvertTo-InventoryDateTime $analysis.ModifyDate } catch { $null })
                    guid                   = $guid
                })
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()

        # Degradação declarada em knownDegradations fica visível no dado, mas não eleva o exit
        # code: se um ambiente sabidamente sem status de runtime marcasse o run como degradado
        # todo dia, o código 2 deixaria de ser sinal.
        $status = 'success'
        $knownDegradation = $null
        if ($statusSource -ne 'QueryRuntimeInformation') {
            $knownDegradation = Get-KnownDegradation -Context $Context -Dataset $dataset -Signal $statusSource
            if ($null -ne $knownDegradation) {
                Write-InventoryLog -Dataset $dataset -Message ("Degradação declarada '{0}': {1}" -f $statusSource, $knownDegradation.reason)
            }
            else {
                $status = 'degraded'
            }
        }

        Write-InventoryLog -Dataset $dataset -Message ('{0} analyses, {1} em erro, {2} ms.' -f $written.row_count, $errorCount, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status $status `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{
            status_source      = $statusSource
            error_status_count = $errorCount
            known_degradation  = $(if ($null -ne $knownDegradation) { [string]$knownDegradation.signal } else { $null })
        }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFAnalysisOutputInventory {
    <#
        .SYNOPSIS
            Exporta as saídas de cada analysis: qual atributo ela escreve e em qual tag.
        .DESCRIPTION
            Uma linha por par (analysis, atributo de saída). O dataset `analyses` tem grão de
            analysis; este tem grão de saída, porque uma analysis pode escrever em vários atributos.

            É o que permite detectar escrita concorrente — duas analyses de camadas diferentes
            gravando na mesma tag do mesmo Data Archive:

                SELECT resolved_server_id, resolved_tag, COUNT(DISTINCT environment)
                FROM silver_analysis_output
                GROUP BY 1, 2
                HAVING COUNT(DISTINCT environment) > 1

            A tag sai do ConfigString do atributo de saída, com o mesmo parser do dataset
            `attributes`. O `resolved_server_id` é indispensável aqui: nomes de tag podem coincidir
            entre camadas, GUID de Data Archive não.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'analysis_outputs'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $columns = @(
        'analysis_name', 'analysis_path', 'analysis_guid', 'analysis_template',
        'target_path', 'variable_name', 'mapped_target', 'mapping_raw',
        'output_attribute_name', 'output_attribute_path', 'output_element_path',
        'data_reference', 'config_string',
        'resolved_server', 'resolved_server_id', 'resolved_tag', 'resolved_point_id',
        'parse_status', 'has_sensitive_hint'
    )

    try {
        $patterns = $Context.SensitivePatterns
        $rows = New-Object System.Collections.Generic.List[object]
        $analysisCount = 0
        $unreadable = 0
        $mappedCount = 0

        foreach ($analysis in $Context.AFDatabase.Analyses) {
            $analysisCount++

            $rule = $analysis.AnalysisRule
            if ($null -eq $rule) { continue }

            $mappingRaw = $null
            try { $mappingRaw = [string]$rule.SimplifiedVariableMapping } catch { }
            if ([string]::IsNullOrWhiteSpace($mappingRaw)) {
                try { $mappingRaw = [string]$rule.VariableMapping } catch { }
            }

            # GetOutputs devolve o atributo real so quando a saida esta ligada a um elemento;
            # caso contrario vem um placeholder 'Output' sem Element e sem Data Reference.
            $realOutputs = New-Object System.Collections.Generic.List[object]
            try {
                foreach ($candidate in @($rule.GetOutputs())) {
                    if ($null -ne $candidate -and $null -ne $candidate.Element) { $realOutputs.Add($candidate) }
                }
            }
            catch { $unreadable++ }

            $analysisPath = $(try { $analysis.GetPath() } catch { $null })
            $targetPath = $(try { if ($null -ne $analysis.Target) { $analysis.Target.GetPath() } else { $null } } catch { $null })
            $analysisGuid = [string]$analysis.ID
            $templateName = Get-SafeName $analysis.Template

            $entries = New-Object System.Collections.Generic.List[object]

            if (-not [string]::IsNullOrWhiteSpace($mappingRaw)) {
                foreach ($entry in $mappingRaw.Split(';')) {
                    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
                    $parts = $entry.Split(@('||'), [System.StringSplitOptions]::None)
                    $variable = $parts[0].Trim()
                    $mapped = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $null }

                    if ($variable -eq '[GUID]') { continue }
                    if ($mapped -eq '[UNSET]' -or [string]::IsNullOrWhiteSpace($mapped)) { continue }

                    $entries.Add([pscustomobject]@{ Variable = $variable; Mapped = $mapped })
                }
            }

            if ($entries.Count -eq 0 -and $realOutputs.Count -eq 0) { continue }

            $index = 0
            foreach ($entry in $entries) {
                # O atributo real, quando existe, vem na mesma ordem das saidas declaradas.
                $attribute = if ($index -lt $realOutputs.Count) { $realOutputs[$index] } else { $null }

                $dataReference = $null
                $configString = $null
                if ($null -ne $attribute) {
                    try { $dataReference = Get-SafeName $attribute.DataReferencePlugIn } catch { }
                    try { $configString = [string]$attribute.ConfigString } catch { }
                }

                $parsed = ConvertFrom-AFConfigString -ConfigString $configString -DataReference $dataReference
                if ($parsed.resolved_tag) { $mappedCount++ }

                $rows.Add([pscustomobject]@{
                        analysis_name         = $analysis.Name
                        analysis_path         = $analysisPath
                        analysis_guid         = $analysisGuid
                        analysis_template     = $templateName
                        target_path           = $targetPath
                        variable_name         = $entry.Variable
                        mapped_target         = $entry.Mapped
                        mapping_raw           = $mappingRaw
                        output_attribute_name = $(if ($null -ne $attribute) { $attribute.Name } else { $null })
                        output_attribute_path = $(if ($null -ne $attribute) { try { $attribute.GetPath() } catch { $null } } else { $null })
                        output_element_path   = $(if ($null -ne $attribute) { try { $attribute.Element.GetPath() } catch { $null } } else { $null })
                        data_reference        = $dataReference
                        config_string         = $configString
                        resolved_server       = $parsed.resolved_server
                        resolved_server_id    = $parsed.resolved_server_id
                        resolved_tag          = $parsed.resolved_tag
                        resolved_point_id     = $parsed.resolved_point_id
                        parse_status          = $parsed.parse_status
                        has_sensitive_hint    = Test-SensitiveHint -Value @($configString) -Pattern $patterns
                    })

                $index++
            }
        }

        if ($unreadable -gt 0) {
            Write-InventoryLog -Level WARN -Dataset $dataset -Message "$unreadable analyses não expuseram suas saídas."
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()

        Write-InventoryLog -Dataset $dataset -Message (
            '{0} saídas mapeadas de {1} analyses ({2} com tag já resolvida na extração), {3} ms.' -f
            $written.row_count, $analysisCount, $mappedCount, $stopwatch.ElapsedMilliseconds
        )

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file `
            -Metrics @{
            analysis_count     = $analysisCount
            unreadable_count   = $unreadable
            resolved_tag_count = $mappedCount
        }
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFEnumerationSetInventory {
    <#
        .SYNOPSIS
            Exporta os enumeration sets do AF Database.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'enumsets'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $columns = @('set_name', 'set_guid', 'value', 'value_name', 'description')

    try {
        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($enumerationSet in $Context.AFDatabase.EnumerationSets) {
            $setGuid = [string]$enumerationSet.ID
            foreach ($enumerationValue in $enumerationSet) {
                $rows.Add([pscustomobject]@{
                        set_name    = $enumerationSet.Name
                        set_guid    = $setGuid
                        value       = $(try { $enumerationValue.Value } catch { $null })
                        value_name  = [string]$enumerationValue.Name
                        description = $(try { [string]$enumerationValue.Description } catch { $null })
                    })
            }
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()
        Write-InventoryLog -Dataset $dataset -Message ('{0} linhas gravadas em {1} ms.' -f $written.row_count, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFUomInventory {
    <#
        .SYNOPSIS
            Exporta as unidades de medida do PI System.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'uom'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $columns = @('uom_class', 'uom_name', 'abbreviation', 'is_canonical', 'factor', 'offset', 'guid')

    try {
        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($uom in $Context.PISystem.UOMDatabase.UOMs) {
            $className = $null
            $isCanonical = $null
            try {
                $className = Get-SafeName $uom.Class
                if ($null -ne $uom.Class -and $null -ne $uom.Class.CanonicalUOM) {
                    $isCanonical = ($uom.Class.CanonicalUOM.ID -eq $uom.ID)
                }
            }
            catch { }

            $rows.Add([pscustomobject]@{
                    uom_class    = $className
                    uom_name     = $uom.Name
                    abbreviation = $(try { [string]$uom.Abbreviation } catch { $null })
                    is_canonical = $isCanonical
                    factor       = $(try { $uom.Factor } catch { $null })
                    offset       = $(try { $uom.Offset } catch { $null })
                    guid         = [string]$uom.ID
                })
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()
        Write-InventoryLog -Dataset $dataset -Message ('{0} linhas gravadas em {1} ms.' -f $written.row_count, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Export-AFTableInventory {
    <#
        .SYNOPSIS
            Exporta os metadados das AF Tables.
        .DESCRIPTION
            Só metadados: materializar a tabela executaria a consulta externa da fonte ligada,
            o que sai do escopo de um inventário e pode ser lento ou indisponível.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .OUTPUTS
            PSCustomObject com dataset, status, row_count, duration_ms, file, error e metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context
    )

    $dataset = 'tables'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $columns = @('table_name', 'categories', 'description', 'is_linked', 'time_zone', 'creation_date', 'modify_date', 'guid')

    try {
        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($table in $Context.AFDatabase.Tables) {
            $isLinked = $null
            try { $isLinked = ($null -ne $table.ConnectionInfo) } catch { }

            $rows.Add([pscustomobject]@{
                    table_name    = $table.Name
                    categories    = Join-CategoryName $table.Categories
                    description   = $(try { [string]$table.Description } catch { $null })
                    is_linked     = $isLinked
                    time_zone     = $(try { [string]$table.TimeZone } catch { $null })
                    creation_date = $(try { ConvertTo-InventoryDateTime $table.CreationDate } catch { $null })
                    modify_date   = $(try { ConvertTo-InventoryDateTime $table.ModifyDate } catch { $null })
                    guid          = [string]$table.ID
                })
        }

        $written = Write-InventoryOutput -InputObject $rows.ToArray() -Dataset $dataset -Context $Context -Column $columns
        $stopwatch.Stop()
        Write-InventoryLog -Dataset $dataset -Message ('{0} linhas gravadas em {1} ms.' -f $written.row_count, $stopwatch.ElapsedMilliseconds)

        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'success' `
            -RowCount $written.row_count -DurationMs $stopwatch.ElapsedMilliseconds -File $written.file
    }
    catch {
        $stopwatch.Stop()
        Write-InventoryLog -Level ERROR -Dataset $dataset -Message $_.Exception.Message
        return Add-DatasetResult -Context $Context -Dataset $dataset -Status 'failed' `
            -RowCount 0 -DurationMs $stopwatch.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
    }
}

function Get-InventoryDatasetMap {
    <#
        .SYNOPSIS
            Mapeia o nome lógico de cada dataset para a função de export correspondente.
        .DESCRIPTION
            Ponto único de registro: adicionar um dataset novo é uma linha aqui mais a entrada
            em `datasets.metadata` ou `datasets.health` no settings.json.
        .OUTPUTS
            OrderedDictionary de nome do dataset para nome da função.
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        'pipoints'       = 'Export-PIPointInventory'
        'pipoint_health' = 'Export-PIPointHealth'
        'digitalsets'    = 'Export-PIDigitalSetInventory'
        'elements'       = 'Export-AFElementInventory'
        'attributes'     = 'Export-AFAttributeInventory'
        'templates'      = 'Export-AFTemplateInventory'
        'eventframes'    = 'Export-AFEventFrameInventory'
        'analyses'         = 'Export-AFAnalysisInventory'
        'analysis_outputs' = 'Export-AFAnalysisOutputInventory'
        'enumsets'         = 'Export-AFEnumerationSetInventory'
        'uom'              = 'Export-AFUomInventory'
        'tables'           = 'Export-AFTableInventory'
    }
}

function Write-InventoryManifest {
    <#
        .SYNOPSIS
            Grava o manifesto da execução ao lado dos dados.
        .DESCRIPTION
            É o que o notebook 01_bronze_ingest usa para decidir se o run é íntegro e para alimentar
            gold_vw_run_performance. Viaja junto com os CSVs.

            O nome inclui tipo de run e timestamp porque a coleta de health roda várias vezes por dia
            na mesma pasta datada.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .PARAMETER DurationMs
            Duração total da execução.
        .OUTPUTS
            PSCustomObject com path, file, status e contagens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [long] $DurationMs = 0
    )

    # @() sobre List[T] pode lançar ArgumentException ou devolver vazio; ToArray() é determinístico.
    $datasets = $Context.Datasets.ToArray()
    $failed = @($datasets | Where-Object { $_.status -eq 'failed' })
    $degraded = @($datasets | Where-Object { $_.status -eq 'degraded' })

    $status = 'success'
    if ($failed.Count -gt 0) { $status = 'partial' }
    elseif ($degraded.Count -gt 0) { $status = 'degraded' }

    $manifest = [ordered]@{
        run_id                  = $Context.RunId
        run_type                = $Context.RunType
        environment             = $Context.Environment
        environment_name        = $Context.EnvironmentName
        tier                    = $Context.Tier
        site                    = $Context.Site
        site_name               = $Context.SiteName
        snapshot_date           = $Context.SnapshotDate
        snapshot_stamp          = $Context.SnapshotStamp
        snapshot_ts             = $Context.SnapshotTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffK")
        status                  = $status
        duration_ms             = $DurationMs
        module_version          = $Context.ModuleVersion
        machine                 = $env:COMPUTERNAME
        user                    = "$env:USERDOMAIN\$env:USERNAME"
        pi_data_archive         = $Context.SourceServer
        pi_data_archive_id      = $Context.SourceServerId
        pi_data_archive_version = [string]$Context.PIServer.ServerVersion
        af_server               = $Context.SourceAFServer
        af_server_id            = $Context.SourceAFServerId
        af_server_version       = [string]$Context.PISystem.ServerVersion
        af_database             = $Context.SourceAFDatabase
        af_database_id          = $Context.SourceAFDatabaseId
        known_degradations      = @($Context.EnvironmentConfig.knownDegradations)
        output_root             = $Context.BaseDir
        used_fallback_dir       = $Context.UsedFallbackDir
        dataset_count           = $datasets.Count
        failed_count            = $failed.Count
        degraded_count          = $degraded.Count
        row_count_total         = ($datasets | Measure-Object -Property row_count -Sum).Sum
        datasets                = $datasets
    }

    $fileName = '_manifest__{0}__{1}__{2}.json' -f $Context.RunType, $Context.Environment, $Context.SnapshotStamp
    $path = Join-Path $Context.SnapshotPath $fileName

    $json = $manifest | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))

    Write-InventoryLog -Message ('Manifesto gravado: {0} (status {1}).' -f $fileName, $status)

    return [pscustomobject]@{
        path           = $path
        file           = $fileName
        status         = $status
        failed_count   = $failed.Count
        degraded_count = $degraded.Count
    }
}

function Copy-InventorySnapshot {
    <#
        .SYNOPSIS
            Copia os arquivos desta execução para a pasta OneDrive sincronizada com o SharePoint.
        .DESCRIPTION
            Copia apenas os arquivos deste run (filtrados pelo timestamp) mais o manifesto, para não
            reenviar execuções anteriores do mesmo dia.

            O resultado vai para `_transfer__<runtype>__<stamp>.json`, que fica SOMENTE na máquina e
            nunca é copiado: é a única fonte que autoriza Remove-ExpiredSnapshot a apagar. Se o
            status da cópia morasse no manifesto, a versão que chega ao SharePoint carregaria
            'pendente' para sempre, porque ela é enviada antes de a transferência terminar.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .PARAMETER ManifestFile
            Nome do arquivo de manifesto a copiar junto.
        .OUTPUTS
            PSCustomObject com status, target, files_copied, files_expected e error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [string] $ManifestFile
    )

    $enabled = $true
    try { $enabled = [bool]$Context.Config.transfer.enabled } catch { }

    $result = [ordered]@{
        run_id         = $Context.RunId
        run_type       = $Context.RunType
        snapshot_date  = $Context.SnapshotDate
        snapshot_stamp = $Context.SnapshotStamp
        status         = 'skipped'
        target         = $null
        files_expected = 0
        files_copied   = 0
        bytes          = 0
        completed_at   = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ss.fffK")
        error          = $null
    }

    if (-not $enabled) {
        Write-InventoryLog -Level WARN -Message 'Transferência desabilitada em transfer.enabled; nada foi copiado.'
    }
    else {
        try {
            $target = Join-Path ([string]$Context.Config.transfer.oneDrivePath) $Context.SnapshotDate
            $result.target = $target

            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
            }

            $files = New-Object System.Collections.Generic.List[object]
            foreach ($file in Get-ChildItem -LiteralPath $Context.SnapshotPath -Filter ('*__{0}__{1}.csv' -f $Context.Environment, $Context.SnapshotStamp) -File) {
                $files.Add($file)
            }
            if ($ManifestFile) {
                $manifestPath = Join-Path $Context.SnapshotPath $ManifestFile
                if (Test-Path -LiteralPath $manifestPath) { $files.Add((Get-Item -LiteralPath $manifestPath)) }
            }

            $result.files_expected = $files.Count
            $copied = 0
            $bytes = 0

            foreach ($file in $files) {
                try {
                    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name) -Force -ErrorAction Stop
                    $copied++
                    $bytes += $file.Length
                }
                catch {
                    Write-InventoryLog -Level ERROR -Message "Falha ao copiar '$($file.Name)': $($_.Exception.Message)"
                }
            }

            $result.files_copied = $copied
            $result.bytes = $bytes
            $result.status = if ($copied -eq $files.Count -and $files.Count -gt 0) { 'success' }
            elseif ($copied -gt 0) { 'partial' }
            else { 'failed' }
        }
        catch {
            $result.status = 'failed'
            $result.error = $_.Exception.Message
            Write-InventoryLog -Level ERROR -Message "Transferência falhou: $($_.Exception.Message)"
        }

        $level = if ($result.status -eq 'success') { 'INFO' } else { 'WARN' }
        Write-InventoryLog -Level $level -Message ('Transferência {0}: {1} de {2} arquivos para {3}.' -f $result.status, $result.files_copied, $result.files_expected, $result.target)
    }

    $transferFile = '_transfer__{0}__{1}__{2}.json' -f $Context.RunType, $Context.Environment, $Context.SnapshotStamp
    $transferPath = Join-Path $Context.SnapshotPath $transferFile
    $json = ([pscustomobject]$result) | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($transferPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]$result
}

function Remove-ExpiredSnapshot {
    <#
        .SYNOPSIS
            Apaga snapshots locais antigos que já foram transportados.
        .DESCRIPTION
            Só remove uma pasta datada se TODAS as execuções nela tiverem `_transfer__*.json` com
            status 'success'. Snapshot que ainda não saiu da máquina nunca é apagado, mesmo vencido.

            Quando transfer.enabled é falso não existe transporte a exigir, e a pasta é removida
            apenas pela idade.

            O bronze no Fabric é o arquivo permanente; a cópia local serve para reprocessar.
        .PARAMETER Context
            Contexto devolvido por Initialize-PIConnection.
        .PARAMETER RetentionDays
            Dias a manter. Padrão: thresholds.retentionDays.
        .OUTPUTS
            PSCustomObject com removed, kept e skipped.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [int] $RetentionDays
    )

    $days = if ($PSBoundParameters.ContainsKey('RetentionDays')) { $RetentionDays } else { [int]$Context.Config.thresholds.retentionDays }
    if ($days -le 0) { $days = 60 }

    $transferRequired = $true
    try { $transferRequired = [bool]$Context.Config.transfer.enabled } catch { }

    $rawRoot = Split-Path -Parent $Context.SnapshotPath
    $cutoff = (Get-Date).Date.AddDays(-$days)

    $removed = New-Object System.Collections.Generic.List[string]
    $blocked = New-Object System.Collections.Generic.List[string]
    $kept = 0

    foreach ($directory in Get-ChildItem -LiteralPath $rawRoot -Directory -ErrorAction SilentlyContinue) {
        $folderDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($directory.Name, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$folderDate)) {
            continue
        }
        if ($folderDate -ge $cutoff) { $kept++; continue }

        # A regra é por execução, não por pasta: todo manifesto precisa do seu par de transferência.
        # Checar apenas os _transfer existentes deixaria passar um run que produziu dados e nunca
        # foi transportado — exatamente o que não pode ser apagado.
        $manifests = @(Get-ChildItem -LiteralPath $directory.FullName -Filter '_manifest__*.json' -File -ErrorAction SilentlyContinue)
        if ($manifests.Count -eq 0) {
            $blocked.Add(('{0} (sem manifesto: origem desconhecida)' -f $directory.Name))
            continue
        }

        $allTransferred = $true
        foreach ($manifest in $manifests) {
            $suffix = $manifest.Name -replace '^_manifest__', '' -replace '\.json$', ''
            $transferPath = Join-Path $directory.FullName ('_transfer__{0}.json' -f $suffix)

            if (-not (Test-Path -LiteralPath $transferPath)) {
                $blocked.Add(('{0} (execução {1} nunca foi transportada)' -f $directory.Name, $suffix))
                $allTransferred = $false
                break
            }

            $status = $null
            try { $status = ((Get-Content -LiteralPath $transferPath -Raw -Encoding UTF8) | ConvertFrom-Json).status } catch { }

            $accepted = if ($transferRequired) { @('success') } else { @('success', 'skipped') }
            if ($status -notin $accepted) {
                $blocked.Add(('{0} (execução {1} com transferência "{2}")' -f $directory.Name, $suffix, $status))
                $allTransferred = $false
                break
            }
        }

        if (-not $allTransferred) { continue }

        if ($PSCmdlet.ShouldProcess($directory.FullName, 'Remover snapshot expirado')) {
            try {
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
                $removed.Add($directory.Name)
            }
            catch {
                $blocked.Add(('{0} ({1})' -f $directory.Name, $_.Exception.Message))
            }
        }
    }

    foreach ($item in $blocked) {
        Write-InventoryLog -Level WARN -Message "Snapshot vencido preservado: $item"
    }
    Write-InventoryLog -Message ('Retenção de {0} dias: {1} removidos, {2} dentro da janela, {3} preservados por segurança.' -f $days, $removed.Count, $kept, $blocked.Count)

    return [pscustomobject]@{
        retention_days = $days
        removed        = $removed.ToArray()
        blocked        = $blocked.ToArray()
        kept           = $kept
    }
}

function Invoke-InventorySnapshot {
    <#
        .SYNOPSIS
            Executa uma coleta completa: exports, manifesto, transferência e retenção.
        .DESCRIPTION
            Cada export é independente: uma falha não interrompe os demais, apenas muda o exit code.

            Exit codes, lidos pelo Power Automate Desktop:
              0  tudo certo
              1  falha fatal (sem conexão, sem configuração) — nenhum dado foi produzido
              2  parcial ou degradado — há dados, mas algo merece atenção
        .PARAMETER RunType
            'metadata' (diário) ou 'health' (intradiário).
        .PARAMETER ConfigPath
            Caminho do settings.json.
        .PARAMETER Dataset
            Sobrescreve a lista de datasets do settings.json.
        .PARAMETER SkipTransfer
            Não copia para o OneDrive.
        .PARAMETER SkipRetention
            Não executa a purga de snapshots vencidos.
        .OUTPUTS
            PSCustomObject com ExitCode, Context, Manifest, Transfer e Retention.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('metadata', 'health')]
        [string] $RunType,

        [string] $ConfigPath,

        [string[]] $Environment,

        [string[]] $Dataset,

        [switch] $SkipTransfer,

        [switch] $SkipRetention
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $environments = @(Get-InventoryEnvironment -ConfigPath $ConfigPath)
    }
    catch {
        Write-InventoryLog -Level ERROR -Message "Falha fatal ao ler a configuração: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = 1; Runs = @(); Retention = $null }
    }

    if ($Environment -and $Environment.Count -gt 0) {
        $environments = @($environments | Where-Object { $Environment -contains $_.id })
    }

    if ($environments.Count -eq 0) {
        Write-InventoryLog -Level ERROR -Message 'Nenhum ambiente habilitado corresponde ao filtro.'
        return [pscustomobject]@{ ExitCode = 1; Runs = @(); Retention = $null }
    }

    $runs = New-Object System.Collections.Generic.List[object]
    $exitCode = 0
    $lastContext = $null

    foreach ($environmentConfig in $environments) {
        $envStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $context = $null

        try {
            $initArgs = @{ RunType = $RunType; Environment = $environmentConfig.id }
            if ($PSBoundParameters.ContainsKey('ConfigPath') -and $ConfigPath) { $initArgs['ConfigPath'] = $ConfigPath }
            $context = Initialize-PIConnection @initArgs
        }
        catch {
            # Um ambiente fora do ar não pode derrubar a coleta dos demais.
            $envStopwatch.Stop()
            Write-InventoryLog -Level ERROR -Message ("Ambiente '{0}' inacessível: {1}" -f $environmentConfig.id, $_.Exception.Message)
            $exitCode = 2
            $runs.Add([pscustomobject]@{
                    Environment = [string]$environmentConfig.id
                    ExitCode    = 1
                    Context     = $null
                    Manifest    = $null
                    Transfer    = $null
                    Error       = $_.Exception.Message
                })
            continue
        }

        $lastContext = $context
        $map = Get-InventoryDatasetMap
        $requested = if ($Dataset -and $Dataset.Count -gt 0) { $Dataset } else { @($context.Config.datasets.$RunType) }
        $unknown = 0

        foreach ($name in $requested) {
            if (-not $map.Contains($name)) {
                Write-InventoryLog -Level WARN -Message "Dataset '$name' não tem função registrada; ignorado."
                $unknown++
                continue
            }

            $functionName = $map[$name]
            try {
                & $functionName -Context $context | Out-Null
            }
            catch {
                # Os exports já capturam suas falhas; isto cobre erro na própria invocação.
                Write-InventoryLog -Level ERROR -Dataset $name -Message "Invocação de $functionName falhou: $($_.Exception.Message)"
                Add-DatasetResult -Context $context -Dataset $name -Status 'failed' -RowCount 0 -DurationMs 0 -ErrorMessage $_.Exception.Message | Out-Null
            }
        }

        $envStopwatch.Stop()
        $manifest = Write-InventoryManifest -Context $context -DurationMs $envStopwatch.ElapsedMilliseconds

        $transfer = $null
        if (-not $SkipTransfer) {
            $transfer = Copy-InventorySnapshot -Context $context -ManifestFile $manifest.file
        }

        $envExit = 0
        if ($manifest.status -ne 'success') { $envExit = 2 }
        if ($null -ne $transfer -and $transfer.status -notin @('success', 'skipped')) { $envExit = 2 }

        # Um run que não coletou nada não é sucesso, mesmo sem nenhuma falha registrada.
        if ($unknown -gt 0) {
            Write-InventoryLog -Level WARN -Message "$unknown nome(s) de dataset sem função registrada."
            $envExit = 2
        }
        if ($context.Datasets.Count -eq 0) {
            Write-InventoryLog -Level ERROR -Message 'Nenhum dataset foi coletado neste ambiente.'
            $envExit = 2
        }

        if ($envExit -gt $exitCode) { $exitCode = $envExit }

        Write-InventoryLog -Message (
            'Ambiente {0} concluído em {1:N1} s com exit code {2}.' -f
            $environmentConfig.id, ($envStopwatch.ElapsedMilliseconds / 1000), $envExit
        )

        $runs.Add([pscustomobject]@{
                Environment = [string]$environmentConfig.id
                ExitCode    = $envExit
                Context     = $context
                Manifest    = $manifest
                Transfer    = $transfer
                Error       = $null
            })
    }

    # Nenhum ambiente produziu dado: isso é falha fatal, não degradação.
    if (@($runs | Where-Object { $null -ne $_.Context }).Count -eq 0) { $exitCode = 1 }

    # A retenção varre a pasta datada inteira, então roda uma vez só, no fim.
    $retention = $null
    if (-not $SkipRetention -and $null -ne $lastContext) {
        try { $retention = Remove-ExpiredSnapshot -Context $lastContext }
        catch { Write-InventoryLog -Level WARN -Message "Retenção não executada: $($_.Exception.Message)" }
    }

    $stopwatch.Stop()
    Write-InventoryLog -Message (
        'Execução {0} concluída em {1:N1} s, {2} ambiente(s), exit code {3}.' -f
        $RunType, ($stopwatch.ElapsedMilliseconds / 1000), $runs.Count, $exitCode
    )

    return [pscustomobject]@{
        ExitCode  = $exitCode
        Runs      = $runs.ToArray()
        Retention = $retention
    }
}

#endregion

Export-ModuleMember -Function @(
    'Import-PISdk',
    'Get-InventoryEnvironment',
    'Initialize-PIConnection',
    'Write-InventoryLog',
    'Write-InventoryOutput',
    'ConvertFrom-AFConfigString',
    'Get-InventoryDatasetMap',
    'Write-InventoryManifest',
    'Copy-InventorySnapshot',
    'Remove-ExpiredSnapshot',
    'Invoke-InventorySnapshot',
    'Export-PIPointInventory',
    'Export-PIPointHealth',
    'Export-PIDigitalSetInventory',
    'Export-AFElementInventory',
    'Export-AFAttributeInventory',
    'Export-AFTemplateInventory',
    'Export-AFEventFrameInventory',
    'Export-AFAnalysisInventory',
    'Export-AFAnalysisOutputInventory',
    'Export-AFEnumerationSetInventory',
    'Export-AFUomInventory',
    'Export-AFTableInventory'
)
