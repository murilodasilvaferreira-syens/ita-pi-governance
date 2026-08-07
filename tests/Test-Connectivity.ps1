#Requires -Version 5.1

<#
    .SYNOPSIS
        Valida ambiente, conectividade e caminhos de saída antes de qualquer coleta.

    .DESCRIPTION
        Executa verificações independentes e resume o resultado. Nenhuma escrita no PI System.

        Verificações críticas quebram o pipeline; avisos merecem atenção mas não impedem a coleta.
        O caso mais traiçoeiro que este script cobre é o drive de rede mapeado: ele funciona na
        sessão interativa e desaparece na sessão unattended do PAD.

    .PARAMETER ConfigPath
        Caminho do settings.json. Padrão: <repo>\config\settings.json.

    .PARAMETER SkipSample
        Pula a leitura de amostra de atributos com Data Reference.

    .OUTPUTS
        Tabela de verificações. Exit code: 0 tudo certo, 1 falha crítica, 2 apenas avisos.

    .EXAMPLE
        .\tests\Test-Connectivity.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $SkipSample
)

$ErrorActionPreference = 'Continue'
$script:Checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'WARN', 'FAIL')][string] $Status,
        [string] $Detail
    )

    $script:Checks.Add([pscustomobject]@{
            Check  = $Name
            Status = $Status
            Detail = $Detail
        }) | Out-Null

    $color = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } }
    Write-Host ('  {0,-4} {1,-34} {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}

function Get-PathDriveInfo {
    param([string] $Path)

    $result = [pscustomobject]@{ Kind = 'Desconhecido'; Detail = $Path }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $result }

    $root = $null
    try { $root = [System.IO.Path]::GetPathRoot($Path) } catch { return $result }
    if ([string]::IsNullOrWhiteSpace($root)) { return $result }

    if ($root.StartsWith('\\')) {
        $result.Kind = 'UNC'
        $result.Detail = $root
        return $result
    }

    $deviceId = $root.Substring(0, 2)
    $disk = $null
    try { $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$deviceId'" -ErrorAction Stop } catch { }

    if ($null -eq $disk) {
        $result.Kind = 'Inexistente'
        $result.Detail = $deviceId
        return $result
    }

    $result.Kind = switch ([int]$disk.DriveType) {
        2 { 'Removivel' }
        3 { 'Local' }
        4 { 'Rede' }
        5 { 'Optico' }
        default { 'Outro' }
    }
    $result.Detail = if ($disk.ProviderName) { "$deviceId -> $($disk.ProviderName)" } else { $deviceId }
    return $result
}

function Test-WritablePath {
    param([string] $Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $probe = Join-Path $Path ('.connectivity_probe_{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $probe -Value 'probe' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

Write-Host ''
Write-Host 'Test-Connectivity — ita-pi-governance' -ForegroundColor Cyan
Write-Host ('Executando como {0}\{1} em {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
Write-Host ''

# ---------------------------------------------------------------- ambiente local

if ($PSVersionTable.PSVersion -ge [version]'5.1') {
    Add-Check -Name 'Versão do PowerShell' -Status 'OK' -Detail $PSVersionTable.PSVersion.ToString()
}
else {
    Add-Check -Name 'Versão do PowerShell' -Status 'FAIL' -Detail "$($PSVersionTable.PSVersion) — requer 5.1 ou superior"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config\settings.json' }

$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $config = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json
        Add-Check -Name 'Arquivo de configuração' -Status 'OK' -Detail $ConfigPath
    }
    catch {
        Add-Check -Name 'Arquivo de configuração' -Status 'FAIL' -Detail "JSON inválido: $($_.Exception.Message)"
    }
}
else {
    Add-Check -Name 'Arquivo de configuração' -Status 'FAIL' -Detail "Não encontrado: $ConfigPath"
}

$localOverride = Join-Path (Split-Path -Parent $ConfigPath) 'settings.local.json'
if (Test-Path -LiteralPath $localOverride) {
    Add-Check -Name 'Override local' -Status 'WARN' -Detail "settings.local.json em uso — valores diferem do repositório"
}

# ---------------------------------------------------------------- caminhos de saída

if ($config) {
    $candidates = @(
        @{ Label = 'Diretório de saída principal'; Path = $config.output.baseDir; Primary = $true },
        @{ Label = 'Diretório de saída fallback'; Path = $config.output.fallbackBaseDir; Primary = $false }
    )

    $anyWritable = $false
    foreach ($candidate in $candidates) {
        $path = [string]$candidate.Path
        $drive = Get-PathDriveInfo -Path $path
        $exists = Test-Path -LiteralPath $path

        if (-not $exists) {
            try {
                New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
                $exists = $true
            }
            catch { }
        }

        $writable = $exists -and (Test-WritablePath -Path $path)
        if ($writable) { $anyWritable = $true }

        $detail = '{0} [{1}] {2}' -f $path, $drive.Kind, $(if ($writable) { 'gravável' } else { 'não gravável' })

        if ($writable -and $drive.Kind -eq 'Rede') {
            Add-Check -Name $candidate.Label -Status 'WARN' -Detail "$detail — drive de rede mapeado NÃO existe em sessão unattended do PAD; use caminho UNC ou local"
        }
        elseif ($writable) {
            Add-Check -Name $candidate.Label -Status 'OK' -Detail $detail
        }
        elseif ($candidate.Primary) {
            Add-Check -Name $candidate.Label -Status 'WARN' -Detail "$detail — o módulo cairá para o fallback com WARN"
        }
        else {
            Add-Check -Name $candidate.Label -Status 'FAIL' -Detail $detail
        }
    }

    if (-not $anyWritable) {
        Add-Check -Name 'Saída local' -Status 'FAIL' -Detail 'Nenhum diretório de saída gravável'
    }

    if ($config.transfer.enabled) {
        $oneDrive = [string]$config.transfer.oneDrivePath
        $driveInfo = Get-PathDriveInfo -Path $oneDrive
        if (Test-WritablePath -Path $oneDrive) {
            Add-Check -Name 'Pasta OneDrive/SharePoint' -Status 'OK' -Detail "$oneDrive [$($driveInfo.Kind)]"
        }
        elseif (Test-Path -LiteralPath $oneDrive) {
            Add-Check -Name 'Pasta OneDrive/SharePoint' -Status 'FAIL' -Detail "$oneDrive existe mas não é gravável"
        }
        else {
            Add-Check -Name 'Pasta OneDrive/SharePoint' -Status 'FAIL' -Detail "$oneDrive não encontrada — se o PAD rodar com outra conta, o perfil de usuário será diferente"
        }
    }
}

# ---------------------------------------------------------------- módulo e SDK

$modulePath = Join-Path $repoRoot 'src\PIInventory.psd1'
$moduleLoaded = $false
try {
    Import-Module $modulePath -Force -ErrorAction Stop
    $moduleLoaded = $true
    Add-Check -Name 'Módulo PIInventory' -Status 'OK' -Detail (Get-Module PIInventory).Version.ToString()
}
catch {
    Add-Check -Name 'Módulo PIInventory' -Status 'FAIL' -Detail $_.Exception.Message
}

if ($moduleLoaded) {
    try {
        $sdkPaths = if ($config) { @($config.pi.afSdkAssemblyPath) } else { @() }
        $sdk = if ($sdkPaths.Count -gt 0) { Import-PISdk -AssemblyPath $sdkPaths } else { Import-PISdk }
        Add-Check -Name 'AF SDK' -Status 'OK' -Detail ('{0} via {1}' -f $sdk.version, $sdk.method)
    }
    catch {
        Add-Check -Name 'AF SDK' -Status 'FAIL' -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------- conectividade

$context = $null
if ($moduleLoaded -and $config) {
    try {
        $context = Initialize-PIConnection -ConfigPath $ConfigPath -RunType 'metadata'
        Add-Check -Name 'Initialize-PIConnection' -Status 'OK' -Detail "log em $($context.LogFile)"
    }
    catch {
        Add-Check -Name 'Initialize-PIConnection' -Status 'FAIL' -Detail $_.Exception.Message
    }
}

if ($context) {
    $pi = $context.PIServer
    $expectedDa = [string]$config.pi.dataArchive
    if ($pi.Name -eq $expectedDa) {
        Add-Check -Name 'PI Data Archive' -Status 'OK' -Detail ('{0} v{1} (conectado: {2})' -f $pi.Name, $pi.ServerVersion, $pi.ConnectionInfo.IsConnected)
    }
    else {
        Add-Check -Name 'PI Data Archive' -Status 'FAIL' -Detail "Conectado em '$($pi.Name)', esperado '$expectedDa'"
    }

    $af = $context.PISystem
    $expectedAf = [string]$config.pi.afServer
    if ($af.Name -eq $expectedAf) {
        Add-Check -Name 'PI AF Server' -Status 'OK' -Detail ('{0} v{1}' -f $af.Name, $af.ServerVersion)
    }
    else {
        Add-Check -Name 'PI AF Server' -Status 'FAIL' -Detail "Conectado em '$($af.Name)', esperado '$expectedAf'"
    }

    # O Default PI System desta máquina aponta para um servidor antigo. Ver armadilha 6.
    try {
        $default = (New-Object OSIsoft.AF.PISystems).DefaultPISystem
        if ($null -ne $default -and $default.Name -ne $expectedAf) {
            Add-Check -Name 'Default PI System' -Status 'WARN' -Detail "Aponta para '$($default.Name)' — por isso o código nunca usa DefaultPISystem"
        }
    }
    catch { }

    $db = $context.AFDatabase
    Add-Check -Name 'AF Database' -Status 'OK' -Detail ('{0} ({1} elementos raiz)' -f $db.Name, $db.Elements.Count)

    try {
        $rootNames = @($db.Elements | ForEach-Object { $_.Name })
        Add-Check -Name 'Elementos raiz' -Status 'OK' -Detail ($rootNames -join ', ')
    }
    catch {
        Add-Check -Name 'Elementos raiz' -Status 'FAIL' -Detail $_.Exception.Message
    }

    try {
        $filter = [string]$config.pi.pointNameFilter
        if ([string]::IsNullOrWhiteSpace($filter)) { $filter = '*' }
        $points = @([OSIsoft.AF.PI.PIPoint]::FindPIPoints($pi, $filter))
        $status = if ($points.Count -gt 0) { 'OK' } else { 'FAIL' }
        Add-Check -Name 'Leitura de PI Points' -Status $status -Detail ("$($points.Count) tags com filtro '$filter'")
    }
    catch {
        Add-Check -Name 'Leitura de PI Points' -Status 'FAIL' -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------- amostra de ConfigString

if ($context -and -not $SkipSample) {
    try {
        $samples = New-Object System.Collections.Generic.List[object]
        $queue = New-Object System.Collections.Queue
        foreach ($element in $db.Elements) { $queue.Enqueue($element) }

        $visited = 0
        while ($queue.Count -gt 0 -and $samples.Count -lt 5 -and $visited -lt 300) {
            $element = $queue.Dequeue()
            $visited++

            foreach ($attribute in $element.Attributes) {
                if ($samples.Count -ge 5) { break }
                $dr = $null
                try { $dr = $attribute.DataReferencePlugIn.Name } catch { }
                if ($dr -notmatch '^\s*PI\s*Point\s*$') { continue }

                $configString = $null
                try { $configString = [string]$attribute.ConfigString } catch { }
                if ([string]::IsNullOrWhiteSpace($configString)) { continue }

                $parsed = ConvertFrom-AFConfigString -ConfigString $configString -DataReference $dr
                $samples.Add([pscustomobject]@{
                        Attribute    = $attribute.GetPath()
                        ConfigString = $configString
                        ResolvedTag  = $parsed.resolved_tag
                        ParseStatus  = $parsed.parse_status
                    }) | Out-Null
            }

            foreach ($child in $element.Elements) { $queue.Enqueue($child) }
        }

        if ($samples.Count -eq 0) {
            Add-Check -Name 'Amostra de ConfigString' -Status 'WARN' -Detail "Nenhum atributo com DR 'PI Point' nos primeiros $visited elementos"
        }
        else {
            $resolved = @($samples | Where-Object { $_.ParseStatus -eq 'resolved' }).Count
            $status = if ($resolved -eq $samples.Count) { 'OK' } else { 'WARN' }
            Add-Check -Name 'Amostra de ConfigString' -Status $status -Detail "$resolved de $($samples.Count) resolvidos"

            Write-Host ''
            Write-Host '  Amostra AF -> PI:' -ForegroundColor Cyan
            $samples | Format-Table ParseStatus, ResolvedTag, ConfigString -AutoSize | Out-String | Write-Host
        }
    }
    catch {
        Add-Check -Name 'Amostra de ConfigString' -Status 'WARN' -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------- resumo

$failures = @($script:Checks | Where-Object { $_.Status -eq 'FAIL' })
$warnings = @($script:Checks | Where-Object { $_.Status -eq 'WARN' })

Write-Host ''
Write-Host ('Resumo: {0} verificações, {1} falhas, {2} avisos' -f $script:Checks.Count, $failures.Count, $warnings.Count) -ForegroundColor Cyan

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Falhas críticas:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host ("  - {0}: {1}" -f $_.Check, $_.Detail) -ForegroundColor Red }
    Write-Host ''
    exit 1
}

if ($warnings.Count -gt 0) {
    Write-Host ''
    exit 2
}

Write-Host ''
exit 0
