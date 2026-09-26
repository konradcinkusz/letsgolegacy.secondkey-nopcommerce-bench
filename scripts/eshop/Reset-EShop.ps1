<#
.SYNOPSIS
    Puts the warm-up application back into its starting state: restarts its application
    pool, which empties the in-memory mock catalog back to its 12 items, and waits until it
    answers again.

.DESCRIPTION
    Not a numbered step. Step 3 calls it before recording each scenario, and `sk replay`
    calls it before replaying each scenario on each side (the `command` reset in
    warmup/eshop/secondkey.yaml), so every scenario starts from the same catalog.

    eShopLegacyMVC keeps its mock catalog in a single in-memory list for the lifetime of
    the process (CatalogServiceMock, registered as a single instance), and nothing resets
    it but a new process. Needs an elevated PowerShell (appcmd).

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench. The site comes from state\eshop-deploy.json.

.EXAMPLE
    .\scripts\eshop\Reset-EShop.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [int] $TimeoutSeconds = 300
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'NopBench.Common.ps1')

$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$deploy = Read-BenchState -WorkRoot $work -Name 'eshop-deploy'
if (-not $deploy) { throw 'No state\eshop-deploy.json: run scripts\eshop\2-deploy-eshop.ps1 first.' }
$pool = $deploy.appPool
$watch = [System.Diagnostics.Stopwatch]::StartNew()

function Wait-PoolState {
    param([string] $Expected)
    $deadline = (Get-Date).AddSeconds(60)
    while ("$(Invoke-BenchAppCmd -Arguments @('list', 'apppool', ('/name:{0}' -f $pool), '/text:state'))".Trim() -ne $Expected) {
        if ((Get-Date) -ge $deadline) { throw ('Application pool {0} did not reach {1} within 60 s.' -f $pool, $Expected) }
        Start-Sleep -Milliseconds 250
    }
}

$null = Invoke-BenchAppCmd -Arguments @('stop', 'apppool', ('/apppool.name:{0}' -f $pool)) -AllowFailure
Wait-PoolState -Expected 'Stopped'
$null = Invoke-BenchAppCmd -Arguments @('start', 'apppool', ('/apppool.name:{0}' -f $pool))
Wait-PoolState -Expected 'Started'

# The first request starts the application; a full catalog proves the old list is gone.
$client = New-BenchHttpClient -TimeoutSeconds $TimeoutSeconds
$catalog = Wait-BenchHttp -Client $client -Uri $deploy.url -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 1
if ($catalog.Body.IndexOf('Showing 10 of 12 products', [System.StringComparison]::Ordinal) -lt 0) {
    throw ('{0} answered after the restart, but not with the 12-item starting catalog.' -f $deploy.url)
}
Write-BenchLog ('{0} restarted and answering with its starting catalog after {1:N1} s' -f $pool, $watch.Elapsed.TotalSeconds)
exit 0
