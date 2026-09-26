<#
.SYNOPSIS
    Warm-up step 2 (P3): serve the published eShopLegacyMVC under IIS and check it answers.

.DESCRIPTION
    A clean deployment every time, like scripts\4-deploy-and-install.ps1 for nopCommerce:
    the site and its application pool are replaced, the files copied, and the application
    pool identity given Modify on the folder (the application writes its log4net log
    there). The application pool has no idle time-out and no periodic recycle; the only
    restarts are the ones Reset-EShop.ps1 makes on purpose.

    Needs IIS with ASP.NET 4.x (scripts\3-install-iis-sql.ps1 -SkipSql) and an elevated
    PowerShell. The mock catalog needs no database.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER SiteDir
    The published site. Default: the one recorded in state\eshop-build.json.

.PARAMETER SiteName
    IIS site and application pool name. Default: eshop-legacy.

.PARAMETER Port
    Default: 8081 (docs/TOPOLOGY.md lists every port).

.EXAMPLE
    .\scripts\eshop\2-deploy-eshop.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $SiteDir,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string] $SiteName = 'eshop-legacy',
    [ValidateRange(1, 65535)][int] $Port = 8081,
    [int] $WarmupTimeoutSeconds = 600
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'NopBench.Common.ps1')

Assert-BenchAdministrator
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
if (-not $SiteDir) {
    $build = Read-BenchState -WorkRoot $work -Name 'eshop-build'
    if ($build) { $SiteDir = $build.siteDir } else { $SiteDir = Join-Path $work 'eshop-site' }
}
if (-not (Test-Path -LiteralPath (Join-Path $SiteDir 'bin\eShopLegacyMVC.dll'))) { throw ('{0} is not a published eShopLegacyMVC. Run scripts\eshop\1-build-eshop.ps1 first.' -f $SiteDir) }
$installDir = Join-Path $env:SystemDrive ('inetpub\{0}' -f $SiteName)
$poolIdentity = 'IIS APPPOOL\{0}' -f $SiteName
$baseUrl = 'http://localhost:{0}/' -f $Port

Enter-BenchGroup ('Deploy {0} on port {1}' -f $SiteName, $Port)
if (@(Invoke-BenchAppCmd -Arguments @('list', 'site', ('/name:{0}' -f $SiteName), '/text:name') -AllowFailure) -contains $SiteName) {
    $null = Invoke-BenchAppCmd -Arguments @('delete', 'site', $SiteName)
}
if (@(Invoke-BenchAppCmd -Arguments @('list', 'apppool', ('/name:{0}' -f $SiteName), '/text:name') -AllowFailure) -contains $SiteName) {
    $null = Invoke-BenchAppCmd -Arguments @('delete', 'apppool', $SiteName)
}
$portDeadline = (Get-Date).AddSeconds(30)
while (@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count -gt 0) {
    if ((Get-Date) -ge $portDeadline) { throw ('Port {0} is already in use. Pick another -Port.' -f $Port) }
    Start-Sleep -Seconds 2
}
$null = Invoke-BenchAppCmd -Arguments @('add', 'apppool', ('/name:{0}' -f $SiteName), '/managedRuntimeVersion:v4.0', '/managedPipelineMode:Integrated')
$null = Invoke-BenchAppCmd -Arguments @(
    'set', 'apppool', $SiteName,
    '/processModel.identityType:ApplicationPoolIdentity',
    '/processModel.idleTimeout:00:00:00',
    '/recycling.periodicRestart.time:00:00:00',
    '/enable32BitAppOnWin64:false'
)
$null = New-Item -ItemType Directory -Force -Path $installDir
Invoke-BenchNative -FilePath (Join-Path $env:windir 'System32\icacls.exe') -ArgumentList @($installDir, '/grant', ('{0}:(OI)(CI)M' -f $poolIdentity), '/Q')
Invoke-BenchNative -FilePath (Join-Path $env:windir 'System32\robocopy.exe') -ArgumentList @($SiteDir, $installDir, '/MIR', '/R:3', '/W:2', '/NFL', '/NDL', '/NP', '/NJH') -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7)
$null = Invoke-BenchAppCmd -Arguments @('add', 'site', ('/name:{0}' -f $SiteName), ('/bindings:http/*:{0}:' -f $Port), ('/physicalPath:{0}' -f $installDir))
$null = Invoke-BenchAppCmd -Arguments @('set', 'app', ('{0}/' -f $SiteName), ('/applicationPool:{0}' -f $SiteName))
$state = "$(Invoke-BenchAppCmd -Arguments @('list', 'site', ('/name:{0}' -f $SiteName), '/text:state'))".Trim()
if ($state -ne 'Started') { $null = Invoke-BenchAppCmd -Arguments @('start', 'site', ('/site.name:{0}' -f $SiteName)) }
Exit-BenchGroup

Enter-BenchGroup ('Wait for {0}' -f $baseUrl)
$client = New-BenchHttpClient -TimeoutSeconds $WarmupTimeoutSeconds
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$catalog = Wait-BenchHttp -Client $client -Uri $baseUrl -TimeoutSeconds $WarmupTimeoutSeconds
foreach ($text in @('Catalog manager', '.NET Bot Black Hoodie', 'Showing 10 of 12 products')) {
    if ($catalog.Body.IndexOf($text, [System.StringComparison]::Ordinal) -lt 0) { throw ('{0} answered 200 without "{1}": not the mock catalog.' -f $baseUrl, $text) }
}
$firstSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
Write-BenchLog ('eShopLegacyMVC answers at {0} with the 12-item mock catalog (first answer after {1} s).' -f $baseUrl, $firstSeconds)
Exit-BenchGroup

Write-BenchState -WorkRoot $work -Name 'eshop-deploy' -Data ([ordered]@{
        url = $baseUrl
        siteName = $SiteName
        appPool = $SiteName
        appPoolIdentity = $poolIdentity
        port = $Port
        installDir = $installDir
        sourceSiteDir = $SiteDir
        firstAnswerSeconds = $firstSeconds
        deployedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

Add-BenchSummary -Lines @(
    '### Warm-up: eShopLegacyMVC under IIS',
    '',
    ('Answers at {0} (IIS site `{1}`), mock catalog of 12 items; first answer after {2} s.' -f $baseUrl, $SiteName, $firstSeconds),
    ''
)

exit 0
