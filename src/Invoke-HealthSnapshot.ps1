#Requires -Version 5.1

<#
    .SYNOPSIS
        Coleta intradiária de estado (health) dos PI Points.

    .DESCRIPTION
        Ponto de entrada do Power Automate Desktop para a coleta de estado, que muda o tempo todo e
        roda de 2 a 4 vezes por dia.

        READ-ONLY: nenhuma escrita no PI System. Ver README.md.

        Várias execuções por dia gravam na mesma pasta datada; o timestamp no nome de cada arquivo,
        manifesto e registro de transferência mantém os runs separados.

        Exit codes lidos pelo PAD:
          0  tudo certo — pode disparar o fluxo do Power Automate cloud
          1  falha fatal, nenhum dado produzido
          2  parcial ou degradado, há dados mas algo merece atenção

    .PARAMETER ConfigPath
        Caminho do settings.json. Padrão: <repo>\config\settings.json.

    .PARAMETER Environment
        Restringe a coleta aos ambientes indicados. Padrão: todos os habilitados em `environments`.

    .PARAMETER Dataset
        Sobrescreve a lista de datasets de `datasets.health`.

    .PARAMETER SkipTransfer
        Não copia para o OneDrive.

    .PARAMETER SkipRetention
        Não executa a purga de snapshots vencidos.

    .EXAMPLE
        .\src\Invoke-HealthSnapshot.ps1
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

$arguments = @{ RunType = 'health' }
if ($ConfigPath) { $arguments['ConfigPath'] = $ConfigPath }
if ($Environment) { $arguments['Environment'] = $Environment }
if ($Dataset) { $arguments['Dataset'] = $Dataset }
if ($SkipTransfer) { $arguments['SkipTransfer'] = $true }
if ($SkipRetention) { $arguments['SkipRetention'] = $true }

$result = Invoke-InventorySnapshot @arguments

foreach ($run in $result.Runs) {
    Write-Host ''
    Write-Host ("=== ambiente: {0} | exit {1} ===" -f $run.Environment, $run.ExitCode) -ForegroundColor Cyan

    if ($null -eq $run.Context) {
        Write-Host ("    FALHA: {0}" -f $run.Error) -ForegroundColor Red
        continue
    }

    $run.Context.Datasets |
        Format-Table dataset, status, row_count, duration_ms, file -AutoSize |
        Out-String -Width 170 |
        Write-Host

    $health = $run.Context.Datasets | Where-Object { $_.dataset -eq 'pipoint_health' }
    if ($null -ne $health -and $null -ne $health.metrics) {
        Write-Host ("    stale={0}  bad={1}  sem_dados={2}  (limite {3} h)" -f
            $health.metrics['stale_count'], $health.metrics['bad_count'],
            $health.metrics['never_fed_count'], $health.metrics['stale_threshold_hours'])
    }
}

Write-Host ("RESULTADO: {0} ambiente(s) | exit {1}" -f $result.Runs.Count, $result.ExitCode) -ForegroundColor Cyan

exit $result.ExitCode
