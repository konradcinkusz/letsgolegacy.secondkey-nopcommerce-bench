<#
.SYNOPSIS
    Warm-up step 5 (P3): run the gate's analyzers (Portcullis) on eShopLegacyMVC's source,
    as SARIF 2.1.0 for `sk gate` and the evidence pack.

.DESCRIPTION
    Portcullis (pinned in pins.json, chain.portcullis) analyses the C# source with its
    migration rules: System.Web, HttpContext.Current, blocking on tasks, ConfigurationManager.
    There is no migration pull request in the warm-up, so this is a whole-tree scan of the
    legacy application: its findings are the .NET Framework idioms a migration would have
    to remove, and the errors among them are what the gate would block if they were a
    change. Portcullis exits 1 when its own gate blocks; that is a result here, not a
    failure of the step.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench. The source comes from step 1.

.PARAMETER Out
    Default: <WorkRoot>\eshop\portcullis.sarif.

.EXAMPLE
    .\scripts\eshop\5-scan-eshop.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Out
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'NopBench.Common.ps1')
. (Join-Path $libDir 'NopBench.Chain.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$sourceDir = Join-Path $work 'eshop-src'
if (-not (Test-BenchPinnedCheckout -Directory $sourceDir -Commit $pins.eShopModernizing.commit)) {
    throw ('{0} is not a clean checkout of the pinned eShopModernizing. Run scripts\eshop\1-build-eshop.ps1 first.' -f $sourceDir)
}
$projectDir = Join-BenchPath -Base $sourceDir -Relative $pins.eShopModernizing.sourceDirectory
if ($Out) { $Out = Get-BenchFullPath $Out } else { $Out = Join-Path (Join-Path $work 'eshop') 'portcullis.sarif' }
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out)
$report = [System.IO.Path]::ChangeExtension($Out, '.json')
$portcullis = Resolve-BenchChainTool -WorkRoot $work -Name 'portcullis'

Enter-BenchGroup ('Portcullis scan of {0}' -f $projectDir)
Write-BenchLog ('> dotnet {0} scan {1} --provenance-repo {2} --sarif {3}' -f $portcullis, $projectDir, $sourceDir, $Out)
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # stdout is the scan's JSON report: kept as a file rather than poured into the log.
    $json = & dotnet $portcullis scan $projectDir --provenance-repo $sourceDir --sarif $Out
    $code = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previous
}
[System.IO.File]::WriteAllText($report, (($json | ForEach-Object { "$_" }) -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
if (@(0, 1) -notcontains $code) { throw ('Portcullis exited with code {0}.' -f $code) }
if (-not (Test-Path -LiteralPath $Out)) { throw ('Portcullis wrote no SARIF at {0}.' -f $Out) }
$sarif = Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json
if ($sarif.version -ne '2.1.0') { throw ('{0} is SARIF {1}, not 2.1.0.' -f $Out, $sarif.version) }
$results = @($sarif.runs[0].results)
$byRule = $results | Group-Object -Property ruleId | Sort-Object -Property Name
foreach ($rule in $byRule) {
    $levels = ($rule.Group | Group-Object -Property level | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', '
    Write-BenchLog ('  {0}: {1}' -f $rule.Name, $levels)
}
$errorCount = @($results | Where-Object { $_.level -eq 'error' }).Count
Write-BenchLog ('{0} findings, {1} of them errors; Portcullis exit code {2} ({3}).' -f $results.Count, $errorCount, $code, @('gate passes', 'gate blocks')[$code])
Exit-BenchGroup

Write-BenchState -WorkRoot $work -Name 'eshop-scan' -Data ([ordered]@{
        sarif = $Out
        report = $report
        scanned = $projectDir
        portcullis = $pins.chain.portcullis.commit
        findings = $results.Count
        errors = $errorCount
        exitCode = $code
        scannedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$summary = @('### Warm-up: gate analyzers (Portcullis)', '', ('Whole-tree scan of the legacy source: {0} findings, {1} errors.' -f $results.Count, $errorCount), '', '| Rule | Findings |', '|---|---|')
foreach ($rule in $byRule) { $summary += ('| `{0}` | {1} |' -f $rule.Name, $rule.Count) }
$summary += ''
Add-BenchSummary -Lines $summary

exit 0
