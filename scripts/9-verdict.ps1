<#
.SYNOPSIS
    Runbook step 9 (P5): the contract's verdict on the replay, and the evidence pack -
    file in, file out.

.DESCRIPTION
    Runs anywhere the chain's tools run (CI runs it on Linux, docs/TOPOLOGY.md): the run
    from step 8 and contract/contract.yaml go in; verdict.json and the pack come out.

      1. sk validate    the contract and the run;
      2. sk compare     the run against the contract into verdict.json;
      3. sk evidence    the pack: report, PDF when a browser is present, verdict, contract,
                        run, manifest and in-toto statement - every file then checked
                        against the manifest's SHA-256.

    For an A/A run (state\replay.json, mode A/A) the outcome must be pass, with every
    accepted clause held and none unexercised: the legacy system against itself has no
    behaviour to disagree about, so anything else is a defect in the contract or the
    replay. Anything short of that fails this step - after the pack is written, so the pack
    explains the failure - and the log names each clause that did not hold, the requests
    it failed on and the text of the legacy answer.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER Run
    Default: <WorkRoot>\replay\run.skrun.

.PARAMETER OutDir
    Default: <WorkRoot>\replay.

.PARAMETER Pdf
    auto (default), required or off - passed to sk evidence --pdf.

.EXAMPLE
    pwsh scripts/9-verdict.ps1 -Pdf required
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Run,
    [string] $OutDir,
    [ValidateSet('auto', 'required', 'off')][string] $Pdf = 'auto'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Chain.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$replayDir = Join-Path $work 'replay'
if ($Run) { $Run = Get-BenchFullPath $Run } else { $Run = Join-Path $replayDir 'run.skrun' }
if ($OutDir) { $OutDir = Get-BenchFullPath $OutDir } else { $OutDir = $replayDir }
$contract = Join-Path (Join-Path $repoRoot 'contract') 'contract.yaml'
$verdictPath = Join-Path $OutDir 'verdict.json'
$packDir = Join-Path $OutDir 'evidence'
foreach ($path in @($Run, $contract)) { if (-not (Test-Path -LiteralPath $path)) { throw ('Missing input: {0}' -f $path) } }
$replay = Read-BenchState -WorkRoot $work -Name 'replay'
$mode = 'A/A'
if ($replay) { $mode = $replay.mode }
$sk = Resolve-BenchChainTool -WorkRoot $work -Name 'secondkey'

Enter-BenchGroup 'sk validate: contract and run'
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $contract, $Run)
Exit-BenchGroup

Enter-BenchGroup 'sk compare'
$compareCode = Invoke-BenchChainTool -Tool $sk -Arguments @('compare', '--contract', $contract, '--run', $Run, '--out', $verdictPath) -SuccessExitCodes @(0, 1, 2)
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $verdictPath)
Exit-BenchGroup

Enter-BenchGroup ('sk evidence (PDF: {0})' -f $Pdf)
# sk evidence refuses a directory holding anything but an earlier pack; start clean.
if (Test-Path -LiteralPath $packDir) { Remove-Item -LiteralPath $packDir -Recurse -Force }
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('evidence', '--verdict', $verdictPath, '--contract', $contract, '--run', $Run, '--out', $packDir, '--pdf', $Pdf)
$manifest = Get-Content -LiteralPath (Join-Path $packDir 'manifest.json') -Raw | ConvertFrom-Json
foreach ($file in $manifest.files) {
    $actual = Get-BenchSha256 (Join-Path $packDir $file.path)
    if ($actual -ne $file.sha256) { throw ('{0} does not match its SHA-256 in the manifest.' -f $file.path) }
}
$packFiles = @($manifest.files | ForEach-Object { $_.path })
foreach ($required in @('index.html', 'verdict.json', 'contract.yaml', 'run.skrun', 'statement.intoto.json')) {
    if ($packFiles -notcontains $required) { throw ('The pack has no {0}.' -f $required) }
}
Write-BenchLog ('Pack: {0} files + manifest.json, every digest verified: {1}' -f $packFiles.Count, ($packFiles -join ', '))
Exit-BenchGroup

function Format-BenchDifference {
    # One raw difference of the verdict, readable in a log. Two long strings - an HTML section
    # inside a JSON answer - are shown as the lines that differ, each side's own; anything
    # else as JSON. A workflow annotation is cut at 4 KB, so the detail goes to the log.
    param([Parameter(Mandatory = $true)] $Difference)
    $names = $Difference.PSObject.Properties.Name
    $legacy = $null; $candidate = $null
    if ($names -contains 'legacy') { $legacy = $Difference.legacy }
    if ($names -contains 'candidate') { $candidate = $Difference.candidate }
    if ($legacy -is [string] -and $candidate -is [string] -and ($legacy.Length -gt 300 -or $candidate.Length -gt 300)) {
        $left = @($legacy -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $right = @($candidate -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($left.Count -gt 0 -and $right.Count -gt 0) {
            $changes = @(Compare-Object -ReferenceObject $left -DifferenceObject $right)
            $shown = @($changes | Select-Object -First 10 | ForEach-Object {
                    $side = 'candidate'
                    if ($_.SideIndicator -eq '<=') { $side = 'legacy   ' }
                    $text = [string] $_.InputObject
                    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
                    '  {0} {1}' -f $side, $text
                })
            return @(('{0}: {1} line(s) differ' -f $Difference.path, $changes.Count)) + $shown
        }
    }
    $show = {
        param($Value)
        $text = ConvertTo-Json -InputObject $Value -Compress -Depth 5
        if ($text.Length -gt 600) { $text = $text.Substring(0, 600) + '...' }
        $text
    }
    return @(('{0}: {1} -> {2}' -f $Difference.path, (& $show $legacy), (& $show $candidate)))
}

# --- What the verdict says --------------------------------------------------------------
$verdict = ConvertFrom-Json (Get-Content -LiteralPath $verdictPath -Raw)
$s = $verdict.summary
$accepted = @($verdict.clauses | Where-Object { $_.accepted })
$notHeld = @($accepted | Where-Object { $_.status -ne 'held' })
$never = @($accepted | Where-Object { $_.kind -eq 'never' })
Write-BenchLog ('Verdict: {0}; {1} exchanges in {2} scenarios: {3} equal, {4} equal under contract, {5} regressions, {6} fix candidates' -f $verdict.outcome, $s.exchanges, $s.scenarios, $s.equal, $s.equalUnderContract, $s.regression, $s.fixCandidate)
Write-BenchLog ('Clauses: {0} accepted ({1} never), {2} exercised, {3} unexercised, absence share {4}' -f $s.clauses.accepted, $never.Count, $s.clauses.exercised, $s.clauses.unexercised, $s.clauses.absenceShare)
# What made the exchanges that are not identical count as equal: each normalization rule of
# the contract, and in how many exchanges it accounted for a difference.
$explained = @{}
foreach ($exchange in @($verdict.exchanges | Where-Object { $_.class -eq 'equal-under-contract' })) {
    $labels = @($exchange.diffs | Where-Object { $_.PSObject.Properties.Name -contains 'normalizedBy' -and $_.normalizedBy } | ForEach-Object { $_.normalizedBy -split ', ' })
    foreach ($label in @($labels | Sort-Object -Unique)) { $explained[$label] = 1 + [int] $explained[$label] }
}
$explainedText = (@($explained.Keys | Sort-Object | ForEach-Object { '{0} x{1}' -f $_, $explained[$_] }) -join ', ')
if (-not $explainedText) { $explainedText = 'nothing to explain' }
Write-BenchLog ('Equal under contract, by rule (exchanges): {0}' -f $explainedText)

# A failed run explains itself in the log: each clause that did not hold, where it failed,
# and what the legacy side answered there; each exchange that is not equal, with its diffs.
if ($notHeld.Count -gt 0 -or $verdict.outcome -ne 'pass') {
    $answers = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Run)) {
        if ($line -notmatch '^\{\s*"type"\s*:\s*"exchange\.result"') { continue }
        $result = ConvertFrom-Json $line
        if ($result.side -ne 'legacy') { continue }
        $text = ''
        if ($result.PSObject.Properties.Name -contains 'response' -and $result.response -and $result.response.PSObject.Properties.Name -contains 'body' -and $result.response.body) {
            $body = $result.response.body
            if ($body.PSObject.Properties.Name -contains 'text' -and $body.text) { $text = $body.text }
            elseif ($body.PSObject.Properties.Name -contains 'json') { $text = ($body.json | ConvertTo-Json -Compress -Depth 20) }
        }
        # From the page's own content on (nopCommerce's layout puts it in master-column-wrapper),
        # past the header and menus every page repeats.
        $content = $text.IndexOf('master-column-wrapper', [System.StringComparison]::Ordinal)
        if ($content -gt 0) { $text = $text.Substring($content) }
        $text = [System.Net.WebUtility]::HtmlDecode(($text -replace '(?is)<(script|style)\b.*?</\1>', ' ' -replace '<[^>]+>', ' ')) -replace '\s+', ' '
        $answers[$result.exchange] = $text
    }
    foreach ($clause in $notHeld) {
        Write-Host ('::error::Clause {0} is {1}: {2}' -f $clause.id, $clause.status, $clause.title)
        $failed = @($verdict.exchanges | Where-Object { @($_.clauses | Where-Object { $_.id -eq $clause.id -and ($_.legacy -ne 'pass' -or $_.candidate -ne 'pass') }).Count -gt 0 })
        foreach ($exchange in ($failed | Select-Object -First 3)) {
            $query = ''
            if ($exchange.request.PSObject.Properties.Name -contains 'query' -and $exchange.request.query) { $query = $exchange.request.query }
            $excerpt = [string] $answers[$exchange.exchange]
            if ($excerpt.Length -gt 2500) { $excerpt = $excerpt.Substring(0, 2500) + '...' }
            Write-BenchLog ('  {0} {1} {2}{3}: {4}' -f $exchange.exchange, $exchange.request.method, $exchange.request.path, $query, $excerpt)
        }
    }
    foreach ($exchange in @($verdict.exchanges | Where-Object { $_.class -eq 'regression' -or $_.class -eq 'fix-candidate' } | Select-Object -First 10)) {
        $diffs = @($exchange.diffs)
        Write-Host ('::error::{0} {1} {2}: {3} ({4}) at {5}' -f $exchange.exchange, $exchange.request.method, $exchange.request.path, $exchange.class, ($exchange.reasons -join ', '), (@($diffs | ForEach-Object { $_.path }) -join ', '))
        foreach ($difference in ($diffs | Select-Object -First 5)) {
            foreach ($line in (Format-BenchDifference -Difference $difference)) { Write-BenchLog ('  {0}' -f $line) }
        }
    }
}

Write-BenchState -WorkRoot $work -Name 'verdict' -Data ([ordered]@{
        mode = $mode
        outcome = $verdict.outcome
        compareExitCode = $compareCode
        summary = $s
        clausesNotHeld = @($notHeld | ForEach-Object { '{0}: {1}' -f $_.id, $_.status })
        normalizedBy = $explainedText
        pack = $packDir
        packFiles = $packFiles
        decidedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$summary = @(
    ('### Contract verdict ({0})' -f $mode),
    '',
    '| | |',
    '|---|---|',
    ('| Behaviour | **{0}**: {1} exchanges in {2} scenarios - {3} equal, {4} equal under contract, {5} regressions, {6} fix candidates |' -f $verdict.outcome, $s.exchanges, $s.scenarios, $s.equal, $s.equalUnderContract, $s.regression, $s.fixCandidate),
    ('| Contract | {0} clauses, {1} accepted ({2} `never`): **{3} held**, {4} not held, {5} unexercised; absence share {6:P0} |' -f $s.clauses.total, $s.clauses.accepted, $never.Count, ($accepted.Count - $notHeld.Count), $notHeld.Count, $s.clauses.unexercised, [double] $s.clauses.absenceShare),
    ('| Normalization | equal under contract, by rule (exchanges): {0} |' -f $explainedText),
    ('| Evidence pack | {0} files + manifest.json, digests verified (artifact `nopcommerce-evidence-pack`) |' -f $packFiles.Count),
    ''
)
Add-BenchSummary -Lines $summary

if ($mode -eq 'A/A' -and ($verdict.outcome -ne 'pass' -or $notHeld.Count -gt 0 -or $s.clauses.unexercised -gt 0)) {
    throw ('The A/A verdict must pass with every accepted clause held and none unexercised: outcome {0}, {1} clause(s) not held, {2} unexercised. The pack at {3} explains it.' -f $verdict.outcome, $notHeld.Count, $s.clauses.unexercised, $packDir)
}
exit 0
