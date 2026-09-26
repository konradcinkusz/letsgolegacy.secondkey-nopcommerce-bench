<#
.SYNOPSIS
    P9 mutants, step 4: every mutant's outcome in one file - "N of M mutants killed" - and
    whether the run counts at all, which the calibration decides.

.DESCRIPTION
    Reads the state\mutant.json that step 3 wrote for each mutant (every mutant.json under
    -InputDir), in the order of mutants\mutants.json, and writes mutants.json: for each mutant
    the clauses it was aimed at, killed or survived, sk compare's outcome, the number of
    regressions, the clauses that regressed, the number of uncovered differences and the
    workflow run - and the headline, which counts the mutants M01 to M99. M00 is the
    calibration and is not counted.

    The file is written in every case, and says what it holds. The step then fails when M00
    did not come out pass - the run's mutant results do not count - or when a mutant of the
    catalog has no outcome, because its job did not get that far.

.PARAMETER InputDir
    Where the mutant.json files are, at any depth (one per mutant).

.PARAMETER Out
    Default: <WorkRoot>\mutants\mutants.json.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench ($HOME/nopbench off Windows).

.PARAMETER RunUrl
    The workflow run. Default: built from GITHUB_SERVER_URL, GITHUB_REPOSITORY and
    GITHUB_RUN_ID when they are set.

.PARAMETER Commit
    The bench commit the run tested. Default: $env:GITHUB_SHA.

.EXAMPLE
    pwsh scripts/mutants/4-collect-mutants.ps1 -InputDir ./outcomes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $InputDir,
    [string] $Out,
    [string] $WorkRoot,
    [string] $RunUrl,
    [string] $Commit
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $scriptsRoot 'lib') 'NopBench.Common.ps1')

$repoRoot = Split-Path -Parent $scriptsRoot
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
if ($Out) { $Out = Get-BenchFullPath $Out } else { $Out = Join-Path (Join-Path $work 'mutants') 'mutants.json' }
if (-not $RunUrl -and $env:GITHUB_RUN_ID) { $RunUrl = '{0}/{1}/actions/runs/{2}' -f $env:GITHUB_SERVER_URL, $env:GITHUB_REPOSITORY, $env:GITHUB_RUN_ID }
if (-not $Commit) { $Commit = $env:GITHUB_SHA }
$catalogPath = Join-Path (Join-Path $repoRoot 'mutants') 'mutants.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

# --- Every outcome, by mutant id ---------------------------------------------------------
$outcomes = @{}
if (Test-Path -LiteralPath $InputDir) {
    foreach ($file in @(Get-ChildItem -LiteralPath $InputDir -Recurse -File -Filter 'mutant.json')) {
        $outcome = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if ($outcomes.ContainsKey([string] $outcome.id)) { throw ('Two outcomes for {0}: {1} and another.' -f $outcome.id, $file.FullName) }
        $outcomes[[string] $outcome.id] = $outcome
        Write-BenchLog ('{0}: {1} (verdict {2}) from {3}' -f $outcome.id, $outcome.outcome, $outcome.verdictOutcome, $file.FullName)
    }
}

$rows = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[string]
foreach ($mutant in @($catalog.mutants)) {
    $id = [string] $mutant.id
    $intended = @($mutant.intendedClauses | Where-Object { $_ } | ForEach-Object { [string] $_ })
    $patch = $null
    if ($mutant.patch) { $patch = [string] $mutant.patch }
    if (-not $outcomes.ContainsKey($id)) {
        $missing.Add($id)
        $rows.Add([ordered]@{ id = $id; title = [string] $mutant.title; patch = $patch; intendedClauses = $intended; outcome = 'no result'; verdictOutcome = $null; regressions = $null; regressedClauses = @(); uncoveredDifferences = $null; runUrl = $RunUrl })
        continue
    }
    $o = $outcomes[$id]
    $rows.Add([ordered]@{
            id = $id
            title = [string] $mutant.title
            patch = $patch
            intendedClauses = $intended
            outcome = [string] $o.outcome
            verdictOutcome = [string] $o.verdictOutcome
            regressions = [int] $o.regressions
            regressedClauses = @($o.regressedClauses | ForEach-Object { [string] $_ })
            uncoveredDifferences = [int] $o.uncoveredDifferences
            intendedClausesRegressed = @($o.intendedClausesRegressed | ForEach-Object { [string] $_ })
            otherRegressedClauses = @($o.otherRegressedClauses | ForEach-Object { [string] $_ })
            missingAnswers = [int] $o.missingAnswers
            fixCandidates = [int] $o.fixCandidates
            runUrl = [string] $o.runUrl
        })
}

$calibration = @($rows | Where-Object { $_.id -eq 'M00' })
$calibrationOutcome = $null
if ($calibration.Count -eq 1) { $calibrationOutcome = $calibration[0].verdictOutcome }
$valid = ($calibrationOutcome -eq 'pass')
$counted = @($rows | Where-Object { $_.id -ne 'M00' })
$killed = @($counted | Where-Object { $_.outcome -eq 'killed' }).Count
$survived = @($counted | Where-Object { $_.outcome -eq 'survived' }).Count
$headline = '{0} of {1} mutants killed' -f $killed, $counted.Count
if (-not $valid) { $headline = 'not counted: M00, the calibration, came out {0}' -f $(if ($calibrationOutcome) { $calibrationOutcome } else { 'without a result' }) }

$document = [ordered]@{
    kind = 'nopbench.p9.mutants'
    v = 1
    headline = $headline
    valid = $valid
    counts = [ordered]@{ mutants = $counted.Count; killed = $killed; survived = $survived; noResult = @($counted | Where-Object { $_.outcome -eq 'no result' }).Count }
    calibration = [ordered]@{ id = 'M00'; verdictOutcome = $calibrationOutcome; passed = $valid }
    run = [ordered]@{ url = $RunUrl; benchCommit = $Commit }
    nopCommerce = [ordered]@{ tag = $pins.nopCommerce.tag; commit = $pins.nopCommerce.commit }
    catalogSha256 = (Get-BenchSha256 $catalogPath)
    mutants = $rows.ToArray()
    collectedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out)
[System.IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject $document -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
Write-BenchLog ('{0}; written to {1}' -f $headline, $Out)

function Format-ClauseList {
    param([object[]] $Items)
    $list = @($Items | Where-Object { $_ })
    if ($list.Count -eq 0) { return '-' }
    return (($list | ForEach-Object { '`{0}`' -f $_ }) -join ', ')
}

$summary = @(
    '### Killed mutants (P9)',
    '',
    ('**{0}.** M00, the calibration (no source change): **{1}**. Run: {2}' -f $headline, $(if ($calibrationOutcome) { $calibrationOutcome } else { 'no result' }), $RunUrl),
    '',
    '| Mutant | Clauses expected to catch it | Outcome | Verdict | Regressions | Clauses that regressed | Uncovered differences |',
    '|---|---|---|---|---|---|---|'
)
foreach ($row in $rows) {
    $expected = Format-ClauseList $row.intendedClauses
    if ($row.id -eq 'M00') { $expected = 'none: it must pass' }
    $summary += ('| {0} {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $row.id, $row.title, $expected, $row.outcome, $row.verdictOutcome, $row.regressions, (Format-ClauseList $row.regressedClauses), $row.uncoveredDifferences)
}
$summary += ''
Add-BenchSummary -Lines $summary

$failures = New-Object System.Collections.Generic.List[string]
if (-not $valid) { $failures.Add(('M00, the calibration, came out {0}: no mutant result of this run counts.' -f $(if ($calibrationOutcome) { $calibrationOutcome } else { 'without a result' }))) }
if ($missing.Count -gt 0) { $failures.Add(('No outcome for {0}: the job did not get that far.' -f ($missing -join ', '))) }
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host ('::error::{0}' -f $_) }
    throw ($failures -join ' ')
}
exit 0
