<#
.SYNOPSIS
    Runbook step 1: fetch the pinned nopCommerce release and prove it is the pinned one.

.DESCRIPTION
    nopCommerce is not vendored into this repository. This step downloads the release
    named in pins.json from the upstream repository and verifies it twice:

      1. the upstream tag still points at the pinned commit (a moved tag fails the run);
      2. the checked-out tree is exactly that commit, with no local modification.

    The checkout keeps upstream line endings byte for byte (core.autocrlf=false), so the
    static files the legacy site serves do not depend on the git settings of the machine
    that fetched them.

    An existing checkout that already passes both checks is reused; -Force re-fetches.
    Works on Windows and Linux (only git is required).

.PARAMETER WorkRoot
    Where every step keeps its working files. Default: $env:NOPBENCH_WORK, else
    C:\nopbench on Windows ($HOME/nopbench elsewhere).

.PARAMETER Destination
    Checkout directory. Default: <WorkRoot>\legacy-src.

.PARAMETER Force
    Delete and re-fetch even when a verified checkout is present.

.EXAMPLE
    .\scripts\1-fetch-nopcommerce.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Destination,
    [switch] $Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$nop = $pins.nopCommerce
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
if ($Destination) { $Destination = Get-BenchFullPath $Destination }
else { $Destination = Join-Path $work 'legacy-src' }

Assert-BenchCommand -Name 'git' -Hint 'Install Git for Windows (https://git-scm.com/download/win).'

Enter-BenchGroup ('Verify upstream tag {0}' -f $nop.tag)
$tagRef = 'refs/tags/{0}' -f $nop.tag
$peeledRef = '{0}^{{}}' -f $tagRef
$lines = @(Invoke-BenchGit -Arguments @('ls-remote', '--tags', $nop.repository, $tagRef, $peeledRef) -Attempts 3)
$upstream = @{}
foreach ($line in $lines) {
    $parts = "$line" -split "`t"
    if ($parts.Count -eq 2) { $upstream[$parts[1]] = $parts[0] }
}
if ($upstream.ContainsKey($peeledRef)) { $upstreamCommit = $upstream[$peeledRef] }       # annotated tag
elseif ($upstream.ContainsKey($tagRef)) { $upstreamCommit = $upstream[$tagRef] }         # lightweight tag
else { throw ('Tag {0} not found in {1}.' -f $nop.tag, $nop.repository) }
if ($upstreamCommit -ne $nop.commit) {
    throw ('Upstream tag {0} now points at {1}, but pins.json pins {2}. Refusing to build a moved tag; review the change and record a decision before updating the pin.' -f $nop.tag, $upstreamCommit, $nop.commit)
}
Write-BenchLog ('Upstream {0} -> {1} (matches pins.json)' -f $nop.tag, $upstreamCommit)
Exit-BenchGroup

$reused = $false
if (-not $Force -and (Test-BenchPinnedCheckout -Directory $Destination -Commit $nop.commit)) {
    Write-BenchLog ('Reusing verified checkout at {0}' -f $Destination)
    $reused = $true
}
else {
    Enter-BenchGroup ('Fetch {0} into {1}' -f $nop.tag, $Destination)
    if (Test-Path -LiteralPath $Destination) {
        Write-BenchLog ('Removing {0}' -f $Destination)
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Force -Path $Destination
    $null = Invoke-BenchGit -Arguments @('-C', $Destination, 'init', '--quiet')
    $null = Invoke-BenchGit -Arguments @('-C', $Destination, 'config', 'core.autocrlf', 'false')
    $null = Invoke-BenchGit -Arguments @('-C', $Destination, 'config', 'core.longpaths', 'true')
    $null = Invoke-BenchGit -Arguments @('-C', $Destination, 'remote', 'add', 'origin', $nop.repository)
    $refspec = '+{0}:{0}' -f $tagRef
    $null = Invoke-BenchGit -Arguments @('-C', $Destination, 'fetch', '--quiet', '--depth', '1', '--no-tags', 'origin', $refspec) -Attempts 3
    $fetched = "$(Invoke-BenchGit -Arguments @('-C', $Destination, 'rev-parse', ('{0}^{{commit}}' -f $tagRef)))".Trim()
    if ($fetched -ne $nop.commit) {
        throw ('Fetched {0} resolves to {1}, expected {2}.' -f $nop.tag, $fetched, $nop.commit)
    }
    $null = Invoke-BenchGit -Arguments @('-c', 'advice.detachedHead=false', '-C', $Destination, 'checkout', '--quiet', '--detach', $nop.commit)
    Exit-BenchGroup
}

if (-not (Test-BenchPinnedCheckout -Directory $Destination -Commit $nop.commit)) {
    throw ('Checkout at {0} is not a clean tree at {1}.' -f $Destination, $nop.commit)
}
$fileCount = @(Invoke-BenchGit -Arguments @('-C', $Destination, 'ls-files')).Count
Write-BenchLog ('Verified: {0} at {1}, {2} tracked files, no local modifications.' -f $nop.tag, $nop.commit, $fileCount)

Write-BenchState -WorkRoot $work -Name 'fetch' -Data ([ordered]@{
        repository    = $nop.repository
        tag           = $nop.tag
        commit        = $nop.commit
        sourceDir     = $Destination
        trackedFiles  = $fileCount
        reused        = $reused
        verifiedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })
