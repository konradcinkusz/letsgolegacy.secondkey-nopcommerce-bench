<#
.SYNOPSIS
    Runbook step 2: restore, build and publish the pinned nopCommerce (Release) with MSBuild.

.DESCRIPTION
    Builds the checkout produced by step 1 without changing a single upstream file:

      1. refuses to build anything but a clean checkout of the pinned commit;
      2. restores packages.config packages with nuget.exe (nopCommerce 3.90 commits its
         packages folder, so on a healthy tree this verifies rather than downloads);
      3. builds the whole solution in Release against the .NET Framework 4.5.1 reference
         assemblies from the pinned NuGet package, passed to MSBuild as
         TargetFrameworkRootPath - current Visual Studio images no longer ship the 4.5.1
         targeting pack (docs/adr/0002);
      4. publishes Nop.Web the way upstream documents it (web publish, file system,
         Release), which carries the Plugins output and the Administration area along;
      5. checks the published site and re-checks that the source tree is still unmodified;
      6. writes a SHA-256 manifest of every published file and state\build.json.

    Needs Windows with Visual Studio 2022 (or Build Tools 2022) including the ASP.NET and
    web development workload, and git. No administrator rights are needed.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER SourceDir
    The step 1 checkout. Default: the one recorded in <WorkRoot>\state\fetch.json, else
    <WorkRoot>\legacy-src.

.PARAMETER SiteDir
    Where the published site goes. Default: <WorkRoot>\legacy-site. Its content is replaced.

.PARAMETER MSBuild
    Path to MSBuild.exe. Default: msbuild.exe on PATH, else located with vswhere.

.PARAMETER NuGet
    Path to nuget.exe. Default: nuget.exe on PATH, else the pinned NuGet.CommandLine package.

.EXAMPLE
    .\scripts\2-build-legacy.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $SourceDir,
    [string] $SiteDir,
    [string] $MSBuild,
    [string] $NuGet
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')

if (-not (Test-BenchWindows)) { throw 'The legacy build needs Windows (MSBuild for .NET Framework and the web publishing targets).' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repoRoot = Split-Path -Parent $PSScriptRoot
$pins = Read-BenchPinFile -RepoRoot $repoRoot
$nop = $pins.nopCommerce
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$logs = Join-Path $work 'logs'
$null = New-Item -ItemType Directory -Force -Path $logs
$timings = [ordered]@{}
$clock = [System.Diagnostics.Stopwatch]::StartNew()

function Complete-Phase {
    param([string] $Name)
    $timings[$Name] = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Write-BenchLog ('{0} took {1} s' -f $Name, $timings[$Name])
    $clock.Restart()
}

# --- Source -------------------------------------------------------------------------
if ($SourceDir) { $SourceDir = Get-BenchFullPath $SourceDir }
else {
    $fetch = Read-BenchState -WorkRoot $work -Name 'fetch'
    if ($fetch) { $SourceDir = $fetch.sourceDir } else { $SourceDir = Join-Path $work 'legacy-src' }
}
if ($SiteDir) { $SiteDir = Get-BenchFullPath $SiteDir } else { $SiteDir = Join-Path $work 'legacy-site' }
if ([System.IO.Path]::GetPathRoot($SiteDir).TrimEnd('\', '/') -eq $SiteDir.TrimEnd('\', '/')) {
    throw ('Refusing to publish into a drive root: {0}' -f $SiteDir)
}

Enter-BenchGroup 'Verify the source tree'
Assert-BenchCommand -Name 'git' -Hint 'Install Git for Windows.'
if (-not (Test-BenchPinnedCheckout -Directory $SourceDir -Commit $nop.commit)) {
    throw ('{0} is not a clean checkout of {1} ({2}). Run scripts\1-fetch-nopcommerce.ps1 first.' -f $SourceDir, $nop.tag, $nop.commit)
}
$solution = Join-BenchPath -Base $SourceDir -Relative $nop.solution
$webProject = Join-BenchPath -Base $SourceDir -Relative $nop.webProject
Write-BenchLog ('Building {0} at {1} from {2}' -f $nop.tag, $nop.commit, $SourceDir)
Exit-BenchGroup

# --- Tools --------------------------------------------------------------------------
Enter-BenchGroup 'Locate MSBuild and nuget.exe'
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
if (-not (Test-Path -LiteralPath $msbuildExe)) { throw ('MSBuild not found at {0}' -f $msbuildExe) }
$msbuildVersion = "$(& $msbuildExe -nologo -version | Select-Object -Last 1)".Trim()
Write-BenchLog ('MSBuild {0}: {1}' -f $msbuildVersion, $msbuildExe)

if ($NuGet) { $nugetExe = Get-BenchFullPath $NuGet }
else {
    $onPath = Get-Command 'nuget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $nugetExe = $onPath.Path }
    else {
        $nugetPackage = Get-BenchPinnedPackage -Package $pins.toolchain.nuget -WorkRoot $work
        $nugetExe = Join-Path (Join-Path $nugetPackage 'tools') 'NuGet.exe'
    }
}
if (-not (Test-Path -LiteralPath $nugetExe)) { throw ('nuget.exe not found at {0}' -f $nugetExe) }
$nugetVersion = "$(& $nugetExe help | Select-Object -First 1)".Replace('NuGet Version:', '').Trim()
Write-BenchLog ('NuGet {0}: {1}' -f $nugetVersion, $nugetExe)
Exit-BenchGroup

# --- Reference assemblies -----------------------------------------------------------
Enter-BenchGroup ('.NET Framework {0} reference assemblies' -f $nop.targetFrameworkVersion)
$refPackage = $pins.toolchain.referenceAssemblies
$refFolder = Get-BenchPinnedPackage -Package $refPackage -WorkRoot $work
# No trailing separator: MSBuild then resolves the framework folder with Path.Combine,
# and the argument survives Windows PowerShell 5.1's quoting even if the path has spaces.
$targetFrameworkRoot = Join-Path $refFolder 'build'
$frameworkFolder = Join-Path (Join-Path $targetFrameworkRoot '.NETFramework') $nop.targetFrameworkVersion
foreach ($required in @('mscorlib.dll', 'System.Web.dll', 'RedistList\FrameworkList.xml')) {
    if (-not (Test-Path -LiteralPath (Join-Path $frameworkFolder $required))) {
        throw ('{0} {1} does not contain {2}' -f $refPackage.id, $refPackage.version, $required)
    }
}
Write-BenchLog ('TargetFrameworkRootPath = {0}' -f $targetFrameworkRoot)
Exit-BenchGroup
Complete-Phase 'prepare'

# Properties shared by the build and the publish. ImportDirectoryBuild* keeps the build
# hermetic: nothing from a Directory.Build.props/targets above the checkout leaks in.
$commonProperties = @(
    '/p:Configuration=Release',
    ('/p:TargetFrameworkRootPath={0}' -f $targetFrameworkRoot),
    '/p:ImportDirectoryBuildProps=false',
    '/p:ImportDirectoryBuildTargets=false'
)

# --- Restore ------------------------------------------------------------------------
Enter-BenchGroup 'nuget restore (packages.config)'
Invoke-BenchNative -FilePath $nugetExe -ArgumentList @('restore', $solution, '-NonInteractive', '-MSBuildPath', (Split-Path -Parent $msbuildExe))
Exit-BenchGroup
Complete-Phase 'restore'

# --- Build --------------------------------------------------------------------------
Enter-BenchGroup 'MSBuild: solution, Release'
$buildLog = Join-Path $logs 'build.binlog'
$buildArguments = @($solution, '/nologo', '/m', '/nr:false', '/v:minimal', '/clp:Summary;ForceNoAlign', '/t:Build', '/p:Platform=Any CPU', ('/bl:{0}' -f $buildLog)) + $commonProperties
Invoke-BenchNative -FilePath $msbuildExe -ArgumentList $buildArguments
Exit-BenchGroup
Complete-Phase 'build'

# --- Publish ------------------------------------------------------------------------
Enter-BenchGroup 'MSBuild: publish Nop.Web (file system, Release)'
$publishLog = Join-Path $logs 'publish.binlog'
$publishArguments = @(
    $webProject, '/nologo', '/nr:false', '/v:minimal', '/clp:Summary;ForceNoAlign',
    '/p:Platform=AnyCPU',
    '/p:BuildProjectReferences=false',
    '/p:DeployOnBuild=true',
    '/p:DeployDefaultTarget=WebPublish',
    '/p:WebPublishMethod=FileSystem',
    ('/p:PublishUrl={0}' -f $SiteDir),
    '/p:DeleteExistingFiles=true',
    ('/bl:{0}' -f $publishLog)
) + $commonProperties
Invoke-BenchNative -FilePath $msbuildExe -ArgumentList $publishArguments
Exit-BenchGroup
Complete-Phase 'publish'

# --- Verify -------------------------------------------------------------------------
Enter-BenchGroup 'Verify the published site'
$problems = New-Object System.Collections.Generic.List[string]
$requiredFiles = @(
    'Global.asax', 'Web.config',
    'bin\Nop.Web.dll', 'bin\Nop.Admin.dll', 'bin\Nop.Core.dll', 'bin\Nop.Data.dll',
    'bin\Nop.Services.dll', 'bin\Nop.Web.Framework.dll',
    'Views\Home\Index.cshtml', 'Administration\Views\Home\Index.cshtml',
    'Themes\DefaultClean\theme.config',
    'App_Data\Install\SqlServer.StoredProcedures.sql', 'App_Data\Localization\defaultResources.nopres.xml',
    'Plugins\bin'
)
foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $SiteDir $relative))) { $problems.Add(('missing {0}' -f $relative)) }
}
foreach ($relative in @('App_Data\Settings.txt', 'App_Data\InstalledPlugins.txt')) {
    if (Test-Path -LiteralPath (Join-Path $SiteDir $relative)) { $problems.Add(('{0} must not be published (it would mark the site as installed)' -f $relative)) }
}
$sourceFiles = @(Get-ChildItem -LiteralPath $SiteDir -Recurse -File | Where-Object { @('.cs', '.csproj') -contains $_.Extension.ToLowerInvariant() })
if ($sourceFiles.Count -gt 0) { $problems.Add(('{0} source files were published, e.g. {1}' -f $sourceFiles.Count, $sourceFiles[0].FullName)) }
$webConfig = Get-Content -LiteralPath (Join-Path $SiteDir 'Web.config') -Raw -ErrorAction SilentlyContinue
if ($webConfig -and $webConfig -match 'debug="true"') { $problems.Add('Web.config still has compilation debug="true": the Release transform was not applied') }

# Every plugin project in the solution must arrive as a folder with its descriptor.
$pluginProjects = @(Get-ChildItem -LiteralPath (Join-BenchPath -Base $SourceDir -Relative $nop.pluginsDirectory) -Recurse -Filter '*.csproj')
$pluginFolders = @(Get-ChildItem -LiteralPath (Join-Path $SiteDir 'Plugins') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Description.txt') })
foreach ($folder in $pluginFolders) {
    if (@(Get-ChildItem -LiteralPath $folder.FullName -Filter 'Nop.Plugin.*.dll').Count -eq 0) { $problems.Add(('plugin folder {0} has no plugin assembly' -f $folder.Name)) }
}
if ($pluginFolders.Count -ne $pluginProjects.Count) {
    $problems.Add(('{0} plugin projects in the solution but {1} published plugin folders' -f $pluginProjects.Count, $pluginFolders.Count))
}
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-BenchLog ('PROBLEM: {0}' -f $_) }
    throw ('The published site failed {0} check(s).' -f $problems.Count)
}
Write-BenchLog ('Site OK: {0} plugins ({1})' -f $pluginFolders.Count, (($pluginFolders | ForEach-Object { $_.Name }) -join ', '))

# The build must not have changed upstream source either.
if (-not (Test-BenchPinnedCheckout -Directory $SourceDir -Commit $nop.commit)) {
    throw 'The build modified tracked files in the nopCommerce checkout.'
}
Write-BenchLog 'Source tree unchanged by the build.'
Exit-BenchGroup

# --- Manifest -----------------------------------------------------------------------
Enter-BenchGroup 'Manifest'
$siteRoot = (Get-Item -LiteralPath $SiteDir).FullName.TrimEnd('\')
$entries = New-Object System.Collections.Generic.List[string]
$totalBytes = [long] 0
foreach ($file in Get-ChildItem -LiteralPath $siteRoot -Recurse -File) {
    $relative = $file.FullName.Substring($siteRoot.Length + 1).Replace('\', '/')
    $entries.Add(('{0}  {1}' -f (Get-BenchSha256 $file.FullName), $relative))
    $totalBytes += $file.Length
}
# Ordinal sort: the manifest must not depend on the culture of the machine that wrote it.
$sorted = $entries.ToArray()
[System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
$manifestPath = Join-Path (Join-Path $work 'state') 'legacy-site.sha256'
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath)
[System.IO.File]::WriteAllText($manifestPath, (($sorted -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$siteDigest = Get-BenchSha256 $manifestPath
Write-BenchLog ('{0} files, {1:N1} MB, manifest sha256 {2}' -f $sorted.Count, ($totalBytes / 1MB), $siteDigest)
Exit-BenchGroup
Complete-Phase 'verify'

Write-BenchState -WorkRoot $work -Name 'build' -Data ([ordered]@{
        nopCommerce = [ordered]@{ repository = $nop.repository; tag = $nop.tag; commit = $nop.commit }
        configuration = 'Release'
        siteDir = $SiteDir
        site = [ordered]@{ files = $sorted.Count; bytes = $totalBytes; plugins = $pluginFolders.Count; manifest = 'legacy-site.sha256'; manifestSha256 = $siteDigest }
        toolchain = [ordered]@{
            msbuild = $msbuildVersion
            nuget = $nugetVersion
            referenceAssemblies = ('{0} {1}' -f $refPackage.id, $refPackage.version)
            targetFrameworkRootPath = $targetFrameworkRoot
        }
        host = [ordered]@{ os = [System.Environment]::OSVersion.VersionString; image = ('{0} {1}' -f $env:ImageOS, $env:ImageVersion).Trim() }
        timingsSeconds = $timings
        builtAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })
