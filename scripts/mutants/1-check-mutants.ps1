<#
.SYNOPSIS
    P9 mutants, step 1: check the mutant catalog, and every patch against the pinned tree;
    write the matrix the mutants workflow runs.

.DESCRIPTION
    mutants\mutants.json is the pre-registered mutant set (docs/P9-MUTANTS.md). Before any
    mutant is built, this step checks:

      1. the catalog: ids M00 to M99, each once; M00, the calibration, has no patch and
         expects no clause; every other mutant names its patch, the file and member the patch
         changes, what it changes, why it is a plausible defect, and at least one clause
         expected to catch it;
      2. every clause the catalog names is a clause of contract\contract.yaml, and every
         mutants\*.patch belongs to a mutant;
      3. with -SourceDir, a checkout from step 1: the checkout is the clean pinned tree, and
         every patch applies to it, changes exactly the file its mutant names, and comes out
         again, leaving the tree clean.

    In GitHub Actions it writes the matrix - one entry per mutant: its id and patch - to
    GITHUB_OUTPUT as "matrix", and the catalog to the job summary. Runs on Windows and Linux,
    Windows PowerShell 5.1 and PowerShell 7; only -SourceDir needs git.

.PARAMETER SourceDir
    A checkout of the pinned nopCommerce (scripts\1-fetch-nopcommerce.ps1) to check every
    patch against. Default: none - the patches are then not applied.

.EXAMPLE
    pwsh scripts/mutants/1-check-mutants.ps1 -SourceDir $HOME/nopbench/legacy-src
#>
[CmdletBinding()]
param(
    [string] $SourceDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $scriptsRoot 'lib') 'NopBench.Common.ps1')

$repoRoot = Split-Path -Parent $scriptsRoot
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$mutantsDir = Join-Path $repoRoot 'mutants'
$catalogPath = Join-Path $mutantsDir 'mutants.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$problems = New-Object System.Collections.Generic.List[string]

# The clause ids of the contract: "  - id: SOME-CLAUSE" lines under clauses.
$contractPath = Join-Path (Join-Path $repoRoot 'contract') 'contract.yaml'
$clauseIds = @{}
foreach ($line in (Get-Content -LiteralPath $contractPath)) {
    $match = [regex]::Match($line, '^\s*-\s+id:\s*([A-Z0-9][A-Z0-9-]*)\s*$')
    if ($match.Success) { $clauseIds[$match.Groups[1].Value] = $true }
}
if ($clauseIds.Count -eq 0) { throw ('No clause ids found in {0}.' -f $contractPath) }

function Get-Field {
    # A catalog field of one mutant; $null when the mutant does not have it.
    param($Mutant, [string] $Name)
    if ($Mutant.PSObject.Properties.Name -contains $Name) { return $Mutant.$Name }
    return $null
}

# --- 1 and 2. The catalog -------------------------------------------------------------
Enter-BenchGroup ('Catalog {0}' -f $catalogPath)
if ((Get-Field $catalog 'nopCommerce') -and $catalog.nopCommerce.commit -ne $pins.nopCommerce.commit) {
    $problems.Add(('The catalog is written against nopCommerce {0}, but pins.json pins {1}.' -f $catalog.nopCommerce.commit, $pins.nopCommerce.commit))
}
$mutants = @($catalog.mutants)
if ($mutants.Count -eq 0) { throw 'The catalog lists no mutant.' }
$seen = @{}
$patches = @{}
foreach ($mutant in $mutants) {
    $id = [string] (Get-Field $mutant 'id')
    if ($id -notmatch '^M[0-9]{2}$') { $problems.Add(('Mutant id "{0}" is not M00 to M99.' -f $id)); continue }
    if ($seen.ContainsKey($id)) { $problems.Add(('{0} is listed twice.' -f $id)) }
    $seen[$id] = $true
    $patch = Get-Field $mutant 'patch'
    $clauses = @(Get-Field $mutant 'intendedClauses' | Where-Object { $_ })
    foreach ($name in @('title', 'change', 'intent')) {
        if (-not [string] (Get-Field $mutant $name)) { $problems.Add(('{0} has no {1}.' -f $id, $name)) }
    }
    if ($id -eq 'M00') {
        if ($patch) { $problems.Add('M00, the calibration, must have no patch.') }
        if ($clauses.Count -gt 0) { $problems.Add('M00, the calibration, must expect no clause to fail.') }
        continue
    }
    if (-not $patch) { $problems.Add(('{0} has no patch.' -f $id)); continue }
    if ($patch -notmatch ('^{0}-[a-z0-9-]+\.patch$' -f $id)) { $problems.Add(('{0}: patch "{1}" is not named {0}-<what-it-does>.patch.' -f $id, $patch)) }
    if (-not (Test-Path -LiteralPath (Join-Path $mutantsDir $patch) -PathType Leaf)) { $problems.Add(('{0}: mutants\{1} does not exist.' -f $id, $patch)) }
    $patches[[string] $patch] = $id
    foreach ($name in @('file', 'member')) {
        if (-not [string] (Get-Field $mutant $name)) { $problems.Add(('{0} has no {1}.' -f $id, $name)) }
    }
    if ($clauses.Count -eq 0) { $problems.Add(('{0} names no clause expected to catch it.' -f $id)) }
    foreach ($clause in $clauses) {
        if (-not $clauseIds.ContainsKey([string] $clause)) { $problems.Add(('{0}: {1} is not a clause of contract\contract.yaml.' -f $id, $clause)) }
    }
}
if (-not $seen.ContainsKey('M00')) { $problems.Add('The catalog has no M00, the calibration mutant.') }
foreach ($file in @(Get-ChildItem -LiteralPath $mutantsDir -Filter '*.patch' -File)) {
    if (-not $patches.ContainsKey($file.Name)) { $problems.Add(('mutants\{0} belongs to no mutant of the catalog.' -f $file.Name)) }
}
Write-BenchLog ('{0} mutants, {1} patches, {2} contract clauses known.' -f $mutants.Count, $patches.Count, $clauseIds.Count)
Exit-BenchGroup

# --- 3. Every patch against the pinned tree -----------------------------------------------
$checked = 0
if ($SourceDir) {
    $SourceDir = Get-BenchFullPath $SourceDir
    Enter-BenchGroup ('Every patch against {0} at {1}' -f $pins.nopCommerce.tag, $pins.nopCommerce.commit)
    if (-not (Test-BenchPinnedCheckout -Directory $SourceDir -Commit $pins.nopCommerce.commit)) {
        throw ('{0} is not a clean checkout of {1}. Run scripts/1-fetch-nopcommerce.ps1 first.' -f $SourceDir, $pins.nopCommerce.commit)
    }
    foreach ($mutant in $mutants) {
        $patch = Get-Field $mutant 'patch'
        if (-not $patch) { continue }
        $patchPath = Join-Path $mutantsDir $patch
        if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) { continue }
        try {
            $files = Add-BenchPatch -SourceDir $SourceDir -Patch $patchPath
            $expectedFile = [string] (Get-Field $mutant 'file')
            if (($files -join ', ') -cne $expectedFile) { $problems.Add(('{0}: the patch changes {1}; the catalog says {2}.' -f $mutant.id, ($files -join ', '), $expectedFile)) }
            Undo-BenchPatch -SourceDir $SourceDir -Files $files
            Write-BenchLog ('{0}: {1} applies and comes out again ({2}).' -f $mutant.id, $patch, ($files -join ', '))
            $checked++
        }
        catch {
            $problems.Add(('{0}: {1}' -f $mutant.id, $_.Exception.Message))
            $left = Get-BenchModifiedFile -SourceDir $SourceDir
            if ($left.Count -gt 0) { Undo-BenchPatch -SourceDir $SourceDir -Files $left }
        }
        if (-not (Test-BenchPinnedCheckout -Directory $SourceDir -Commit $pins.nopCommerce.commit)) {
            throw ('The checkout did not come back clean after {0}.' -f $patch)
        }
    }
    Exit-BenchGroup
}

# --- Results ------------------------------------------------------------------------------
$summary = @(
    '### Mutant catalog (P9, pre-registered)',
    '',
    ('{0} mutants in `mutants/mutants.json`; patches checked against the pinned tree: {1}.' -f $mutants.Count, $(if ($SourceDir) { '{0} of {1}' -f $checked, $patches.Count } else { 'not asked for' })),
    '',
    '| Mutant | Patch | Changes | Clauses expected to catch it |',
    '|---|---|---|---|'
)
foreach ($mutant in $mutants) {
    $patch = Get-Field $mutant 'patch'
    if (-not $patch) { $patch = 'none (calibration)' }
    $where = [string] (Get-Field $mutant 'member')
    if (-not $where) { $where = '-' }
    $clauses = @(Get-Field $mutant 'intendedClauses' | Where-Object { $_ })
    $expected = '- (must pass)'
    if ($clauses.Count -gt 0) { $expected = ($clauses | ForEach-Object { '`{0}`' -f $_ }) -join ', ' }
    $summary += ('| {0} | `{1}` | `{2}` | {3} |' -f (Get-Field $mutant 'id'), $patch, $where, $expected)
}
$summary += ''
Add-BenchSummary -Lines $summary

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host ('::error::{0}' -f $_) }
    throw ('{0} problem(s) with the mutant catalog.' -f $problems.Count)
}

$matrix = [ordered]@{ include = @($mutants | ForEach-Object { $p = Get-Field $_ 'patch'; if (-not $p) { $p = '' }; [ordered]@{ id = [string] $_.id; patch = [string] $p } }) }
$json = ConvertTo-Json -InputObject $matrix -Compress -Depth 5
Write-BenchLog ('Matrix: {0}' -f $json)
if ($env:GITHUB_OUTPUT) {
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, ('matrix={0}' -f $json) + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
exit 0
