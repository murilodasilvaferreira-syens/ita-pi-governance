#Requires -Version 5.1

<#
    .SYNOPSIS
        Falha se algum arquivo PowerShell estiver sem BOM UTF-8.

    .DESCRIPTION
        O Windows PowerShell 5.1 lê arquivos sem BOM usando a code page ANSI. Um travessão em
        comentário ou string vira uma aspa tipográfica de fechamento, que o parser aceita como
        delimitador — e blocos inteiros de código somem sem erro, sem exceção e sem nada em $Error.

        Isso já aconteceu neste repositório: Test-Connectivity.ps1 executou 1 de 15 verificações e
        reportou sucesso. Ver armadilha 8 em docs/armadilhas.md.

        Editores e ferramentas de geração de código costumam gravar sem BOM, então a regressão é
        fácil de reintroduzir. Daí a verificação automatizada.

    .PARAMETER Path
        Raiz a varrer. Padrão: raiz do repositório.

    .PARAMETER Fix
        Regrava os arquivos sem BOM adicionando o BOM, preservando o conteúdo.

    .OUTPUTS
        Exit code 0 se todos têm BOM, 1 caso contrário.

    .EXAMPLE
        .\tests\Test-SourceEncoding.ps1

    .EXAMPLE
        .\tests\Test-SourceEncoding.ps1 -Fix
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Path,
    [switch] $Fix
)

$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }

# -Include é silenciosamente ignorado junto com -LiteralPath; filtrar pela extensão é confiável.
$files = Get-ChildItem -LiteralPath $Path -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '\\\.git\\' }

Write-Host ''
Write-Host 'Test-SourceEncoding — PowerShell 5.1 exige BOM UTF-8 em arquivos com acentuação' -ForegroundColor Cyan
Write-Host ("Arquivos analisados: {0}" -f $files.Count)

$missing = New-Object System.Collections.Generic.List[object]

foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom) { $missing.Add($file) }
}

Write-Host ''

if ($missing.Count -eq 0) {
    Write-Host 'OK — todos os arquivos PowerShell têm BOM UTF-8.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("SEM BOM: {0} arquivo(s)" -f $missing.Count) -ForegroundColor Red
foreach ($file in $missing) {
    Write-Host ("  {0}" -f $file.FullName.Replace($Path, '').TrimStart('\')) -ForegroundColor Red
}

if (-not $Fix) {
    Write-Host ''
    Write-Host 'Rode com -Fix para corrigir.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$withBom = New-Object System.Text.UTF8Encoding($true)
$withoutBom = New-Object System.Text.UTF8Encoding($false)

foreach ($file in $missing) {
    if ($PSCmdlet.ShouldProcess($file.FullName, 'Adicionar BOM UTF-8')) {
        $text = [System.IO.File]::ReadAllText($file.FullName, $withoutBom)
        [System.IO.File]::WriteAllText($file.FullName, $text, $withBom)
        Write-Host ("  corrigido: {0}" -f $file.Name) -ForegroundColor Green
    }
}

Write-Host ''
exit 0
