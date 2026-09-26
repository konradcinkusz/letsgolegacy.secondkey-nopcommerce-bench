# PSScriptAnalyzer settings for scripts/. CI runs the same settings (legacy-build.yml, lint
# job):  Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')

    # Write-Host is deliberate: these are interactive runbook scripts whose output is a
    # human-readable log, not pipeline data.
    ExcludeRules = @('PSAvoidUsingWriteHost')

    Rules        = @{
        # The scripts must run on Windows PowerShell 5.1 (what every Windows host has) and
        # on PowerShell 7.
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
                'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core'
            )
        }
    }
}
