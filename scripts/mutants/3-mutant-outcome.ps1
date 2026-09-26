<#
.SYNOPSIS
    P9 mutants, step 3: killed or survived - one mutant's outcome, read from the verdict of
    its replay against the legacy shop.

.DESCRIPTION
    After the traffic set was replayed with the legacy shop on one side and the mutant on the
    other (8-replay.ps1 -Candidate) and compared against the contract (9-verdict.ps1), this
    step reads replay\verdict.json and applies the rule docs/P9-MUTANTS.md registered before
    any mutant ran:

      killed    sk compare's outcome is fail: at least one exchange is a regression - a
                clause that held on legacy did not hold on the mutant, a difference nothing
                in the contract explains, or an answer missing;
      survived  any other outcome (pass, or review: fix candidates only).

    It records what caught the mutant beside what the catalog expected to: the clauses whose
    status is "regressed", and the regressed exchanges by the reason sk gave - a clause, an
    uncovered difference, a missing answer (sk classifies an exchange by the first of these
    that applies) - with the scenario each belongs to. The record goes to state\mutant.json
    and the job summary.

    M00, the calibration, must come out pass: anything else is a difference between the two
    sites that is not code, and no mutant result of the run counts. The step then fails, after
    writing its record.

    Runs anywhere (Windows or Linux), file in, file out: it reads replay\verdict.json,
    state\replay.json, state\traffic.json and state\mutant-deploy.json from the work root.

.PARAMETER Id
    The mutant, as mutants\mutants.json names it.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench ($HOME/nopbench off Windows).

.PARAMETER RunUrl
    The workflow run the outcome belongs to. Default: built from GITHUB_SERVER_URL,
    GITHUB_REPOSITORY and GITHUB_RUN_ID when they are set.

.EXAMPLE
    pwsh scripts/mutants/3-mutant-outcome.ps1 -Id M01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^M[0-9]{2}$')][string] $Id,
    [string] $WorkRoot,
    [string] $RunUrl
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $scriptsRoot 'lib') 'NopBench.Common.ps1')

$repoRoot = Split-Path -Parent $scriptsRoot
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
if (-not $RunUrl -and $env:GITHUB_RUN_ID) { $RunUrl = '{0}/{1}/actions/runs/{2}' -f $env:GITHUB_SERVER_URL, $env:GITHUB_REPOSITORY, $env:GITHUB_RUN_ID }
$verdictPath = Join-Path (Join-Path $work 'replay') 'verdict.json'
if (-not (Test-Path -LiteralPath $verdictPath)) { throw ('No verdict at {0}: run scripts/9-verdict.ps1 first.' -f $verdictPath) }

$catalog = Get-Content -LiteralPath (Join-Path (Join-Path $repoRoot 'mutants') 'mutants.json') -Raw | ConvertFrom-Json
$entry = @($catalog.mutants | Where-Object { $_.id -eq $Id })
if ($entry.Count -ne 1) { throw ('mutants\mutants.json has no mutant {0}.' -f $Id) }
$entry = $entry[0]
$intended = @($entry.intendedClauses | Where-Object { $_ } | ForEach-Object { [string] $_ })

# The replay must be the legacy shop against this mutant.
$replay = Read-BenchState -WorkRoot $work -Name 'replay'
if (-not $replay -or $replay.mode -ne 'legacy vs candidate') { throw 'state\replay.json does not describe a replay of legacy against a candidate (8-replay.ps1 -Candidate).' }
$deployed = Read-BenchState -WorkRoot $work -Name 'mutant-deploy'
if (-not $deployed) { throw 'No state\mutant-deploy.json: the replay is not known to be of a mutant.' }
if ($deployed.id -ne $Id) { throw ('The replay is of {0}, not {1}.' -f $deployed.id, $Id) }
if ($replay.candidate.TrimEnd('/') -ne $deployed.url.TrimEnd('/')) { throw ('The replay''s candidate is {0}, but {1} was deployed at {2}.' -f $replay.candidate, $Id, $deployed.url) }

# Scenario names: the verdict names a scenario by its session id (state\traffic.json maps them).
$scenarioNames = @{}
$traffic = Read-BenchState -WorkRoot $work -Name 'traffic'
if ($traffic) { foreach ($row in @($traffic.scenarioList)) { $scenarioNames[[string] $row.session] = [string] $row.id } }

$verdict = ConvertFrom-Json (Get-Content -LiteralPath $verdictPath -Raw)
$summaryCounts = $verdict.summary
$regressionExchanges = @($verdict.exchanges | Where-Object { $_.class -eq 'regression' })
$byClause = @($regressionExchanges | Where-Object { @($_.reasons | Where-Object { "$_" -like 'clause-regression:*' }).Count -gt 0 })
$uncovered = @($regressionExchanges | Where-Object { @($_.reasons) -contains 'uncovered-difference' })
$missing = @($regressionExchanges | Where-Object { @($_.reasons | Where-Object { "$_" -like 'missing-result:*' }).Count -gt 0 })
# An answer missing on the mutant's side is the mutant's doing; one missing on the legacy
# side means the replay itself did not work, and the verdict is not about the mutant.
$legacyMissing = @($missing | Where-Object { @($_.reasons | Where-Object { "$_" -like 'missing-result: legacy*' }).Count -gt 0 })
if ($legacyMissing.Count -gt 0) {
    throw ('{0} exchange(s) have no legacy answer ({1}): the replay did not work, and the verdict decides nothing about {2}.' -f $legacyMissing.Count, (@($legacyMissing | Select-Object -First 5 | ForEach-Object { '{0} {1}' -f $_.request.method, $_.request.path }) -join ', '), $Id)
}
$regressedClauses = @($verdict.clauses | Where-Object { $_.accepted -and $_.status -eq 'regressed' } | ForEach-Object { [string] $_.id })
# What became of each clause the catalog expected to catch the mutant: regressed, held,
# violated-both, fixed or unexercised, as the verdict's clause summary says.
$intendedStatus = [ordered]@{}
foreach ($clause in $intended) {
    $found = @($verdict.clauses | Where-Object { $_.id -eq $clause })
    if ($found.Count -eq 1) { $intendedStatus[$clause] = [string] $found[0].status } else { $intendedStatus[$clause] = 'not in the verdict' }
}
$outcome = 'survived'
if ($verdict.outcome -eq 'fail') { $outcome = 'killed' }
# The calibration is neither: it is the method's own check, and it passes or it does not.
if ($Id -eq 'M00') { $outcome = 'calibration {0}' -f $verdict.outcome }

$exchangeRows = @($regressionExchanges | ForEach-Object {
        $scenario = [string] $_.scenario
        if ($scenarioNames.ContainsKey($scenario)) { $scenario = $scenarioNames[$scenario] }
        $query = ''
        if ($_.request.PSObject.Properties.Name -contains 'query' -and $_.request.query) { $query = [string] $_.request.query }
        [ordered]@{
            exchange = [string] $_.exchange
            scenario = $scenario
            request = ('{0} {1}{2}' -f $_.request.method, $_.request.path, $query)
            reasons = @($_.reasons | ForEach-Object { [string] $_ })
            differences = @($_.diffs | Where-Object { -not ($_.PSObject.Properties.Name -contains 'normalizedBy' -and $_.normalizedBy) } | ForEach-Object { [string] $_.path })
        }
    })

$patchName = $null
if ($entry.patch) { $patchName = [string] $entry.patch }
$record = [ordered]@{
    id = $Id
    title = [string] $entry.title
    patch = $patchName
    intendedClauses = $intended
    outcome = $outcome
    verdictOutcome = [string] $verdict.outcome
    regressions = [int] $summaryCounts.regression
    regressedClauses = $regressedClauses
    uncoveredDifferences = $uncovered.Count
    intendedClausesRegressed = @($intended | Where-Object { $regressedClauses -contains $_ })
    intendedClauseStatus = $intendedStatus
    otherRegressedClauses = @($regressedClauses | Where-Object { $intended -notcontains $_ })
    regressionsByClause = $byClause.Count
    missingAnswers = $missing.Count
    fixCandidates = [int] $summaryCounts.fixCandidate
    exchanges = [int] $summaryCounts.exchanges
    scenarios = [int] $summaryCounts.scenarios
    regressedExchanges = $exchangeRows
    verdictSha256 = (Get-BenchSha256 $verdictPath)
    runSha256 = [string] $verdict.inputs.run.sha256
    contractSha256 = [string] $verdict.inputs.contract.sha256
    runUrl = $RunUrl
    decidedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
Write-BenchState -WorkRoot $work -Name 'mutant' -Data $record

function Format-ClauseList {
    param([object[]] $Clauses)
    $list = @($Clauses | Where-Object { $_ })
    if ($list.Count -eq 0) { return 'none' }
    return (($list | ForEach-Object { '`{0}`' -f $_ }) -join ', ')
}

$headline = '{0}: {1}' -f $Id, $outcome.ToUpperInvariant()
if ($Id -eq 'M00') { $headline = 'M00 (calibration): {0}' -f $verdict.outcome }
$lines = @(
    ('### {0}' -f $headline),
    '',
    '| | |',
    '|---|---|',
    ('| Mutant | {0}: {1} (`{2}`) |' -f $Id, $entry.title, $(if ($patchName) { $patchName } else { 'no patch' })),
    ('| Verdict | **{0}**: {1} exchanges in {2} scenarios, {3} regressions - {4} by a clause, {5} uncovered differences, {6} missing answers - and {7} fix candidates |' -f $verdict.outcome, $summaryCounts.exchanges, $summaryCounts.scenarios, $summaryCounts.regression, $byClause.Count, $uncovered.Count, $missing.Count, $summaryCounts.fixCandidate),
    ('| Expected to catch it | {0} |' -f $(if ($intended.Count -gt 0) { (($intended | ForEach-Object { '`{0}`: {1}' -f $_, $intendedStatus[$_] }) -join ', ') } else { 'nothing: it must pass' })),
    ('| Other clauses that regressed | {0} |' -f (Format-ClauseList $record.otherRegressedClauses))
)
foreach ($row in ($exchangeRows | Select-Object -First 15)) {
    $lines += ('| {0} `{1}` | {2} |' -f $row.scenario, $row.request, (@($row.reasons) -join '; '))
}
if ($exchangeRows.Count -gt 15) { $lines += ('| ... | {0} more regressed exchanges in `state/mutant.json` |' -f ($exchangeRows.Count - 15)) }
$lines += ''
Add-BenchSummary -Lines $lines
Write-BenchLog ('{0}: {1} (verdict {2}; {3} regressions: {4} by a clause, {5} uncovered differences, {6} missing answers). Regressed clauses: {7}' -f $Id, $outcome, $verdict.outcome, $summaryCounts.regression, $byClause.Count, $uncovered.Count, $missing.Count, (Format-ClauseList $regressedClauses))

if ($Id -eq 'M00' -and $verdict.outcome -ne 'pass') {
    throw ('M00, the calibration, came out {0}, not pass: the second site differs from the legacy site for a reason that is not code, and no mutant result of this run counts. replay\verdict.json and the pack name the differences.' -f $verdict.outcome)
}
exit 0
