<#
.SYNOPSIS
    P9 mutants, step 2: run a mutant build of nopCommerce as a second IIS site beside the
    legacy shop, on the legacy shop's database.

.DESCRIPTION
    A mutant (docs/P9-MUTANTS.md) is the pinned nopCommerce with one hand-written defect,
    built by scripts\2-build-legacy.ps1 -Patch into a work root of its own. It is replayed
    against the legacy shop exactly as the P7 candidate will be (8-replay.ps1 -Candidate),
    so it runs where the replay's reset reaches it: beside the legacy site, on the same
    database. Both sides are then restored to the same snapshot before every scenario, and
    contract\secondkey.yaml serves unchanged.

      1. Checks the mutant's published site against the manifest its build wrote, and that
         the build is the one mutants\mutants.json names for -Id: its patch, by SHA-256, or
         no patch at all for the calibration mutant M00.
      2. Replaces an earlier mutant deployment: site, application pool, files.
      3. Copies the site into its own folder, then the legacy install's App_Data\Settings.txt
         (the connection string) and App_Data\InstalledPlugins.txt, so the mutant opens the
         database the legacy installer created and step 6 configured: no second install and
         no second configuration.
      4. Creates its application pool and site the way step 4 creates the legacy ones (.NET
         CLR v4.0, integrated pipeline, no idle time-out, no periodic recycle), on its own
         port.
      5. Gives the pool identity a Windows login on SQL Server and db_owner in the legacy
         database - the rights the legacy site has as the database's owner. The database
         user has to be in the snapshot step 7 takes, or the first restore takes the
         mutant's access away: run this step before step 7. When the snapshot exists
         already, it must hold the user.
      6. Waits for the mutant's first answer, and checks from the nopCommerce log in the
         database that it was this site that started on that database.

    Run after step 6 and before step 7, elevated, on the legacy shop's host.

.PARAMETER Id
    The mutant, as mutants\mutants.json names it: M00 (the calibration) to M99.

.PARAMETER WorkRoot
    The legacy shop's work root (state\deploy.json). Default: $env:NOPBENCH_WORK, else
    C:\nopbench.

.PARAMETER MutantWorkRoot
    The work root the mutant was built in (its state\build.json and manifest). Default:
    $env:NOPBENCH_MUTANT_WORK, else a folder named nopmut beside the work root.

.PARAMETER SiteName
    IIS site and application pool name. Default: nopcommerce-mutant.

.PARAMETER Port
    HTTP port of the mutant. Default: 8091 (docs/TOPOLOGY.md lists every port).

.PARAMETER InstallDir
    Where IIS serves the mutant from. Default: C:\inetpub\<SiteName>. Replaced on every run.

.PARAMETER WarmupTimeoutSeconds
    How long the mutant may take to answer its first request. Default: 900.

.EXAMPLE
    .\scripts\mutants\2-deploy-mutant.ps1 -Id M01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^M[0-9]{2}$')][string] $Id,
    [string] $WorkRoot,
    [string] $MutantWorkRoot,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string] $SiteName = 'nopcommerce-mutant',
    [ValidateRange(1, 65535)][int] $Port = 8091,
    [string] $InstallDir,
    [int] $WarmupTimeoutSeconds = 900
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $scriptsRoot 'lib') 'NopBench.Common.ps1')

Assert-BenchAdministrator
$repoRoot = Split-Path -Parent $scriptsRoot
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
if (-not $MutantWorkRoot) { $MutantWorkRoot = $env:NOPBENCH_MUTANT_WORK }
if (-not $MutantWorkRoot) { $MutantWorkRoot = Join-Path (Split-Path -Parent $work) 'nopmut' }
$MutantWorkRoot = Get-BenchFullPath $MutantWorkRoot
if (-not $InstallDir) { $InstallDir = Join-Path $env:SystemDrive ('inetpub\{0}' -f $SiteName) }
$InstallDir = Get-BenchFullPath $InstallDir
$baseUrl = 'http://localhost:{0}/' -f $Port
$poolIdentity = 'IIS APPPOOL\{0}' -f $SiteName
$timings = [ordered]@{}
$clock = [System.Diagnostics.Stopwatch]::StartNew()

function Complete-Phase {
    param([string] $Name)
    $timings[$Name] = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Write-BenchLog ('{0} took {1} s' -f $Name, $timings[$Name])
    $clock.Restart()
}

# --- Inputs -------------------------------------------------------------------------
$deploy = Read-BenchState -WorkRoot $work -Name 'deploy'
if (-not $deploy) { throw ('No state\deploy.json in {0}: install the legacy shop first (steps 3 and 4), and configure it (step 6).' -f $work) }
if (-not (Read-BenchState -WorkRoot $work -Name 'store-config')) { throw 'No state\store-config.json: configure the legacy shop (step 6) before its mutant opens the same database.' }
if ($Port -eq [int] $deploy.port) { throw ('Port {0} is the legacy shop''s own.' -f $Port) }
if ($SiteName -eq $deploy.siteName) { throw ('{0} is the legacy shop''s own site name.' -f $SiteName) }
$legacySettings = Join-Path $deploy.installDir 'App_Data\Settings.txt'
$legacyPlugins = Join-Path $deploy.installDir 'App_Data\InstalledPlugins.txt'
foreach ($file in @($legacySettings, $legacyPlugins)) {
    if (-not (Test-Path -LiteralPath $file)) { throw ('{0} is missing: the legacy shop at {1} is not installed.' -f $file, $deploy.installDir) }
}

$catalog = Get-Content -LiteralPath (Join-Path (Join-Path $repoRoot 'mutants') 'mutants.json') -Raw | ConvertFrom-Json
$entry = @($catalog.mutants | Where-Object { $_.id -eq $Id })
if ($entry.Count -ne 1) { throw ('mutants\mutants.json has no mutant {0}.' -f $Id) }
$entry = $entry[0]

$build = Read-BenchState -WorkRoot $MutantWorkRoot -Name 'build'
if (-not $build) { throw ('No state\build.json in {0}: build the mutant first (scripts\2-build-legacy.ps1 -WorkRoot {0} -Patch ...).' -f $MutantWorkRoot) }
$siteDir = $build.siteDir
if (-not (Test-Path -LiteralPath (Join-Path $siteDir 'bin\Nop.Web.dll'))) { throw ('{0} is not a published nopCommerce site.' -f $siteDir) }

# --- 1. Integrity: the published files, and which mutant they are ------------------
Enter-BenchGroup ('Check the {0} build against its manifest and the mutant catalog' -f $Id)
if ($build.nopCommerce.commit -ne $pins.nopCommerce.commit) { throw ('The mutant was built from {0}, not the pinned {1}.' -f $build.nopCommerce.commit, $pins.nopCommerce.commit) }
$builtPatch = $null
if ($build.PSObject.Properties.Name -contains 'patch') { $builtPatch = $build.patch }
if ($null -eq $entry.patch) {
    if ($builtPatch) { throw ('{0} is built without a patch, but {1} was built with {2}.' -f $Id, $siteDir, $builtPatch.file) }
    Write-BenchLog ('{0}: no patch - the pinned source as it is, built like every mutant.' -f $Id)
}
else {
    $catalogPatch = Get-BenchSha256 (Join-Path (Join-Path $repoRoot 'mutants') $entry.patch)
    if (-not $builtPatch -or $builtPatch.sha256 -ne $catalogPatch) {
        $what = 'no patch'
        if ($builtPatch) { $what = '{0} ({1})' -f $builtPatch.file, $builtPatch.sha256 }
        throw ('{0} is mutants\{1} ({2}), but {3} was built with {4}.' -f $Id, $entry.patch, $catalogPatch, $siteDir, $what)
    }
    Write-BenchLog ('{0}: built with {1} (sha256 {2}), which changes {3}.' -f $Id, $entry.patch, $catalogPatch, ($builtPatch.files -join ', '))
}
$manifestPath = Join-Path (Join-Path $MutantWorkRoot 'state') $build.site.manifest
if (-not (Test-Path -LiteralPath $manifestPath)) { throw ('No manifest at {0}.' -f $manifestPath) }
$manifestDigest = Get-BenchSha256 $manifestPath
if ($manifestDigest -ne $build.site.manifestSha256) { throw ('{0} is not the manifest the build wrote.' -f $manifestPath) }
$expected = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ })
$mismatches = New-Object System.Collections.Generic.List[string]
foreach ($line in $expected) {
    $relative = $line.Substring(66)
    $file = Join-Path $siteDir ($relative.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $file)) { $mismatches.Add(('missing {0}' -f $relative)); continue }
    if ((Get-BenchSha256 $file) -ne $line.Substring(0, 64)) { $mismatches.Add(('changed {0}' -f $relative)) }
}
$actualCount = @(Get-ChildItem -LiteralPath $siteDir -Recurse -File).Count
if ($actualCount -ne $expected.Count) { $mismatches.Add(('{0} files on disk, {1} in the manifest' -f $actualCount, $expected.Count)) }
if ($mismatches.Count -gt 0) {
    $mismatches | Select-Object -First 20 | ForEach-Object { Write-BenchLog ('MISMATCH: {0}' -f $_) }
    throw ('{0} does not match {1} ({2} problem(s)).' -f $siteDir, $manifestPath, $mismatches.Count)
}
Write-BenchLog ('{0} files match the mutant''s build manifest (sha256 {1}).' -f $expected.Count, $manifestDigest)
Exit-BenchGroup
Complete-Phase 'verify'

# --- 2. Remove an earlier mutant deployment -----------------------------------------
Enter-BenchGroup ('Remove an earlier deployment of {0}' -f $SiteName)
if (@(Invoke-BenchAppCmd -Arguments @('list', 'site', ('/name:{0}' -f $SiteName), '/text:name') -AllowFailure) -contains $SiteName) {
    $null = Invoke-BenchAppCmd -Arguments @('delete', 'site', $SiteName)
    Write-BenchLog ('Deleted IIS site {0}' -f $SiteName)
}
if (@(Invoke-BenchAppCmd -Arguments @('list', 'apppool', ('/name:{0}' -f $SiteName), '/text:name') -AllowFailure) -contains $SiteName) {
    $null = Invoke-BenchAppCmd -Arguments @('delete', 'apppool', $SiteName)
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
Exit-BenchGroup

# --- 3 and 4. Files, settings, application pool, site --------------------------------
Enter-BenchGroup ('Deploy {0} to IIS: {1} on port {2}' -f $Id, $SiteName, $Port)
$null = Invoke-BenchAppCmd -Arguments @('add', 'apppool', ('/name:{0}' -f $SiteName), '/managedRuntimeVersion:v4.0', '/managedPipelineMode:Integrated')
$null = Invoke-BenchAppCmd -Arguments @(
    'set', 'apppool', $SiteName,
    '/processModel.identityType:ApplicationPoolIdentity',
    '/processModel.loadUserProfile:true',
    '/processModel.idleTimeout:00:00:00',
    '/recycling.periodicRestart.time:00:00:00',
    '/enable32BitAppOnWin64:false'
)
$null = New-Item -ItemType Directory -Force -Path $InstallDir
# Granted on the root before copying, so every copied file inherits it: nopCommerce writes
# App_Data, Plugins\bin and picture thumbnails at run time.
Invoke-BenchNative -FilePath (Join-Path $env:windir 'System32\icacls.exe') -ArgumentList @($InstallDir, '/grant', ('{0}:(OI)(CI)M' -f $poolIdentity), '/Q')
Invoke-BenchNative -FilePath (Join-Path $env:windir 'System32\robocopy.exe') -ArgumentList @($siteDir, $InstallDir, '/MIR', '/R:3', '/W:2', '/NFL', '/NDL', '/NP', '/NJH') -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7)
# The two files nopCommerce's installer wrote for the legacy site: which database it uses,
# and which plugins are installed in it. With them the mutant is an installed shop on the
# legacy shop's database - which is what makes both sides of the replay one system's state.
$appData = Join-Path $InstallDir 'App_Data'
Copy-Item -LiteralPath $legacySettings -Destination $appData -Force
Copy-Item -LiteralPath $legacyPlugins -Destination $appData -Force
Write-BenchLog ('Copied App_Data\Settings.txt and App_Data\InstalledPlugins.txt from {0}' -f $deploy.installDir)
$null = Invoke-BenchAppCmd -Arguments @('add', 'site', ('/name:{0}' -f $SiteName), ('/bindings:http/*:{0}:' -f $Port), ('/physicalPath:{0}' -f $InstallDir))
$null = Invoke-BenchAppCmd -Arguments @('set', 'app', ('{0}/' -f $SiteName), ('/applicationPool:{0}' -f $SiteName))
$siteState = "$(Invoke-BenchAppCmd -Arguments @('list', 'site', ('/name:{0}' -f $SiteName), '/text:state'))".Trim()
if ($siteState -ne 'Started') { $null = Invoke-BenchAppCmd -Arguments @('start', 'site', ('/site.name:{0}' -f $SiteName)) }
Write-BenchLog ('IIS site {0} ({1}) serves {2} as {3}' -f $SiteName, $baseUrl, $InstallDir, $poolIdentity)
Exit-BenchGroup
Complete-Phase 'deploy'

# --- 5. The pool identity's rights in the legacy database ---------------------------
Enter-BenchGroup ('SQL Server: {0} in {1}' -f $poolIdentity, $deploy.database)
$snapshot = '{0}_snapshot' -f $deploy.database
$snapshotExists = [int] (Invoke-BenchSqlScalar -Server $deploy.sqlServer -Query ("SELECT COUNT(*) FROM sys.databases WHERE name = N'{0}' AND source_database_id = DB_ID(N'{1}')" -f $snapshot, $deploy.database))
if ($snapshotExists -gt 0) {
    $inSnapshot = [int] (Invoke-BenchSqlScalar -Server $deploy.sqlServer -Database $snapshot -Query ("SELECT COUNT(*) FROM sys.database_principals WHERE name = N'{0}'" -f $poolIdentity))
    if ($inSnapshot -eq 0) {
        throw ('Snapshot {0} exists and has no user {1}: every restore would take the mutant''s access to the database away. Deploy the first mutant before step 7 takes the snapshot - reinstall with step 4, configure with step 6, then run this step.' -f $snapshot, $poolIdentity)
    }
    Write-BenchLog ('Snapshot {0} exists and already holds {1}.' -f $snapshot, $poolIdentity)
}
$grantLogin = @"
IF SUSER_ID(N'$poolIdentity') IS NULL CREATE LOGIN [$poolIdentity] FROM WINDOWS WITH DEFAULT_DATABASE = [master];
SELECT SUSER_ID(N'$poolIdentity');
"@
$null = Invoke-BenchSqlScalar -Server $deploy.sqlServer -Query $grantLogin
$grantUser = @"
IF USER_ID(N'$poolIdentity') IS NULL CREATE USER [$poolIdentity] FOR LOGIN [$poolIdentity];
ALTER ROLE [db_owner] ADD MEMBER [$poolIdentity];
SELECT IS_ROLEMEMBER(N'db_owner', N'$poolIdentity');
"@
$isOwner = [int] (Invoke-BenchSqlScalar -Server $deploy.sqlServer -Database $deploy.database -Query $grantUser)
if ($isOwner -ne 1) { throw ('{0} is not db_owner in {1}.' -f $poolIdentity, $deploy.database) }
Write-BenchLog ('Login and user [{0}] on {1}: db_owner in {2}' -f $poolIdentity, $deploy.sqlServer, $deploy.database)
Exit-BenchGroup

# --- 6. The mutant's first answer ---------------------------------------------------
Enter-BenchGroup ('Wait for {0} at {1}' -f $Id, $baseUrl)
$startsQuery = "SELECT COUNT(*) FROM dbo.[Log] WHERE ShortMessage = N'Application started'"
$startsBefore = [int] (Invoke-BenchSqlScalar -Server $deploy.sqlServer -Database $deploy.database -Query $startsQuery)
$client = New-BenchHttpClient -TimeoutSeconds $WarmupTimeoutSeconds
$deadline = (Get-Date).AddSeconds($WarmupTimeoutSeconds)
$last = 'no response yet'
$firstAnswer = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($true) {
        $answer = $null
        try { $answer = Invoke-BenchHttp -Client $client -Uri $baseUrl }
        catch { $last = $_.Exception.GetBaseException().Message }
        if ($answer) {
            if ($answer.StatusCode -eq 200) { break }
            # An uninstalled nopCommerce sends every visitor to its installer: the settings did
            # not reach the mutant, and waiting will not change that.
            if ($answer.StatusCode -eq 302 -and "$($answer.Location)" -match '(?i)/install') { throw ('{0} redirects to its installer ({1}): App_Data\Settings.txt did not take.' -f $baseUrl, $answer.Location) }
            $last = 'HTTP {0}' -f $answer.StatusCode
        }
        if ((Get-Date) -ge $deadline) { throw ('{0} did not answer 200 within {1} s (last: {2}).' -f $baseUrl, $WarmupTimeoutSeconds, $last) }
        Start-Sleep -Seconds 5
    }
}
finally {
    $client.Dispose()
}
$firstSeconds = [math]::Round($firstAnswer.Elapsed.TotalSeconds, 1)
if ($answer.Body -notmatch 'Powered by <a href="http://www.nopcommerce.com/">nopCommerce</a>') { throw ('{0} answered 200 without the nopCommerce footer.' -f $baseUrl) }
# nopCommerce logs "Application started" to its database when it starts: a new entry proves
# that the site which just started - the mutant; the legacy site has been running all along -
# is working on the legacy shop's database.
$startsAfter = [int] (Invoke-BenchSqlScalar -Server $deploy.sqlServer -Database $deploy.database -Query $startsQuery)
if ($startsAfter -le $startsBefore) { throw ('No new "Application started" entry in {0}: the site at {1} did not start on the legacy shop''s database.' -f $deploy.database, $baseUrl) }
Write-BenchLog ('{0} answered 200 after {1} s; "Application started" logged in {2} ({3} time(s) before, {4} now).' -f $baseUrl, $firstSeconds, $deploy.database, $startsBefore, $startsAfter)
Exit-BenchGroup
Complete-Phase 'firstAnswer'

# --- Records ------------------------------------------------------------------------
$patchRecord = $null
if ($builtPatch) { $patchRecord = [ordered]@{ file = $builtPatch.file; sha256 = $builtPatch.sha256; files = @($builtPatch.files) } }
Write-BenchState -WorkRoot $work -Name 'mutant-deploy' -Data ([ordered]@{
        id = $Id
        title = $entry.title
        patch = $patchRecord
        url = $baseUrl
        siteName = $SiteName
        appPool = $SiteName
        appPoolIdentity = $poolIdentity
        port = $Port
        installDir = $InstallDir
        sourceSiteDir = $siteDir
        siteManifestSha256 = $manifestDigest
        legacy = [ordered]@{ url = $deploy.url; installDir = $deploy.installDir; siteManifestSha256 = $deploy.siteManifestSha256 }
        sqlServer = $deploy.sqlServer
        database = $deploy.database
        databaseRole = 'db_owner'
        snapshot = [ordered]@{ name = $snapshot; existedBefore = ($snapshotExists -gt 0) }
        firstAnswerSeconds = $firstSeconds
        timingsSeconds = $timings
        deployedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$patchText = 'none: the pinned source as it is'
if ($patchRecord) { $patchText = '`{0}` (SHA-256 `{1}`): {2}' -f $patchRecord.file, $patchRecord.sha256, ($patchRecord.files -join ', ') }
Add-BenchSummary -Lines @(
    ('### Mutant {0} beside the legacy shop' -f $Id),
    '',
    '| | |',
    '|---|---|',
    ('| Mutant | {0}: {1} |' -f $Id, $entry.title),
    ('| Patch | {0} |' -f $patchText),
    ('| Site | {0} (IIS site `{1}`, identity `{2}`), site manifest `{3}` |' -f $baseUrl, $SiteName, $poolIdentity, $manifestDigest),
    ('| Database | the legacy shop''s `{0}` on `{1}` (db_owner), settings copied from `{2}` |' -f $deploy.database, $deploy.sqlServer, $deploy.installDir),
    ('| First answer | after {0} s, with "Application started" logged in `{1}` |' -f $firstSeconds, $deploy.database),
    ''
)

# The step succeeded; do not let the exit code of the last native command decide.
exit 0
