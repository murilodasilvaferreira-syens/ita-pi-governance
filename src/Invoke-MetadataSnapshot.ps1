#Requires -Version 5.1

<#
    .SYNOPSIS
        Coleta diária de metadados do PI System (estrutura).

    .DESCRIPTION
        Ponto de entrada do Power Automate Desktop para a coleta de estrutura, que muda pouco e
        roda uma vez por dia.

        READ-ONLY: nenhuma escrita no PI System. Ver README.md.

        Exit codes lidos pelo PAD:
          0  tudo certo — pode disparar o fluxo do Power Automate cloud
          1  falha fatal, nenhum dado produzido
          2  parcial ou degradado, há dados mas algo merece atenção

    .PARAMETER ConfigPath
        Caminho do settings.json. Padrão: <repo>\config\settings.json.

    .PARAMETER Environment
        Restringe a coleta aos ambientes indicados. Padrão: todos os habilitados em `environments`.

    .PARAMETER Dataset
        Sobrescreve a lista de datasets de `datasets.metadata`.

    .PARAMETER SkipTransfer
        Não copia para o OneDrive.

    .PARAMETER SkipRetention
        Não executa a purga de snapshots vencidos.

    .EXAMPLE
        .\src\Invoke-MetadataSnapshot.ps1

    .EXAMPLE
        .\src\Invoke-MetadataSnapshot.ps1 -Environment itatiba-legado -Dataset attributes -SkipTransfer
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string[]] $Environment,
    [string[]] $Dataset,
    [switch] $SkipTransfer,
    [switch] $SkipRetention
)

$ErrorActionPreference = 'Continue'

try {
    Import-Module (Join-Path $PSScriptRoot 'PIInventory.psd1') -Force -ErrorAction Stop
}
catch {
    Write-Host "FATAL: não foi possível carregar o módulo PIInventory: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$arguments = @{ RunType = 'metadata' }
if ($ConfigPath) { $arguments['ConfigPath'] = $ConfigPath }
if ($Environment) { $arguments['Environment'] = $Environment }
if ($Dataset) { $arguments['Dataset'] = $Dataset }
if ($SkipTransfer) { $arguments['SkipTransfer'] = $true }
if ($SkipRetention) { $arguments['SkipRetention'] = $true }

$result = Invoke-InventorySnapshot @arguments

foreach ($run in $result.Runs) {
    Write-Host ''
    Write-Host ("=== ambiente: {0} | exit {1} ===" -f $run.Environment, $run.ExitCode) -ForegroundColor Cyan
    if ($null -ne $run.Context) {
        $run.Context.Datasets |
            Format-Table dataset, status, row_count, duration_ms, file -AutoSize |
            Out-String -Width 170 |
            Write-Host
    }
    else {
        Write-Host ("    FALHA: {0}" -f $run.Error) -ForegroundColor Red
    }
}

Write-Host ("RESULTADO: {0} ambiente(s) | exit {1}" -f $result.Runs.Count, $result.ExitCode) -ForegroundColor Cyan

exit $result.ExitCode
