<#
.SYNOPSIS
    Collects what it takes to debug a failed legacy deployment into one folder.

.DESCRIPTION
    Not a runbook step: run it when step 3, 4 or 5 fails (CI does, and uploads the result
    as the legacy-iis-diagnostics artifact). Best effort - every section that cannot be
    collected is noted and skipped, and the script itself never fails.

    Collects: the hand-off state files, the IIS site and application pool configuration,
    IIS and HTTP.SYS logs, recent Application and System event log entries (ASP.NET,
    .NET Runtime, IIS, SQL Server), the SQL Server setup summary and error log,
    nopCommerce's App_Data state files, and the last entries of nopCommerce's own Log
    table.

    Never collects <WorkRoot>\secrets.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER OutputDir
    Default: <WorkRoot>\diagnostics (emptied first).

.EXAMPLE
    .\scripts\collect-diagnostics.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $OutputDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')

$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
if ($OutputDir) { $OutputDir = Get-BenchFullPath $OutputDir } else { $OutputDir = Join-Path $work 'diagnostics' }
if (Test-Path -LiteralPath $OutputDir) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$since = (Get-Date).AddHours(-3)

function Save-Section {
    param([string] $Name, [scriptblock] $Action)
    try {
        & $Action
        Write-BenchLog ('collected {0}' -f $Name)
    }
    catch {
        Write-BenchLog ('skipped {0}: {1}' -f $Name, $_.Exception.Message)
        Add-Content -LiteralPath (Join-Path $OutputDir 'skipped.txt') -Value ('{0}: {1}' -f $Name, $_.Exception.Message)
    }
}

$deploy = Read-BenchState -WorkRoot $work -Name 'deploy'
$siteName = 'nopcommerce-legacy'
$installDir = Join-Path $env:SystemDrive 'inetpub\nopcommerce-legacy'
$sqlServer = '.\SQLEXPRESS'
$database = 'nopcommerce_legacy'
if ($deploy) { $siteName = $deploy.siteName; $installDir = $deploy.installDir; $sqlServer = $deploy.sqlServer; $database = $deploy.database }

Save-Section 'state files' {
    $target = Join-Path $OutputDir 'state'
    $null = New-Item -ItemType Directory -Force -Path $target
    Get-ChildItem -LiteralPath (Join-Path $work 'state') -Filter '*.json' | Copy-Item -Destination $target
}

Save-Section 'IIS configuration' {
    $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    $lines = @()
    $lines += & $appcmd list site
    $lines += & $appcmd list apppool
    $lines += & $appcmd list site ('/name:{0}' -f $siteName) /config
    $lines += & $appcmd list apppool ('/name:{0}' -f $siteName) /config
    $lines += & $appcmd list wp
    $lines | Set-Content -LiteralPath (Join-Path $OutputDir 'iis-config.txt')
}

Save-Section 'IIS and HTTP.SYS logs' {
    foreach ($source in @((Join-Path $env:SystemDrive 'inetpub\logs\LogFiles'), (Join-Path $env:windir 'System32\LogFiles\HTTPERR'))) {
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDir ('logs-' + (Split-Path -Leaf $source))) -Recurse
        }
    }
}

Save-Section 'event logs' {
    foreach ($log in @('Application', 'System')) {
        Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -MaxEvents 400 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'ASP\.NET|\.NET Runtime|Application Error|W3SVC|WAS|IIS|MSSQL|SQL' -or $_.Level -le 2 } |
            Format-List TimeCreated, ProviderName, Id, LevelDisplayName, Message |
            Out-File -LiteralPath (Join-Path $OutputDir ('eventlog-{0}.txt' -f $log.ToLowerInvariant())) -Width 400
    }
}

Save-Section 'SQL Server logs' {
    $setupSummary = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt') -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($setupSummary) { Copy-Item -LiteralPath $setupSummary.FullName -Destination (Join-Path $OutputDir 'sql-setup-summary.txt') }
    $logPatterns = @(Join-Path $env:ProgramFiles 'Microsoft SQL Server\MSSQL*.*\MSSQL\Log\ERRORLOG')
    $logPatterns += (Join-Path $work 'sqldata\MSSQL*.*\MSSQL\Log\ERRORLOG')
    $errorLog = $logPatterns | ForEach-Object { Get-ChildItem -Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($errorLog) { Copy-Item -LiteralPath $errorLog.FullName -Destination (Join-Path $OutputDir 'sql-errorlog.txt') }
}

Save-Section 'nopCommerce App_Data state' {
    foreach ($name in @('Settings.txt', 'InstalledPlugins.txt')) {
        $file = Join-Path $installDir ('App_Data\{0}' -f $name)
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination (Join-Path $OutputDir ('app_data-{0}' -f $name)) }
    }
}

Save-Section 'nopCommerce Log table' {
    $query = @"
IF DB_ID(N'$database') IS NULL SELECT N'database $database does not exist'
ELSE SELECT (SELECT TOP (50) CreatedOnUtc, LogLevelId, ShortMessage, PageUrl, FullMessage
             FROM [$database].dbo.[Log] ORDER BY Id DESC FOR XML PATH('entry'), ROOT('log'))
"@
    $xml = Invoke-BenchSqlScalar -Server $sqlServer -Query $query
    [System.IO.File]::WriteAllText((Join-Path $OutputDir 'nopcommerce-log.xml'), [string] $xml)
}

# The most telling excerpts also go to the job log, for readers without the artifact.
foreach ($excerpt in @('sql-errorlog.txt', 'nopcommerce-log.xml')) {
    $file = Join-Path $OutputDir $excerpt
    if (Test-Path -LiteralPath $file) {
        Enter-BenchGroup ('Excerpt: {0}' -f $excerpt)
        Get-Content -LiteralPath $file -Tail 60 | Out-Host
        Exit-BenchGroup
    }
}
Write-BenchLog ('Diagnostics in {0}' -f $OutputDir)

# Best effort by design: never fail the job a second time.
exit 0
