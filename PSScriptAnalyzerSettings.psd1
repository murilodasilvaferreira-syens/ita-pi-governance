@{
    # Regras conscientemente desabilitadas neste repositório.
    ExcludeRules = @(
        # A saída de console é o que o Power Automate Desktop captura em execução unattended;
        # Write-Verbose e Write-Information não aparecem no log do fluxo.
        'PSAvoidUsingWriteHost',

        # `catch { }` em volta de leitura de propriedade do AF é a estratégia de resiliência do
        # módulo, não descuido: propriedade ausente num objeto específico precisa deixar o campo
        # vazio, nunca derrubar a linha inteira nem poluir o log com milhares de entradas.
        # Falhas que importam são capturadas no catch externo de cada Export-* e viram
        # status 'failed' no manifesto.
        'PSAvoidUsingEmptyCatchBlock',

        # Os scripts em src/ e tests/ são pontos de entrada, não módulos reutilizáveis.
        'PSUseShouldProcessForStateChangingFunctions',

        # Nenhuma credencial trafega neste repositório: a autenticação é integrada do Windows.
        'PSAvoidUsingPlainTextForPassword',
        'PSUsePSCredentialType'
    )

    Rules        = @{
        PSPlaceOpenBrace           = @{
            Enable     = $true
            OnSameLine = $true
        }
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
        }
    }
}
