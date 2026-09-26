<#
.SYNOPSIS
    Warm-up step 4 (P3): replay the recording A/A - the legacy application against itself.

.DESCRIPTION
    `sk replay` sends every recorded scenario to the "legacy" and the "candidate" side,
    each restarted before each scenario (Reset-EShop.ps1, the command reset in
    warmup/eshop/secondkey.yaml). Both sides are the same IIS site: with no candidate yet,
    an A/A run is what shows that the chain itself adds no difference - every exchange
    should come out equal, and the contract should hold on both sides.

    Anti-forgery tokens are issued per form; the replay carries the fresh one from the page
    it just loaded into the form it posts (the correlation rule in secondkey.yaml).

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER Capture
    Default: the capture recorded by step 3 (state\eshop-traffic.json).

.PARAMETER Out
    Default: <WorkRoot>\eshop\run.skrun.

.EXAMPLE
    .\scripts\eshop\4-replay-eshop.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Capture,
    [string] $Out
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'NopBench.Common.ps1')
. (Join-Path $libDir 'NopBench.Chain.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$deploy = Read-BenchState -WorkRoot $work -Name 'eshop-deploy'
if (-not $deploy) { throw 'No state\eshop-deploy.json: run scripts\eshop\2-deploy-eshop.ps1 first.' }
if (-not $Capture) {
    $traffic = Read-BenchState -WorkRoot $work -Name 'eshop-traffic'
    if (-not $traffic) { throw 'No state\eshop-traffic.json: run scripts\eshop\3-record-eshop.ps1 first, or pass -Capture.' }
    $Capture = $traffic.capture
}
$Capture = Get-BenchFullPath $Capture
if ($Out) { $Out = Get-BenchFullPath $Out } else { $Out = Join-Path (Join-Path $work 'eshop') 'run.skrun' }
$sk = Resolve-BenchChainTool -WorkRoot $work -Name 'secondkey'
$config = Join-Path $repoRoot 'warmup\eshop\secondkey.yaml'
$url = $deploy.url.TrimEnd('/')

Enter-BenchGroup ('sk replay: A/A against {0}' -f $url)
$watch = [System.Diagnostics.Stopwatch]::StartNew()
Push-Location $repoRoot
try {
    $null = Invoke-BenchChainTool -Tool $sk -Arguments @('replay', '--config', $config, '--capture', $Capture, '--out', $Out, '--legacy', $url, '--candidate', $url)
}
finally {
    Pop-Location
}
$seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
Exit-BenchGroup

Enter-BenchGroup 'sk validate'
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $Out)
Exit-BenchGroup

# What the run holds, read back from the file itself.
$results = 0; $errors = 0; $resets = 0; $failedResets = 0; $scenarios = @{}
foreach ($line in [System.IO.File]::ReadAllLines($Out)) {
    if ($line -match '^\{"type":"exchange\.result"') {
        $results++
        if ($line -match '"error":\{') { $errors++ }
    }
    elseif ($line -match '^\{"type":"state\.reset".*"scenario":"([^"]+)"') {
        $resets++
        $scenarios[$Matches[1]] = $true
        if ($line -match '"outcome":"failed"') { $failedResets++ }
    }
}
Write-BenchLog ('Run: {0} scenarios, {1} results ({2} without an answer), {3} resets ({4} failed), {5} s' -f $scenarios.Count, $results, $errors, $resets, $failedResets, $seconds)
if ($errors -gt 0 -or $failedResets -gt 0) { throw 'The replay has results without an answer or failed resets; it is not a fair comparison.' }

Write-BenchState -WorkRoot $work -Name 'eshop-replay' -Data ([ordered]@{
        run = $Out
        runSha256 = (Get-BenchSha256 $Out)
        capture = $Capture
        legacy = $url
        candidate = $url
        scenarios = $scenarios.Count
        results = $results
        resets = $resets
        seconds = $seconds
        replayedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

Add-BenchSummary -Lines @(
    '### Warm-up: A/A replay',
    '',
    ('{0} scenarios replayed on both sides ({1} results, {2} resets by application restart) in {3} s; legacy and candidate are both {4}.' -f $scenarios.Count, $results, $resets, $seconds, $url),
    ''
)

exit 0
