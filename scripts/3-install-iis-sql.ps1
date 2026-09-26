<#
.SYNOPSIS
    Runbook step 3: enable IIS with ASP.NET 4.x and install SQL Server 2022 Express.

.DESCRIPTION
    Prepares the Windows host the legacy shop runs on (docs/TOPOLOGY.md):

      1. IIS with ASP.NET 4.x, via DISM optional features. The feature names are the
         same on Windows Server and on Windows 10/11, so one code path serves the CI
         runner and a workstation. Response compression is deliberately not installed:
         recorded traffic (P4) should not depend on it.
      2. SQL Server 2022 Express as the named instance SQLEXPRESS, from Microsoft's
         media pinned in pins.json. The download must match the pinned SHA-256 and carry
         a valid Microsoft Authenticode signature. Server collation is pinned so that
         ordering and comparison in the database do not depend on the host's locale.
         Members of BUILTIN\Administrators are sysadmins; the site itself connects with
         its own least-privilege Windows login (step 4).

    Idempotent: features already enabled are left alone, and an existing SQLEXPRESS
    instance is reused after its collation is checked.

    Needs an elevated PowerShell on Windows.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench. Downloads land in <WorkRoot>\downloads.

.PARAMETER SkipIis
    Leave IIS alone (for example when only SQL Server needs repairing).

.PARAMETER SkipSql
    Leave SQL Server alone.

.EXAMPLE
    .\scripts\3-install-iis-sql.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [switch] $SkipIis,
    [switch] $SkipSql
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')

Assert-BenchAdministrator
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repoRoot = Split-Path -Parent $PSScriptRoot
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$sqlPin = $pins.toolchain.sqlServerExpress
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$timings = [ordered]@{}
$clock = [System.Diagnostics.Stopwatch]::StartNew()

# Leaf features; /All enables their parents (IIS-WebServerRole, IIS-WebServer, ...).
$iisFeatures = @(
    'IIS-DefaultDocument',
    'IIS-StaticContent',
    'IIS-HttpErrors',
    'IIS-HttpLogging',
    'IIS-RequestFiltering',
    'IIS-NetFxExtensibility45',
    'IIS-ISAPIExtensions',
    'IIS-ISAPIFilter',
    'IIS-ASPNET45'
)

# --- IIS ----------------------------------------------------------------------------
$iisState = 'skipped'
if (-not $SkipIis) {
    Enter-BenchGroup 'IIS with ASP.NET 4.x (DISM)'
    $dism = Join-Path $env:windir 'System32\dism.exe'
    $arguments = @('/Online', '/Enable-Feature', '/All', '/NoRestart')
    foreach ($feature in $iisFeatures) { $arguments += ('/FeatureName:{0}' -f $feature) }
    # 3010 = success, restart required. IIS does not need the restart to serve.
    $code = Invoke-BenchNative -FilePath $dism -ArgumentList $arguments -SuccessExitCodes @(0, 3010) -PassThru
    if ($code -eq 3010) { Write-BenchLog 'DISM reports that a restart is pending; IIS works without it.' }
    foreach ($service in @('WAS', 'W3SVC')) {
        $svc = Get-Service -Name $service
        if ($svc.Status -ne 'Running') { Start-Service -Name $service }
        Write-BenchLog ('{0}: {1}' -f $service, (Get-Service -Name $service).Status)
    }
    $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    if (-not (Test-Path -LiteralPath $appcmd)) { throw ('IIS is enabled but {0} is missing.' -f $appcmd) }
    $iisVersion = (Get-Item -LiteralPath (Join-Path $env:windir 'System32\inetsrv\w3wp.exe')).VersionInfo.ProductVersion
    # The handler ASP.NET MVC's extensionless URLs run through exists only once ASP.NET
    # 4.x is registered with IIS.
    $handlers = (& $appcmd list config /section:system.webServer/handlers) -join "`n"
    if ($handlers -notmatch 'ExtensionlessUrlHandler-Integrated-4\.0') { throw 'ASP.NET 4.x is not registered with IIS (no ExtensionlessUrlHandler-Integrated-4.0 handler).' }
    $iisState = 'enabled'
    Write-BenchLog ('IIS {0} with ASP.NET 4.x is ready.' -f $iisVersion)
    Exit-BenchGroup
}
$timings['iis'] = [math]::Round($clock.Elapsed.TotalSeconds, 1)
$clock.Restart()

# --- SQL Server Express -------------------------------------------------------------
$instance = $sqlPin.instanceName
$serviceName = 'MSSQL${0}' -f $instance
$serverName = '.\{0}' -f $instance
$sqlState = 'skipped'
$sqlVersion = $null
$sqlCollation = $null
if (-not $SkipSql) {
    Enter-BenchGroup ('SQL Server Express ({0})' -f $serverName)
    $installedNow = $false
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Write-BenchLog ('Instance {0} already exists; reusing it.' -f $instance)
    }
    else {
        $media = Join-Path (Join-Path $work 'downloads') 'SQLEXPR_x64_ENU.exe'
        $null = Get-BenchVerifiedDownload -Uri $sqlPin.url -Sha256 $sqlPin.sha256 -Destination $media
        $signature = Get-AuthenticodeSignature -FilePath $media
        $signer = ''
        if ($signature.SignerCertificate) { $signer = $signature.SignerCertificate.Subject }
        if ($signature.Status -ne 'Valid' -or $signer -notmatch ('O={0}' -f [regex]::Escape($sqlPin.signer))) {
            throw ('{0}: Authenticode status {1}, signer "{2}"; expected a valid signature by {3}.' -f $media, $signature.Status, $signer, $sqlPin.signer)
        }
        Write-BenchLog ('Signature valid: {0}' -f $signer)

        $extractDir = Join-Path (Join-Path $work 'tools') 'sqlexpress-media'
        if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
        Write-BenchLog ('Extracting the media to {0}' -f $extractDir)
        $extract = Start-Process -FilePath $media -ArgumentList @('/Q', ('/X:"{0}"' -f $extractDir)) -Wait -PassThru -NoNewWindow
        if ($extract.ExitCode -ne 0) { throw ('Extracting {0} failed with exit code {1}.' -f $media, $extract.ExitCode) }
        $setup = Join-Path $extractDir 'SETUP.EXE'
        if (-not (Test-Path -LiteralPath $setup)) { throw ('{0} not found after extraction.' -f $setup) }

        # RebootRequiredCheck is skipped because enabling IIS a minute earlier may leave
        # a restart pending that has nothing to do with SQL Server.
        $setupArguments = @(
            '/Q', '/ACTION=Install', '/IACCEPTSQLSERVERLICENSETERMS',
            '/FEATURES=SQLENGINE',
            ('/INSTANCENAME={0}' -f $instance), ('/INSTANCEID={0}' -f $instance),
            '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"',
            ('/SQLCOLLATION={0}' -f $sqlPin.collation),
            '/TCPENABLED=1', '/NPENABLED=0',
            '/UPDATEENABLED=False',
            '/SKIPRULES=RebootRequiredCheck'
        )
        Write-BenchLog ('> {0} {1}' -f $setup, ($setupArguments -join ' '))
        $process = Start-Process -FilePath $setup -ArgumentList $setupArguments -Wait -PassThru -NoNewWindow
        $setupCode = $process.ExitCode
        $summary = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (@(0, 3010) -notcontains $setupCode) {
            if ($summary) { Get-Content -LiteralPath $summary.FullName | Out-Host }
            throw ('SQL Server setup failed with exit code {0}.' -f $setupCode)
        }
        Write-BenchLog ('SQL Server setup finished with exit code {0}.' -f $setupCode)
        $installedNow = $true
    }

    $service = Get-Service -Name $serviceName
    if ($service.Status -ne 'Running') { Start-Service -Name $serviceName }
    $sqlVersion = [string] (Invoke-BenchSqlScalar -Server $serverName -Query "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) + N' ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(128))")
    $sqlCollation = [string] (Invoke-BenchSqlScalar -Server $serverName -Query "SELECT CAST(SERVERPROPERTY('Collation') AS nvarchar(128))")
    Write-BenchLog ('{0}: SQL Server {1}, collation {2}' -f $serverName, $sqlVersion, $sqlCollation)
    if ($sqlCollation -ne $sqlPin.collation) {
        # Not fatal: step 4 creates the database with the pinned collation explicitly.
        Write-Warning ('Server collation is {0}, pins.json expects {1}; the database will still be created with {1}.' -f $sqlCollation, $sqlPin.collation)
    }
    if ($installedNow) { $sqlState = 'installed' } else { $sqlState = 'reused' }
    Exit-BenchGroup
}
$timings['sql'] = [math]::Round($clock.Elapsed.TotalSeconds, 1)

Write-BenchState -WorkRoot $work -Name 'platform' -Data ([ordered]@{
        iis = [ordered]@{ state = $iisState; features = $iisFeatures }
        sqlServer = [ordered]@{ state = $sqlState; server = $serverName; service = $serviceName; version = $sqlVersion; collation = $sqlCollation }
        timingsSeconds = $timings
        preparedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

Add-BenchSummary -Lines @(
    '### Legacy host',
    '',
    '| | |',
    '|---|---|',
    ('| IIS | {0} (ASP.NET 4.x) |' -f $iisState),
    ('| SQL Server | {0}: `{1}` {2}, collation {3} |' -f $sqlState, $serverName, $sqlVersion, $sqlCollation),
    ('| Seconds | IIS {0}, SQL Server {1} |' -f $timings['iis'], $timings['sql']),
    ''
)
