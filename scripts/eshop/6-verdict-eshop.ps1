<#
.SYNOPSIS
    Warm-up step 6 (P3): compare, gate and assemble the evidence pack - file in, file out.

.DESCRIPTION
    Runs anywhere the chain's tools run (CI runs it on Linux, docs/TOPOLOGY.md): only
    files go in - the run from step 4, the SARIF from step 5 and the contract in
    warmup/eshop/ - and only files come out.

      1. sk validate    the contract, the run and the SARIF's companions;
      2. sk compare     the run against the contract into verdict.json. The warm-up is an
                        A/A run, so the outcome must be pass, with every accepted clause held
                        and none unexercised; anything else fails this step - after the pack
                        is written, so the pack explains the failure;
      3. sk gate        the SARIF, per rule (exit 1 means an error would block a change);
      4. sk evidence    the pack: report, PDF when a browser is present, verdict, contract,
                        run, SARIF, manifest and in-toto statement - then every file is
                        checked against the manifest's SHA-256.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench. Inputs default to <WorkRoot>\eshop\.

.PARAMETER Pdf
    auto (default), required or off - passed to sk evidence --pdf.

.EXAMPLE
    pwsh scripts/eshop/6-verdict-eshop.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Run,
    [string] $Sarif,
    [string] $OutDir,
    [ValidateSet('auto', 'required', 'off')][string] $Pdf = 'auto'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'NopBench.Common.ps1')
. (Join-Path $libDir 'NopBench.Chain.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$eshopDir = Join-Path $work 'eshop'
if ($Run) { $Run = Get-BenchFullPath $Run } else { $Run = Join-Path $eshopDir 'run.skrun' }
if ($Sarif) { $Sarif = Get-BenchFullPath $Sarif } else { $Sarif = Join-Path $eshopDir 'portcullis.sarif' }
if ($OutDir) { $OutDir = Get-BenchFullPath $OutDir } else { $OutDir = $eshopDir }
$contract = Join-Path (Join-Path (Join-Path $repoRoot 'warmup') 'eshop') 'contract.yaml'
$verdictPath = Join-Path $OutDir 'verdict.json'
$packDir = Join-Path $OutDir 'evidence'
foreach ($path in @($Run, $Sarif, $contract)) { if (-not (Test-Path -LiteralPath $path)) { throw ("Missing input: {0}" -f $path) } }
$sk = Resolve-BenchChainTool -WorkRoot $work -Name 'secondkey'

Enter-BenchGroup 'sk validate: contract and run'
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $contract, $Run)
Exit-BenchGroup

Enter-BenchGroup 'sk compare'
$compareCode = Invoke-BenchChainTool -Tool $sk -Arguments @('compare', '--contract', $contract, '--run', $Run, '--out', $verdictPath) -SuccessExitCodes @(0, 1, 2)
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $verdictPath)
Exit-BenchGroup

Enter-BenchGroup 'sk gate'
$gateCode = Invoke-BenchChainTool -Tool $sk -Arguments @('gate', '--sarif', $Sarif) -SuccessExitCodes @(0, 1)
Exit-BenchGroup

Enter-BenchGroup ('sk evidence (PDF: {0})' -f $Pdf)
# sk evidence refuses a directory holding anything but an earlier pack; start clean.
if (Test-Path -LiteralPath $packDir) { Remove-Item -LiteralPath $packDir -Recurse -Force }
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('evidence', '--verdict', $verdictPath, '--contract', $contract, '--run', $Run, '--sarif', $Sarif, '--out', $packDir, '--pdf', $Pdf)
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

# --- What the verdict says --------------------------------------------------------------
$verdict = Get-Content -LiteralPath $verdictPath -Raw | ConvertFrom-Json
$s = $verdict.summary
$accepted = @($verdict.clauses | Where-Object { $_.accepted })
$notHeld = @($accepted | Where-Object { $_.status -ne 'held' })
$gate = @('pass', 'fail (an error would block a change)')[$gateCode]
Write-BenchLog ('Verdict: {0}; {1} exchanges in {2} scenarios: {3} equal, {4} equal under contract, {5} regressions, {6} fix candidates' -f $verdict.outcome, $s.exchanges, $s.scenarios, $s.equal, $s.equalUnderContract, $s.regression, $s.fixCandidate)
Write-BenchLog ('Clauses: {0} accepted, {1} exercised, {2} unexercised, absence share {3}' -f $s.clauses.accepted, $s.clauses.exercised, $s.clauses.unexercised, $s.clauses.absenceShare)
foreach ($clause in $notHeld) { Write-BenchLog ('  NOT HELD: {0} ({1})' -f $clause.id, $clause.status) }

Write-BenchState -WorkRoot $work -Name 'eshop-verdict' -Data ([ordered]@{
        outcome = $verdict.outcome
        compareExitCode = $compareCode
        gate = $gate
        gateExitCode = $gateCode
        summary = $s
        clausesNotHeld = @($notHeld | ForEach-Object { '{0}: {1}' -f $_.id, $_.status })
        pack = $packDir
        packFiles = $packFiles
        decidedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$summary = @(
    '### Warm-up: verdict, gate and evidence pack',
    '',
    '| | |',
    '|---|---|',
    ('| Behaviour (A/A) | **{0}**: {1} exchanges in {2} scenarios - {3} equal, {4} equal under contract, {5} regressions, {6} fix candidates |' -f $verdict.outcome, $s.exchanges, $s.scenarios, $s.equal, $s.equalUnderContract, $s.regression, $s.fixCandidate),
    ('| Contract | {0} clauses, {1} accepted: {2} held of {1}, {3} unexercised; absence share {4:P0} |' -f $s.clauses.total, $s.clauses.accepted, ($accepted.Count - $notHeld.Count), $s.clauses.unexercised, [double] $s.clauses.absenceShare),
    ('| Gate (Portcullis SARIF) | {0} |' -f $gate),
    ('| Evidence pack | {0} files + manifest.json, digests verified (artifact `eshop-evidence-pack`) |' -f $packFiles.Count),
    ''
)
Add-BenchSummary -Lines $summary

if ($verdict.outcome -ne 'pass' -or $notHeld.Count -gt 0 -or $s.clauses.unexercised -gt 0) {
    throw ('The A/A verdict must pass with every accepted clause held: outcome {0}, {1} clause(s) not held. The pack at {2} explains it.' -f $verdict.outcome, $notHeld.Count, $packDir)
}
exit 0
