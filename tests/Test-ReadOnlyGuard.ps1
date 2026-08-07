#Requires -Version 5.1

<#
    .SYNOPSIS
        Falha se algum arquivo de código contiver chamada de escrita no PI System.

    .DESCRIPTION
        Materializa em verificação executável a regra inviolável do repositório: nada aqui pode
        criar, alterar ou remover PI Point, elemento, atributo, template ou valor.

        O usuário de execução tem identity MES-Admin e pode deletar PI Points — e deletar apaga o
        histórico de forma irreversível. Por isso a regra é verificada, não confiada.

        Escopo: apenas arquivos PowerShell, que são os únicos capazes de alcançar o AF SDK. Os
        notebooks do Fabric operam sobre o Lakehouse e nunca tocam o PI.

        Exclusões deliberadas:
          - este próprio arquivo, que precisa citar os termos para procurá-los
          - README.md e docs/, onde a proibição precisa ser nomeada para ser compreensível

    .PARAMETER Path
        Raiz a varrer. Padrão: raiz do repositório.

    .OUTPUTS
        Lista de violações. Exit code 0 se limpo, 1 se houver qualquer violação.

    .EXAMPLE
        .\tests\Test-ReadOnlyGuard.ps1
#>
[CmdletBinding()]
param(
    [string] $Path
)

$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }

$rules = @(
    @{ Pattern = 'CreatePIPoints?\s*\('; Reason = 'criação de PI Point' }
    @{ Pattern = 'DeletePIPoints?\s*\('; Reason = 'remoção de PI Point (apaga histórico)' }
    @{ Pattern = '\.CheckIn\s*\('; Reason = 'persistência de alterações no AF' }
    @{ Pattern = '\.ApplyChanges\s*\('; Reason = 'persistência de alterações no AF' }
    @{ Pattern = '\.SetValue\s*\('; Reason = 'escrita de valor' }
    @{ Pattern = 'UpdateValues?\s*\('; Reason = 'escrita de valor' }
    @{ Pattern = 'SetAttribute\s*\('; Reason = 'alteração de atributo de PI Point' }
    @{ Pattern = 'SaveAttributes\s*\('; Reason = 'persistência de atributo de PI Point' }
    @{ Pattern = '\.Delete\s*\('; Reason = 'remoção de objeto' }
    @{ Pattern = '\b(New|Set|Remove)-PIPoint\b'; Reason = 'cmdlet de escrita em PI Point' }
    @{ Pattern = '\bAdd-PIValues?\b'; Reason = 'cmdlet de escrita de valor' }
    @{ Pattern = '\b(New|Set|Remove)-AF(Element|Attribute|Database|ElementTemplate|EventFrame|Analysis)\b'; Reason = 'cmdlet de escrita no AF' }
)

$selfPath = $MyInvocation.MyCommand.Path
# -Include é silenciosamente ignorado junto com -LiteralPath, o que faria a varredura pegar
# README.md e docs/, onde os termos proibidos aparecem de propósito.
$files = Get-ChildItem -LiteralPath $Path -Recurse -File |
    Where-Object {
        $_.Extension -in '.ps1', '.psm1', '.psd1' -and
        $_.FullName -ne $selfPath -and
        $_.FullName -notmatch '\\\.git\\'
    }

Write-Host ''
Write-Host 'Test-ReadOnlyGuard — nenhuma escrita no PI System é permitida neste repositório' -ForegroundColor Cyan
Write-Host ("Arquivos analisados: {0}" -f $files.Count)

$violations = New-Object System.Collections.Generic.List[object]

foreach ($file in $files) {
    $lines = Get-Content -LiteralPath $file.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($rule in $rules) {
            if ($lines[$i] -match $rule.Pattern) {
                $violations.Add([pscustomobject]@{
                        File   = $file.FullName.Replace($Path, '').TrimStart('\')
                        Line   = $i + 1
                        Reason = $rule.Reason
                        Code   = $lines[$i].Trim()
                    })
            }
        }
    }
}

Write-Host ''

if ($violations.Count -eq 0) {
    Write-Host 'OK — nenhuma chamada de escrita no PI System encontrada.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("VIOLAÇÃO DA REGRA READ-ONLY: {0} ocorrência(s)" -f $violations.Count) -ForegroundColor Red
Write-Host ''
foreach ($violation in $violations) {
    Write-Host ("  {0}:{1}" -f $violation.File, $violation.Line) -ForegroundColor Red
    Write-Host ("    motivo: {0}" -f $violation.Reason) -ForegroundColor Red
    Write-Host ("    código: {0}" -f $violation.Code)
}
Write-Host ''
Write-Host 'Scripts que escrevem no PI vivem em outro repositório. Ver README.md.' -ForegroundColor Yellow
Write-Host ''
exit 1
