<#
.SYNOPSIS
    Warm-up step 1 (P3): fetch the pinned eShopModernizing, build and publish eShopLegacyMVC.

.DESCRIPTION
    The warm-up runs the whole Second Key chain on Microsoft's own sample legacy
    application before it is pointed at nopCommerce
    (docs/adr/0004-chain-tools-and-eshop-warmup.md). This step:

      1. fetches the commit pinned in pins.json (eShopModernizing) and checks that the
         checkout is exactly that commit;
      2. restores the eShopLegacyMVC project's NuGet packages (it uses PackageReference);
      3. builds and publishes it in Release with MSBuild (file-system web publish) against
         the .NET Framework reference assemblies pinned in pins.json - the project targets
         4.7.2 and its utility library 4.6.1, and the hosted images no longer carry the
         4.6.1 targeting pack (the same approach as docs/adr/0002);
      4. switches the published Web.config to the application's own mock data
         (appSettings UseMockData=true), so the catalog lives in memory and no database is
         needed. The source tree is not changed; step 1 re-checks that it is clean.

    Needs Windows with Visual Studio 2022 (or Build Tools 2022) including the web
    development workload, and git. No administrator rights are needed.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER SiteDir
    Where the published site goes. Default: <WorkRoot>\eshop-site. Its content is replaced.

.PARAMETER MSBuild
    Path to MSBuild.exe. Default: msbuild.exe on PATH, else located with vswhere.

.EXAMPLE
    .\scripts\eshop\1-build-eshop.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $SiteDir,
    [string] $MSBuild
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'NopBench.Common.ps1')

if (-not (Test-BenchWindows)) { throw 'eShopLegacyMVC builds with MSBuild for .NET Framework, on Windows.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$eshop = $pins.eShopModernizing
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$sourceDir = Join-Path $work 'eshop-src'
if ($SiteDir) { $SiteDir = Get-BenchFullPath $SiteDir } else { $SiteDir = Join-Path $work 'eshop-site' }
$logs = Join-Path $work 'logs'
$null = New-Item -ItemType Directory -Force -Path $logs
Assert-BenchCommand -Name 'git' -Hint 'Install Git for Windows.'

# --- Source -------------------------------------------------------------------------
Enter-BenchGroup ('Fetch eShopModernizing at {0}' -f $eshop.commit)
if (Test-BenchPinnedCheckout -Directory $sourceDir -Commit $eshop.commit) {
    Write-BenchLog ('Reusing verified checkout at {0}' -f $sourceDir)
}
else {
    if (Test-Path -LiteralPath $sourceDir) { Remove-Item -LiteralPath $sourceDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $sourceDir
    $null = Invoke-BenchGit -Arguments @('-C', $sourceDir, 'init', '--quiet')
    $null = Invoke-BenchGit -Arguments @('-C', $sourceDir, 'config', 'core.autocrlf', 'false')
    $null = Invoke-BenchGit -Arguments @('-C', $sourceDir, 'config', 'core.longpaths', 'true')
    $null = Invoke-BenchGit -Arguments @('-C', $sourceDir, 'remote', 'add', 'origin', $eshop.repository)
    # GitHub serves any commit by its id, so the pin needs no tag or branch that could move.
    $null = Invoke-BenchGit -Arguments @('-C', $sourceDir, 'fetch', '--quiet', '--depth', '1', 'origin', $eshop.commit) -Attempts 3
    $null = Invoke-BenchGit -Arguments @('-c', 'advice.detachedHead=false', '-C', $sourceDir, 'checkout', '--quiet', '--detach', 'FETCH_HEAD')
}
if (-not (Test-BenchPinnedCheckout -Directory $sourceDir -Commit $eshop.commit)) {
    throw ('{0} is not a clean checkout of {1}.' -f $sourceDir, $eshop.commit)
}
$webProject = Join-BenchPath -Base $sourceDir -Relative $eshop.webProject
Write-BenchLog ('Verified: {0} at {1}' -f $eshop.repository, $eshop.commit)
Exit-BenchGroup

# --- Tools --------------------------------------------------------------------------
Enter-BenchGroup 'MSBuild and the reference assemblies'
if ($MSBuild) { $msbuildExe = Get-BenchFullPath $MSBuild }
else {
    $msbuildExe = $null
    $onPath = Get-Command 'msbuild.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $msbuildExe = $onPath.Path }
    else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $msbuildExe = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        }
    }
    if (-not $msbuildExe) { throw 'MSBuild not found. Install Visual Studio 2022 or Build Tools 2022 with the web development workload, or pass -MSBuild.' }
}
$msbuildVersion = "$(& $msbuildExe -nologo -version | Select-Object -Last 1)".Trim()
Write-BenchLog ('MSBuild {0}: {1}' -f $msbuildVersion, $msbuildExe)

# One TargetFrameworkRootPath serves every project of the build, so both frameworks' reference
# assemblies are laid out under one root: <root>\.NETFramework\v4.6.1 and v4.7.2.
$frameworkRoot = Join-Path (Join-Path $work 'tools') 'eshop-reference-assemblies'
$frameworksDir = Join-Path $frameworkRoot '.NETFramework'
$null = New-Item -ItemType Directory -Force -Path $frameworksDir
foreach ($package in $eshop.referenceAssemblies) {
    $folder = Get-BenchPinnedPackage -Package $package -WorkRoot $work
    $source = Join-Path (Join-Path (Join-Path $folder 'build') '.NETFramework') $package.framework
    foreach ($required in @('mscorlib.dll', 'System.Web.dll', 'RedistList\FrameworkList.xml')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $required))) { throw ('{0} {1} does not contain {2}' -f $package.id, $package.version, $required) }
    }
    $target = Join-Path $frameworksDir $package.framework
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath $source -Destination $target -Recurse
    Write-BenchLog ('{0} {1} -> {2}' -f $package.id, $package.version, $target)
}
Exit-BenchGroup

$commonProperties = @(
    '/p:Configuration=Release',
    '/p:Platform=AnyCPU',
    ('/p:TargetFrameworkRootPath={0}' -f $frameworkRoot),
    '/p:ImportDirectoryBuildProps=false',
    '/p:ImportDirectoryBuildTargets=false'
)

# --- Restore, build, publish ---------------------------------------------------------
Enter-BenchGroup 'MSBuild: restore (PackageReference)'
Invoke-BenchNative -FilePath $msbuildExe -ArgumentList (@($webProject, '/nologo', '/t:Restore', '/v:minimal', ('/bl:{0}' -f (Join-Path $logs 'eshop-restore.binlog'))) + $commonProperties)
Exit-BenchGroup

Enter-BenchGroup 'MSBuild: build and publish eShopLegacyMVC (file system, Release)'
$publishArguments = @(
    $webProject, '/nologo', '/nr:false', '/v:minimal', '/clp:Summary;ForceNoAlign',
    '/p:DeployOnBuild=true',
    '/p:DeployDefaultTarget=WebPublish',
    '/p:WebPublishMethod=FileSystem',
    ('/p:PublishUrl={0}' -f $SiteDir),
    '/p:DeleteExistingFiles=true',
    ('/bl:{0}' -f (Join-Path $logs 'eshop-publish.binlog'))
) + $commonProperties
Invoke-BenchNative -FilePath $msbuildExe -ArgumentList $publishArguments
Exit-BenchGroup

# --- Verify, then switch to the mock catalog -------------------------------------------
Enter-BenchGroup 'Verify the published site'
$problems = New-Object System.Collections.Generic.List[string]
foreach ($relative in @('Global.asax', 'Web.config', 'bin\eShopLegacyMVC.dll', 'bin\eShopLegacy.Utilities.dll', 'bin\System.Web.Mvc.dll', 'bin\Autofac.dll', 'Views\Catalog\Index.cshtml', 'Pics\1.png')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SiteDir $relative))) { $problems.Add(('missing {0}' -f $relative)) }
}
$sourceFiles = @(Get-ChildItem -LiteralPath $SiteDir -Recurse -File | Where-Object { @('.cs', '.csproj') -contains $_.Extension.ToLowerInvariant() })
if ($sourceFiles.Count -gt 0) { $problems.Add(('{0} source files were published, e.g. {1}' -f $sourceFiles.Count, $sourceFiles[0].FullName)) }
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-BenchLog ('PROBLEM: {0}' -f $_) }
    throw ('The published site failed {0} check(s).' -f $problems.Count)
}
if (-not (Test-BenchPinnedCheckout -Directory $sourceDir -Commit $eshop.commit)) { throw 'The build modified tracked files in the eShopModernizing checkout.' }

$webConfigPath = Join-Path $SiteDir 'Web.config'
$webConfig = New-Object System.Xml.XmlDocument
$webConfig.PreserveWhitespace = $true
$webConfig.Load($webConfigPath)
$mock = $webConfig.SelectSingleNode("/configuration/appSettings/add[@key='UseMockData']")
if (-not $mock) { throw 'The published Web.config has no UseMockData setting; the pinned commit is not the one this step was written for.' }
$mock.SetAttribute('value', 'true')
if ($webConfig.SelectSingleNode("/configuration/system.web/compilation[@debug='true']")) { throw 'Web.config still has compilation debug="true": the Release transform was not applied.' }
$webConfig.Save($webConfigPath)
$fileCount = @(Get-ChildItem -LiteralPath $SiteDir -Recurse -File).Count
Write-BenchLog ('Site OK: {0} files; Web.config switched to UseMockData=true (in-memory catalog, no database).' -f $fileCount)
Exit-BenchGroup

Write-BenchState -WorkRoot $work -Name 'eshop-build' -Data ([ordered]@{
        repository = $eshop.repository
        commit = $eshop.commit
        project = $eshop.webProject
        siteDir = $SiteDir
        files = $fileCount
        useMockData = $true
        msbuild = $msbuildVersion
        referenceAssemblies = @($eshop.referenceAssemblies | ForEach-Object { '{0} {1}' -f $_.id, $_.version })
        builtAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

Add-BenchSummary -Lines @(
    '### Warm-up: eShopLegacyMVC build',
    '',
    '| | |',
    '|---|---|',
    ('| Source | `{0}` at `{1}` |' -f $eshop.repository, $eshop.commit),
    ('| MSBuild | {0} |' -f $msbuildVersion),
    ('| Published site | {0} files, `UseMockData=true` |' -f $fileCount),
    ''
)

# The step succeeded; do not let the exit code of the last native command decide.
exit 0
