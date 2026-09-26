<#
.SYNOPSIS
    Runbook step 4: deploy the published site to IIS and run nopCommerce's installer with
    sample data, unattended.

.DESCRIPTION
    Always a clean install: the site, its application pool and its database are
    replaced, so a re-run converges on the same state instead of accumulating one.

      1. Checks the site against the SHA-256 manifest step 2 wrote, so what IIS serves is
         provably what was built.
      2. Removes an earlier deployment (site, application pool, database).
      3. Copies the site to the install directory and grants the application pool
         identity Modify on it - nopCommerce writes App_Data, Plugins\bin and image
         thumbnails at run time, and its installer refuses to start without it.
      4. Creates the application pool (.NET CLR v4.0, integrated pipeline, no idle
         time-out, no periodic recycle: a recording must not straddle a restart) and the
         site on a fixed port.
      5. Gives the application pool identity a Windows login on SQL Server with the
         dbcreator role only. The connection string therefore carries no password.
      6. Posts nopCommerce's own install form - the same fields a person submits at
         /install - with "create database" and "create sample data" on. Seeding goes
         through the application's own installer, not around it.
      7. Waits for the restarted shop to answer, and records what it did in
         state\deploy.json.

    The administrator account the installer creates gets a password generated for this
    run (or taken from NOPBENCH_ADMIN_PASSWORD). It is masked in CI logs, never printed,
    and written only to <WorkRoot>\secrets\legacy-admin.json, readable by the current
    user and Administrators, outside the repository.

    Needs an elevated PowerShell on Windows, after steps 2 and 3.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER SiteDir
    The published site. Default: the one recorded in state\build.json if it exists on
    this machine, else <WorkRoot>\legacy-site.

.PARAMETER InstallDir
    Where IIS serves the site from. Default: C:\inetpub\nopcommerce-legacy.

.PARAMETER SiteName
    IIS site and application pool name. Default: nopcommerce-legacy.

.PARAMETER Port
    HTTP port of the site. Default: 8080 (docs/TOPOLOGY.md lists every port).

.PARAMETER SqlServer
    Default: the instance recorded in state\platform.json, else .\SQLEXPRESS.

.PARAMETER DatabaseName
    Default: nopcommerce_legacy. Dropped and recreated on every run.

.PARAMETER AdminEmail
    E-mail of the store administrator the installer creates. Default:
    admin@nopbench.invalid (a reserved domain: nothing is ever delivered).

.EXAMPLE
    .\scripts\4-deploy-and-install.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $SiteDir,
    [string] $InstallDir,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string] $SiteName = 'nopcommerce-legacy',
    [ValidateRange(1, 65535)][int] $Port = 8080,
    [string] $SqlServer,
    [ValidatePattern('^[A-Za-z0-9_]+$')][string] $DatabaseName = 'nopcommerce_legacy',
    [string] $AdminEmail = 'admin@nopbench.invalid',
    [int] $InstallTimeoutSeconds = 1200,
    [int] $WarmupTimeoutSeconds = 900
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')

Assert-BenchAdministrator
$repoRoot = Split-Path -Parent $PSScriptRoot
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
if (-not (Test-Path -LiteralPath $appcmd)) { throw 'IIS is not installed. Run scripts\3-install-iis-sql.ps1 first.' }
$collation = $pins.toolchain.sqlServerExpress.collation
$timings = [ordered]@{}
$clock = [System.Diagnostics.Stopwatch]::StartNew()

function Complete-Phase {
    param([string] $Name)
    $timings[$Name] = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Write-BenchLog ('{0} took {1} s' -f $Name, $timings[$Name])
    $clock.Restart()
}

function Invoke-AppCmd {
    # appcmd reports "not found" through its exit code; callers that probe pass
    # -AllowFailure and look at the output instead.
    param([string[]] $Arguments, [switch] $AllowFailure)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $appcmd @Arguments
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ('appcmd {0} failed ({1}): {2}' -f ($Arguments -join ' '), $code, ($output -join ' '))
    }
    return $output
}

# --- Inputs -------------------------------------------------------------------------
$build = Read-BenchState -WorkRoot $work -Name 'build'
if ($SiteDir) { $SiteDir = Get-BenchFullPath $SiteDir }
elseif ($build -and (Test-Path -LiteralPath $build.siteDir)) { $SiteDir = $build.siteDir }
else { $SiteDir = Join-Path $work 'legacy-site' }
if (-not (Test-Path -LiteralPath (Join-Path $SiteDir 'bin\Nop.Web.dll'))) {
    throw ('{0} is not a published nopCommerce site. Run scripts\2-build-legacy.ps1 first (or download the legacy-site artifact).' -f $SiteDir)
}
if (-not $InstallDir) { $InstallDir = Join-Path $env:SystemDrive ('inetpub\{0}' -f $SiteName) }
$InstallDir = Get-BenchFullPath $InstallDir
if (-not $SqlServer) {
    $platform = Read-BenchState -WorkRoot $work -Name 'platform'
    if ($platform -and $platform.sqlServer.server) { $SqlServer = $platform.sqlServer.server } else { $SqlServer = '.\SQLEXPRESS' }
}
$baseUrl = 'http://localhost:{0}/' -f $Port
$poolIdentity = 'IIS APPPOOL\{0}' -f $SiteName

# --- 1. Integrity -------------------------------------------------------------------
Enter-BenchGroup 'Check the site against its build manifest'
$manifestPath = Join-Path (Join-Path $work 'state') 'legacy-site.sha256'
$manifestDigest = $null
if (Test-Path -LiteralPath $manifestPath) {
    $manifestDigest = Get-BenchSha256 $manifestPath
    $expected = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ })
    $mismatches = New-Object System.Collections.Generic.List[string]
    foreach ($line in $expected) {
        $hash = $line.Substring(0, 64)
        $relative = $line.Substring(66)
        $file = Join-Path $SiteDir ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $file)) { $mismatches.Add(('missing {0}' -f $relative)); continue }
        if ((Get-BenchSha256 $file) -ne $hash) { $mismatches.Add(('changed {0}' -f $relative)) }
    }
    $actualCount = @(Get-ChildItem -LiteralPath $SiteDir -Recurse -File).Count
    if ($actualCount -ne $expected.Count) { $mismatches.Add(('{0} files on disk, {1} in the manifest' -f $actualCount, $expected.Count)) }
    if ($mismatches.Count -gt 0) {
        $mismatches | Select-Object -First 20 | ForEach-Object { Write-BenchLog ('MISMATCH: {0}' -f $_) }
        throw ('{0} does not match {1} ({2} problem(s)).' -f $SiteDir, $manifestPath, $mismatches.Count)
    }
    Write-BenchLog ('{0} files match the build manifest (sha256 {1}).' -f $expected.Count, $manifestDigest)
}
else {
    Write-Warning ('No build manifest at {0}; deploying {1} unverified.' -f $manifestPath, $SiteDir)
}
Exit-BenchGroup
Complete-Phase 'verify'

# --- 2. Remove an earlier deployment ------------------------------------------------
Enter-BenchGroup ('Remove an earlier deployment of {0}' -f $SiteName)
if (@(Invoke-AppCmd -Arguments @('list', 'site', ('/name:{0}' -f $SiteName), '/text:name') -AllowFailure) -contains $SiteName) {
    $null = Invoke-AppCmd -Arguments @('delete', 'site', $SiteName)
    Write-BenchLog ('Deleted IIS site {0}' -f $SiteName)
}
if (@(Invoke-AppCmd -Arguments @('list', 'apppool', ('/name:{0}' -f $SiteName), '/text:name') -AllowFailure) -contains $SiteName) {
    $null = Invoke-AppCmd -Arguments @('delete', 'apppool', $SiteName)
    Write-BenchLog ('Deleted application pool {0}' -f $SiteName)
}
# http.sys may take a moment to release the port of a site that was just deleted.
$portDeadline = (Get-Date).AddSeconds(30)
while ($true) {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) { break }
    if ((Get-Date) -ge $portDeadline) {
        throw ('Port {0} is already in use (process id {1}). Pick another -Port or stop the other listener.' -f $Port, (($listeners | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique) -join ', '))
    }
    Start-Sleep -Seconds 2
}
$dropDatabase = @"
IF DB_ID(N'$DatabaseName') IS NOT NULL
BEGIN
    ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DatabaseName];
    SELECT N'dropped';
END
ELSE SELECT N'absent';
"@
$dropped = Invoke-BenchSqlScalar -Server $SqlServer -Query $dropDatabase
Write-BenchLog ('Database {0} on {1}: {2}' -f $DatabaseName, $SqlServer, $dropped)
Exit-BenchGroup

# --- 3 and 4. Files, application pool, permissions, site -----------------------------
Enter-BenchGroup ('Deploy to IIS: {0} on port {1}' -f $SiteName, $Port)
$null = Invoke-AppCmd -Arguments @('add', 'apppool', ('/name:{0}' -f $SiteName), '/managedRuntimeVersion:v4.0', '/managedPipelineMode:Integrated')
$null = Invoke-AppCmd -Arguments @(
    'set', 'apppool', $SiteName,
    '/processModel.identityType:ApplicationPoolIdentity',
    '/processModel.loadUserProfile:true',
    '/processModel.idleTimeout:00:00:00',
    '/recycling.periodicRestart.time:00:00:00',
    '/enable32BitAppOnWin64:false'
)
$null = New-Item -ItemType Directory -Force -Path $InstallDir
# Granted on the root before copying, so every copied file inherits it.
Invoke-BenchNative -FilePath (Join-Path $env:windir 'System32\icacls.exe') -ArgumentList @($InstallDir, '/grant', ('{0}:(OI)(CI)M' -f $poolIdentity), '/Q')
# robocopy: exit codes below 8 mean success. /MIR also removes what an earlier install
# wrote (App_Data\Settings.txt and friends), which is what makes this a clean install.
Invoke-BenchNative -FilePath (Join-Path $env:windir 'System32\robocopy.exe') -ArgumentList @($SiteDir, $InstallDir, '/MIR', '/R:3', '/W:2', '/NFL', '/NDL', '/NP', '/NJH') -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7)
$null = Invoke-AppCmd -Arguments @('add', 'site', ('/name:{0}' -f $SiteName), ('/bindings:http/*:{0}:' -f $Port), ('/physicalPath:{0}' -f $InstallDir))
$null = Invoke-AppCmd -Arguments @('set', 'app', ('{0}/' -f $SiteName), ('/applicationPool:{0}' -f $SiteName))
$siteState = "$(Invoke-AppCmd -Arguments @('list', 'site', ('/name:{0}' -f $SiteName), '/text:state'))".Trim()
if ($siteState -ne 'Started') { $null = Invoke-AppCmd -Arguments @('start', 'site', ('/site.name:{0}' -f $SiteName)) }
Write-BenchLog ('IIS site {0} ({1}) serves {2} as {3}' -f $SiteName, $baseUrl, $InstallDir, $poolIdentity)
Exit-BenchGroup

# --- 5. SQL Server login for the application pool ------------------------------------
Enter-BenchGroup 'SQL Server login for the application pool identity'
$grantLogin = @"
IF SUSER_ID(N'$poolIdentity') IS NULL CREATE LOGIN [$poolIdentity] FROM WINDOWS WITH DEFAULT_DATABASE = [master];
ALTER SERVER ROLE [dbcreator] ADD MEMBER [$poolIdentity];
SELECT IS_SRVROLEMEMBER(N'dbcreator', N'$poolIdentity');
"@
$isCreator = Invoke-BenchSqlScalar -Server $SqlServer -Query $grantLogin
Write-BenchLog ('Login [{0}] on {1}: dbcreator = {2}' -f $poolIdentity, $SqlServer, $isCreator)
Exit-BenchGroup
Complete-Phase 'deploy'

# --- 6. Installer -------------------------------------------------------------------
Enter-BenchGroup 'Run the nopCommerce installer (sample data)'
$client = New-BenchHttpClient -TimeoutSeconds ([math]::Max($InstallTimeoutSeconds, $WarmupTimeoutSeconds))
$installForm = Wait-BenchHttp -Client $client -Uri ($baseUrl + 'install') -TimeoutSeconds $WarmupTimeoutSeconds
if ($installForm.Body -notmatch 'name="AdminEmail"') { throw 'GET /install answered 200 but is not the nopCommerce install form.' }
Complete-Phase 'firstRequest'

$password = $env:NOPBENCH_ADMIN_PASSWORD
$generated = $false
if (-not $password) {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $password = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
    $generated = $true
}
Add-BenchSecretMask $password

$connectionString = 'Data Source={0};Initial Catalog={1};Integrated Security=True;Persist Security Info=False' -f $SqlServer, $DatabaseName
# Field names and values are those of nopCommerce 3.90's InstallModel and install view
# (Nop.Web\Models\Install\InstallModel.cs, Nop.Web\Views\Install\Index.cshtml).
$form = [ordered]@{
    AdminEmail               = $AdminEmail
    AdminPassword            = $password
    ConfirmPassword          = $password
    InstallSampleData        = 'true'
    DataProvider             = 'sqlserver'
    SqlConnectionInfo        = 'sqlconnectioninfo_raw'
    DatabaseConnectionString = $connectionString
    SqlAuthenticationType    = 'windowsauthentication'
    SqlServerCreateDatabase  = 'true'
    UseCustomCollation       = 'true'
    Collation                = $collation
}
Write-BenchLog ('POST {0}install  (database {1} on {2}, collation {3}, sample data)' -f $baseUrl, $DatabaseName, $SqlServer, $collation)
$install = Invoke-BenchHttp -Client $client -Uri ($baseUrl + 'install') -Method POST -Form $form
Write-BenchLog ('Installer answered {0} after {1:N0} s' -f $install.StatusCode, ($install.Ms / 1000))
$succeeded = ($install.StatusCode -eq 302 -and "$($install.Location)" -match '^(/|https?://[^/]+/)$')
if (-not $succeeded) {
    $errors = @()
    $match = [regex]::Match($install.Body, '<div class="validation-summary-errors"[^>]*>(.*?)</div>', 'Singleline')
    if ($match.Success) {
        $errors = @([regex]::Matches($match.Groups[1].Value, '<li>(.*?)</li>', 'Singleline') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value).Trim() })
    }
    if ($errors.Count -eq 0) {
        $title = [regex]::Match($install.Body, '<title>(.*?)</title>', 'Singleline').Groups[1].Value.Trim()
        $errors = @(('HTTP {0} {1} (Location: {2})' -f $install.StatusCode, $title, $install.Location))
    }
    $errors | ForEach-Object { Write-BenchLog ('INSTALLER: {0}' -f $_) }
    throw 'The nopCommerce installer did not complete.'
}
Complete-Phase 'install'
Exit-BenchGroup

# --- 7. The restarted shop ----------------------------------------------------------
Enter-BenchGroup 'Wait for the installed shop'
$homePage = Wait-BenchHttp -Client $client -Uri $baseUrl -TimeoutSeconds $WarmupTimeoutSeconds
if ($homePage.Body -notmatch 'nopCommerce') { throw ('{0} answered 200 without nopCommerce content.' -f $baseUrl) }
$settingsFile = Join-Path $InstallDir 'App_Data\Settings.txt'
if (-not (Test-Path -LiteralPath $settingsFile)) { throw 'App_Data\Settings.txt was not written: the installer did not finish.' }
$tables = Invoke-BenchSqlScalar -Server $SqlServer -Database $DatabaseName -Query 'SELECT COUNT(*) FROM sys.tables'
$products = Invoke-BenchSqlScalar -Server $SqlServer -Database $DatabaseName -Query 'SELECT COUNT(*) FROM dbo.Product WHERE Deleted = 0'
$dbCollation = Invoke-BenchSqlScalar -Server $SqlServer -Query ("SELECT CAST(DATABASEPROPERTYEX(N'{0}', 'Collation') AS nvarchar(128))" -f $DatabaseName)
Write-BenchLog ('Shop is up at {0}: {1} tables, {2} products, database collation {3}' -f $baseUrl, $tables, $products, $dbCollation)
Exit-BenchGroup
Complete-Phase 'warmup'

# --- Records ------------------------------------------------------------------------
$secretsDir = Join-Path $work 'secrets'
$null = New-Item -ItemType Directory -Force -Path $secretsDir
$secretsFile = Join-Path $secretsDir 'legacy-admin.json'
$secretJson = ([ordered]@{ url = ($baseUrl + 'admin'); email = $AdminEmail; password = $password; generated = $generated }) | ConvertTo-Json
[System.IO.File]::WriteAllText($secretsFile, $secretJson, (New-Object System.Text.UTF8Encoding($false)))
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Invoke-BenchNative -FilePath (Join-Path $env:windir 'System32\icacls.exe') -ArgumentList @($secretsFile, '/inheritance:r', '/grant:r', ('{0}:F' -f $me), '*S-1-5-32-544:F', '*S-1-5-18:F', '/Q')
Write-BenchLog ('Administrator credentials for this run: {0} (current user and Administrators only)' -f $secretsFile)

Write-BenchState -WorkRoot $work -Name 'deploy' -Data ([ordered]@{
        url = $baseUrl
        siteName = $SiteName
        appPool = $SiteName
        appPoolIdentity = $poolIdentity
        port = $Port
        installDir = $InstallDir
        sourceSiteDir = $SiteDir
        siteManifestSha256 = $manifestDigest
        sqlServer = $SqlServer
        database = $DatabaseName
        databaseCollation = [string] $dbCollation
        connectionString = $connectionString
        sampleData = $true
        tables = [int] $tables
        products = [int] $products
        adminEmail = $AdminEmail
        adminCredentials = $secretsFile
        timingsSeconds = $timings
        installedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

Add-BenchSummary -Lines @(
    '### Legacy deployment',
    '',
    '| | |',
    '|---|---|',
    ('| URL | {0} (IIS site `{1}`, identity `{2}`) |' -f $baseUrl, $SiteName, $poolIdentity),
    ('| Database | `{0}` on `{1}`, {2}, {3} tables, {4} products |' -f $DatabaseName, $SqlServer, $dbCollation, $tables, $products),
    ('| Site manifest | `{0}` |' -f $manifestDigest),
    ('| Seconds | {0} |' -f (($timings.Keys | ForEach-Object { '{0} {1}' -f $_, $timings[$_] }) -join ', ')),
    ''
)
