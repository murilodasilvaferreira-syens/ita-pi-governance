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

    .PARAMETER Dataset
        Sobrescreve a lista de datasets de `datasets.metadata`.

    .PARAMETER SkipTransfer
        Não copia para o OneDrive.

    .PARAMETER SkipRetention
        Não executa a purga de snapshots vencidos.

    .EXAMPLE
        .\src\Invoke-MetadataSnapshot.ps1

    .EXAMPLE
        .\src\Invoke-MetadataSnapshot.ps1 -Dataset attributes -SkipTransfer
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
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
if ($Dataset) { $arguments['Dataset'] = $Dataset }
if ($SkipTransfer) { $arguments['SkipTransfer'] = $true }
if ($SkipRetention) { $arguments['SkipRetention'] = $true }

$result = Invoke-InventorySnapshot @arguments

if ($null -ne $result.Context) {
    Write-Host ''
    $result.Context.Datasets |
        Format-Table dataset, status, row_count, duration_ms, file -AutoSize |
        Out-String -Width 160 |
        Write-Host
}

$statusText = if ($null -ne $result.Manifest) { $result.Manifest.status } else { 'fatal' }
Write-Host ("RESULTADO: {0} | exit {1}" -f $statusText, $result.ExitCode) -ForegroundColor Cyan

exit $result.ExitCode
