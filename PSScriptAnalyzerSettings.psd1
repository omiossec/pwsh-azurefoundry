@{
    # Default rules plus the formatting rules that enforce the CLAUDE.md code style.
    # The build fails on any finding (Error, Warning or Information).
    Severity     = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true

    Rules        = @{
        PSAvoidLongLines            = @{
            Enable            = $true
            MaximumLineLength = 120
        }
        PSUseConsistentIndentation  = @{
            Enable              = $true
            IndentationSize     = 4
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSPlaceOpenBrace            = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace           = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentWhitespace   = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            CheckOpenBrace                  = $true
            CheckOpenParen                  = $true
            CheckOperator                   = $false   # allow aligned assignments
            CheckPipe                       = $true
            CheckSeparator                  = $true
            CheckParameter                  = $false
        }
        PSUseCompatibleSyntax       = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }
    }
}
