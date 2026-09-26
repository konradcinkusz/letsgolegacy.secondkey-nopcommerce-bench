<#
.SYNOPSIS
    Runbook step 8 (P5): replay the traffic set with `sk replay` - A/A by default, the
    legacy shop against itself.

.DESCRIPTION
    Sends every scenario of the recording (step 7) to the "legacy" and the "candidate"
    side, each first restored to the snapshot step 7 recorded from (the sqlServerSnapshot
    reset in contract/secondkey.yaml), each scenario with a fresh cookie jar. The
    anti-forgery token of each form is carried from the page that issued it into the
    request that posts it (the correlation rule in contract/secondkey.yaml).

    With no candidate yet (P5), both sides are the legacy shop: an A/A run shows that the
    chain adds no difference of its own and that the contract holds on the legacy system.
    P7 passes the candidate's URL.

    sk reads the connection string for the reset from NOPBENCH_SK_SQL, which this step
    sets for its own process from the SQL Server instance in state\deploy.json (Windows
    authentication: the string holds no secret).

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER Capture
    Default: the recording of step 7 (state\traffic.json).

.PARAMETER Candidate
    The candidate's base URL. Default: the legacy shop itself (A/A).

.PARAMETER Out
    Default: <WorkRoot>\replay\run.skrun.

.EXAMPLE
    .\scripts\8-replay.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Capture,
    [string] $Candidate,
    [string] $Out
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Chain.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$deploy = Read-BenchState -WorkRoot $work -Name 'deploy'
if (-not $deploy) { throw 'No state\deploy.json: run scripts\4-deploy-and-install.ps1 first.' }
$traffic = Read-BenchState -WorkRoot $work -Name 'traffic'
if (-not $Capture) {
    if (-not $traffic) { throw 'No state\traffic.json: run scripts\7-record-traffic.ps1 first, or pass -Capture.' }
    if ($traffic.partial) { throw 'state\traffic.json names a partial recording (-Only): record the whole set first.' }
    $Capture = $traffic.capture
}
$Capture = Get-BenchFullPath $Capture
if ($Out) { $Out = Get-BenchFullPath $Out } else { $Out = Join-Path (Join-Path $work 'replay') 'run.skrun' }
$outDir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir }
$legacy = $deploy.url.TrimEnd('/')
if ($Candidate) { $Candidate = $Candidate.TrimEnd('/') } else { $Candidate = $legacy }
$mode = 'A/A'
if ($Candidate -ne $legacy) { $mode = 'legacy vs candidate' }
$sk = Resolve-BenchChainTool -WorkRoot $work -Name 'secondkey'
$config = Join-Path (Join-Path $repoRoot 'contract') 'secondkey.yaml'

# The reset's connection string, for sk's process only. Windows authentication: no secret.
$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$builder['Data Source'] = $deploy.sqlServer
$builder['Integrated Security'] = $true
$env:NOPBENCH_SK_SQL = $builder.ConnectionString + ';Encrypt=False'

Enter-BenchGroup ('sk replay ({0}): legacy {1}, candidate {2}' -f $mode, $legacy, $Candidate)
$watch = [System.Diagnostics.Stopwatch]::StartNew()
Push-Location $repoRoot
try {
    $null = Invoke-BenchChainTool -Tool $sk -Arguments @('replay', '--config', $config, '--capture', $Capture, '--out', $Out, '--legacy', $legacy, '--candidate', $Candidate)
}
finally {
    Pop-Location
    Remove-Item Env:\NOPBENCH_SK_SQL -ErrorAction SilentlyContinue
}
$seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
Exit-BenchGroup

Enter-BenchGroup 'sk validate'
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $Out)
Exit-BenchGroup

# What the run holds, read back from the file itself.
$results = 0; $errors = 0; $resets = 0; $failedResets = 0; $resetMs = 0.0
$scenarios = @{}
$statuses = @{}
foreach ($line in [System.IO.File]::ReadAllLines($Out)) {
    if ($line -match '^\{\s*"type"\s*:\s*"exchange\.result"') {
        $results++
        if ($line -match '"error"\s*:\s*\{') { $errors++ }
        $status = [regex]::Match($line, '"response"\s*:\s*\{\s*"status"\s*:\s*([0-9]+)').Groups[1].Value
        if ($status) { $statuses[$status] = 1 + [int] $statuses[$status] }
    }
    elseif ($line -match '^\{\s*"type"\s*:\s*"state\.reset"') {
        $resets++
        $scenarios[[regex]::Match($line, '"scenario"\s*:\s*"([^"]+)"').Groups[1].Value] = $true
        if ($line -match '"outcome"\s*:\s*"failed"') {
            $failedResets++
            Write-Host ('::error::Reset failed: {0}' -f [regex]::Match($line, '"detail"\s*:\s*"((?:[^"\\]|\\.)*)"').Groups[1].Value)
        }
        $ms = [regex]::Match($line, '"durationMs"\s*:\s*([0-9.]+)').Groups[1].Value
        if ($ms) { $resetMs += [double]::Parse($ms, [System.Globalization.CultureInfo]::InvariantCulture) }
    }
}
$statusText = (@($statuses.Keys | Sort-Object | ForEach-Object { '{0} x{1}' -f $_, $statuses[$_] }) -join ', ')
Write-BenchLog ('Run: {0} scenarios, {1} results ({2} without an answer; statuses {3}), {4} resets ({5} failed, {6:N0} ms on average), {7} s' -f $scenarios.Count, $results, $errors, $statusText, $resets, $failedResets, ($resetMs / [math]::Max(1, $resets)), $seconds)
if ($errors -gt 0 -or $failedResets -gt 0) { throw 'The replay has results without an answer or failed resets; it is not a fair comparison.' }
if ($traffic -and -not $PSBoundParameters.ContainsKey('Capture') -and $scenarios.Count -ne $traffic.scenarios) { throw ('The run holds {0} scenarios; the recording has {1}.' -f $scenarios.Count, $traffic.scenarios) }

Write-BenchState -WorkRoot $work -Name 'replay' -Data ([ordered]@{
        run = $Out
        runSha256 = (Get-BenchSha256 $Out)
        capture = $Capture
        mode = $mode
        legacy = $legacy
        candidate = $Candidate
        scenarios = $scenarios.Count
        results = $results
        statuses = $statusText
        resets = $resets
        seconds = $seconds
        replayedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$snapshotName = 'nopcommerce_legacy_snapshot'
if ($traffic) { $snapshotName = $traffic.snapshot }
Add-BenchSummary -Lines @(
    ('### Replay ({0})' -f $mode),
    '',
    ('{0} scenarios replayed on both sides: {1} results ({2}), {3} resets from snapshot `{4}`, in {5} s. Legacy {6}, candidate {7}.' -f $scenarios.Count, $results, $statusText, $resets, $snapshotName, $seconds, $legacy, $Candidate),
    ''
)
exit 0
