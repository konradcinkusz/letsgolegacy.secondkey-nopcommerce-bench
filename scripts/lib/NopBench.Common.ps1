# Shared helpers for the numbered runbook scripts in scripts/. Dot-source it; it only
# defines functions.
#
# Compatibility contract: Windows PowerShell 5.1 and PowerShell 7+. CI runs the scripts
# under Windows PowerShell 5.1 because that is the shell every Windows host already has.
# Keep this file (and every script) ASCII-only: Windows PowerShell 5.1 reads a script
# without a byte-order mark as ANSI, and a stray typographic dash changes its meaning.

function Test-BenchWindows {
    return ($env:OS -eq 'Windows_NT')
}

function Write-BenchLog {
    param([Parameter(Mandatory = $true)][string] $Message)
    Write-Host ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message)
}

function Enter-BenchGroup {
    param([Parameter(Mandatory = $true)][string] $Title)
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host ('::group::{0}' -f $Title) }
    else { Write-Host ('== {0}' -f $Title) }
}

function Exit-BenchGroup {
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host '::endgroup::' }
}

function Add-BenchSecretMask {
    # Registers a value with the GitHub Actions log masker. No-op outside Actions.
    param([string] $Value)
    if ($env:GITHUB_ACTIONS -eq 'true' -and $Value) { Write-Host ('::add-mask::{0}' -f $Value) }
}

function Add-BenchSummary {
    # Appends Markdown lines to the GitHub Actions job summary. No-op outside Actions.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]] $Lines)
    if ($env:GITHUB_STEP_SUMMARY) {
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, (($Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Get-BenchFullPath {
    # Resolves a path relative to the current PowerShell location, whether or not it exists.
    param([Parameter(Mandatory = $true)][string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Join-BenchPath {
    # Joins a base directory and a pins.json-style relative path ('src/Foo.sln') and
    # normalises the separators for the current platform.
    param(
        [Parameter(Mandatory = $true)][string] $Base,
        [Parameter(Mandatory = $true)][string] $Relative
    )
    $native = $Relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
    return [System.IO.Path]::GetFullPath((Join-Path $Base $native))
}

function Resolve-BenchWorkRoot {
    # Work root resolution order: explicit parameter, NOPBENCH_WORK, then a short default
    # outside the repository (C:\nopbench on Windows). Short matters: MSBuild's web publish
    # pipeline nests paths deeply and legacy tooling still trips over MAX_PATH (260).
    param([string] $WorkRoot)
    if (-not $WorkRoot) { $WorkRoot = $env:NOPBENCH_WORK }
    if (-not $WorkRoot) {
        if (Test-BenchWindows) { $WorkRoot = Join-Path $env:SystemDrive 'nopbench' }
        else { $WorkRoot = Join-Path $HOME 'nopbench' }
    }
    $full = Get-BenchFullPath $WorkRoot
    $null = New-Item -ItemType Directory -Force -Path $full
    return $full
}

function Read-BenchPinFile {
    param([Parameter(Mandatory = $true)][string] $RepoRoot)
    $path = Join-Path $RepoRoot 'pins.json'
    if (-not (Test-Path -LiteralPath $path)) { throw ('pins.json not found at {0}' -f $path) }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-BenchStatePath {
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][string] $Name
    )
    return (Join-Path (Join-Path $WorkRoot 'state') ('{0}.json' -f $Name))
}

function Write-BenchState {
    # Hand-off files: each step records what it produced so the next step does not have
    # to be told again (REPO-BASELINE.md section 4). Never write secrets here.
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)] $Data
    )
    $path = Get-BenchStatePath -WorkRoot $WorkRoot -Name $Name
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)
    $json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-BenchLog ('State written: {0}' -f $path)
}

function Read-BenchState {
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][string] $Name
    )
    $path = Get-BenchStatePath -WorkRoot $WorkRoot -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Assert-BenchCommand {
    param([Parameter(Mandatory = $true)][string] $Name, [string] $Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw ('Required command not found: {0}. {1}' -f $Name, $Hint)
    }
}

function Assert-BenchAdministrator {
    if (-not (Test-BenchWindows)) { throw 'This step needs Windows.' }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This step changes machine configuration and must run from an elevated (Administrator) PowerShell.'
    }
}

function Invoke-BenchNative {
    # Runs a native command, streams its output to the host and throws on an unexpected
    # exit code. The error preference is relaxed for the call because Windows PowerShell
    # 5.1 turns redirected native stderr into terminating errors under 'Stop'.
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [int[]] $SuccessExitCodes = @(0),
        [switch] $PassThru
    )
    Write-BenchLog ('> {0} {1}' -f $FilePath, ($ArgumentList -join ' '))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList | Out-Host
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($SuccessExitCodes -notcontains $code) {
        throw ('{0} exited with code {1}' -f (Split-Path -Leaf $FilePath), $code)
    }
    if ($PassThru) { return $code }
}

function Invoke-BenchGit {
    # Runs git and returns its stdout lines. stderr goes to the host.
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [switch] $AllowFailure,
        [int] $Attempts = 1
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & git @Arguments
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
        }
        if ($code -eq 0) { return $output }
        if ($attempt -lt $Attempts) {
            Write-BenchLog ('git {0} failed with exit code {1}; retrying' -f ($Arguments -join ' '), $code)
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    if ($AllowFailure) { return $null }
    throw ('git {0} failed with exit code {1}' -f ($Arguments -join ' '), $code)
}

function Test-BenchPinnedCheckout {
    # True when $Directory is a git checkout at $Commit with no tracked file modified.
    # Untracked files (bin, obj, the Plugins output folder) are build output and allowed.
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string] $Commit
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Directory '.git'))) { return $false }
    $head = Invoke-BenchGit -Arguments @('-C', $Directory, 'rev-parse', 'HEAD') -AllowFailure
    if ("$head".Trim() -ne $Commit) { return $false }
    $dirty = @(Invoke-BenchGit -Arguments @('-C', $Directory, 'status', '--porcelain', '--untracked-files=no') | Where-Object { $_ })
    if ($dirty.Count -gt 0) {
        Write-BenchLog ('Modified tracked files in {0}:' -f $Directory)
        $dirty | Select-Object -First 20 | ForEach-Object { Write-BenchLog ('  {0}' -f $_) }
        return $false
    }
    return $true
}

function Get-BenchSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# --- Patches (P9 mutants, docs/P9-MUTANTS.md) ------------------------------------------
# A mutant is a unified diff against the pinned checkout. nopCommerce keeps most of its
# sources with CRLF line endings, and so do the patches (.gitattributes); git apply is
# nevertheless told to ignore whitespace, so a patch whose line endings were converted on
# the way still applies - and still has to match every line it changes.

function Invoke-BenchPatchGit {
    # git -C <SourceDir> <arguments>; returns the exit code and sends every line git
    # writes, stderr included (which hunk failed, and where), to the log.
    param(
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $SourceDir @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    foreach ($line in $output) { if ("$line") { Write-BenchLog ('  git apply: {0}' -f $line) } }
    return $code
}

function Get-BenchPatchFile {
    # The files a patch changes (repository-relative, "/"-separated, ordinal order), read from
    # the patch itself; nothing is applied.
    param(
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string] $Patch
    )
    $lines = @(Invoke-BenchGit -Arguments @('-C', $SourceDir, 'apply', '--numstat', $Patch))
    $files = @($lines | Where-Object { "$_" } | ForEach-Object { ("$_" -split "`t", 3)[2] })
    if ($files.Count -eq 0) { throw ('{0} changes no file.' -f $Patch) }
    [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
    return , $files
}

function Get-BenchModifiedFile {
    # The tracked files that differ from HEAD in a checkout, in the same form as
    # Get-BenchPatchFile.
    param([Parameter(Mandatory = $true)][string] $SourceDir)
    $files = @(Invoke-BenchGit -Arguments @('-C', $SourceDir, 'diff', '--name-only', 'HEAD') | Where-Object { "$_" } | ForEach-Object { "$_" })
    [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
    return , $files
}

function Test-BenchPatch {
    # True when the patch applies to the checkout as it is; with -Reverse, when the checkout
    # holds the whole patch (it would come out again cleanly). Nothing is changed.
    param(
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string] $Patch,
        [switch] $Reverse
    )
    $arguments = @('apply', '--check', '--ignore-whitespace', '--whitespace=nowarn')
    if ($Reverse) { $arguments += '--reverse' }
    return ((Invoke-BenchPatchGit -SourceDir $SourceDir -Arguments ($arguments + @($Patch))) -eq 0)
}

function Add-BenchPatch {
    # Applies a patch to a clean checkout and checks that it changed exactly the files the
    # patch names. Throws, naming the patch, when it does not apply. Returns those files.
    param(
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string] $Patch
    )
    $files = Get-BenchPatchFile -SourceDir $SourceDir -Patch $Patch
    if (-not (Test-BenchPatch -SourceDir $SourceDir -Patch $Patch)) {
        throw ('{0} does not apply to the checkout at {1}: git apply --check refused it (the log above names the hunk). A patch is written against the pinned tree exactly as step 1 fetches it.' -f $Patch, $SourceDir)
    }
    if ((Invoke-BenchPatchGit -SourceDir $SourceDir -Arguments @('apply', '--ignore-whitespace', '--whitespace=nowarn', $Patch)) -ne 0) {
        throw ('git apply {0} failed after its check passed.' -f $Patch)
    }
    Assert-BenchPatchedTree -SourceDir $SourceDir -Patch $Patch -Files $files
    return , $files
}

function Assert-BenchPatchedTree {
    # The checkout holds exactly the patch: the modified files are the patch's files, and the
    # patch would come out again cleanly.
    param(
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string] $Patch,
        [Parameter(Mandatory = $true)][string[]] $Files
    )
    $modified = Get-BenchModifiedFile -SourceDir $SourceDir
    if (($modified -join "`n") -cne ($Files -join "`n")) {
        throw ('The checkout does not hold exactly {0}: modified [{1}], the patch changes [{2}].' -f $Patch, ($modified -join ', '), ($Files -join ', '))
    }
    if (-not (Test-BenchPatch -SourceDir $SourceDir -Patch $Patch -Reverse)) {
        throw ('The checkout no longer holds all of {0}.' -f $Patch)
    }
}

function Undo-BenchPatch {
    # Restores the files a patch changed from the checkout's own HEAD - whatever line endings
    # the patch was applied with - so the tree is the pinned one again.
    param(
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string[]] $Files
    )
    $null = Invoke-BenchGit -Arguments (@('-C', $SourceDir, 'checkout', 'HEAD', '--') + $Files)
}

function Get-BenchVerifiedDownload {
    # Downloads $Uri to $Destination unless a file with the pinned SHA-256 is already
    # there (for example restored from the CI cache). Nothing unverified is ever kept.
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $Sha256,
        [Parameter(Mandatory = $true)][string] $Destination
    )
    $expected = $Sha256.ToLowerInvariant()
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-BenchSha256 $Destination) -eq $expected) {
            Write-BenchLog ('Using {0} (sha256 verified)' -f $Destination)
            return $Destination
        }
        Write-BenchLog ('{0} does not match the pinned sha256; downloading it again' -f $Destination)
        Remove-Item -LiteralPath $Destination -Force
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination)
    $partial = '{0}.partial' -f $Destination
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-BenchLog ('Downloading {0} (attempt {1})' -f $Uri, $attempt)
            Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
            break
        }
        catch {
            if ($attempt -eq $maxAttempts) { throw }
            Write-BenchLog ('Download failed: {0}' -f $_.Exception.Message)
            Start-Sleep -Seconds (10 * $attempt)
        }
    }
    $actual = Get-BenchSha256 $partial
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $partial -Force
        throw ('sha256 mismatch for {0}: pinned {1}, downloaded {2}. The upstream file changed; do not update the pin without reviewing why.' -f $Uri, $expected, $actual)
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
    Write-BenchLog ('Downloaded and verified {0}' -f $Destination)
    return $Destination
}

function Expand-BenchZip {
    # A .nupkg is a zip file; Expand-Archive in Windows PowerShell 5.1 refuses any other
    # extension, so use the framework API directly.
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Destination
    )
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { $null = $_ }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $Destination)
}

function Get-BenchPinnedPackage {
    # Downloads, verifies and extracts a pinned NuGet package. Returns the extraction folder.
    param(
        [Parameter(Mandatory = $true)] $Package,
        [Parameter(Mandatory = $true)][string] $WorkRoot
    )
    $name = ('{0}.{1}' -f $Package.id, $Package.version).ToLowerInvariant()
    $nupkg = Join-Path (Join-Path $WorkRoot 'downloads') ('{0}.nupkg' -f $name)
    $folder = Join-Path (Join-Path $WorkRoot 'tools') $name
    $marker = Join-Path $folder '.sha256'
    $null = Get-BenchVerifiedDownload -Uri $Package.url -Sha256 $Package.sha256 -Destination $nupkg
    $current = $null
    if (Test-Path -LiteralPath $marker) { $current = (Get-Content -LiteralPath $marker -Raw).Trim() }
    if ($current -ne $Package.sha256.ToLowerInvariant()) {
        Write-BenchLog ('Extracting {0} to {1}' -f $name, $folder)
        Expand-BenchZip -Path $nupkg -Destination $folder
        [System.IO.File]::WriteAllText($marker, $Package.sha256.ToLowerInvariant())
    }
    return $folder
}

# --- IIS ----------------------------------------------------------------------------

function Invoke-BenchAppCmd {
    # appcmd.exe, which behaves the same under Windows PowerShell 5.1 and PowerShell 7
    # (unlike the WebAdministration module). It reports "not found" through its exit code;
    # callers that probe pass -AllowFailure and look at the output instead.
    param([Parameter(Mandatory = $true)][string[]] $Arguments, [switch] $AllowFailure)
    $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    if (-not (Test-Path -LiteralPath $appcmd)) { throw 'IIS is not installed (no appcmd.exe). Run scripts\3-install-iis-sql.ps1 first.' }
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

# --- HTTP ---------------------------------------------------------------------------
# System.Net.Http behaves the same on Windows PowerShell 5.1 and PowerShell 7, unlike
# Invoke-WebRequest (redirect handling and error behaviour differ between the two).

function New-BenchHttpClient {
    # A client that keeps cookies (the shop identifies a guest by cookie), never follows
    # redirects on its own (the installer's success signal is a redirect) and sends a
    # browser-like User-Agent (the shop treats known crawlers differently).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object; changes no system state.')]
    param([int] $TimeoutSeconds = 120)
    try { Add-Type -AssemblyName System.Net.Http } catch { $null = $_ }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $true
    $handler.CookieContainer = New-Object System.Net.CookieContainer
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) nopbench/1.0')
    return $client
}

function New-BenchFormFieldList {
    # An ordered list of form fields. A list rather than a dictionary because a form may
    # repeat a name (ASP.NET MVC renders a checkbox as the box plus a hidden "false").
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object; changes no system state.')]
    param([System.Collections.IDictionary] $From)
    $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
    if ($From) {
        foreach ($key in $From.Keys) {
            $pairs.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList ([string] $key), ([string] $From[$key])))
        }
    }
    return , $pairs
}

function Invoke-BenchHttp {
    # One request. Returns status, headers of interest, body and elapsed milliseconds;
    # throws only on transport failure (connection refused, timeout). A POST sends -Form (a
    # dictionary) or -FormPairs (New-BenchFormFieldList, Get-BenchForm) url-encoded.
    param(
        [Parameter(Mandatory = $true)] $Client,
        [Parameter(Mandatory = $true)][string] $Uri,
        [ValidateSet('GET', 'POST')][string] $Method = 'GET',
        [System.Collections.IDictionary] $Form,
        $FormPairs,
        [System.Collections.IDictionary] $Headers
    )
    if ($Method -eq 'POST') { $httpMethod = [System.Net.Http.HttpMethod]::Post } else { $httpMethod = [System.Net.Http.HttpMethod]::Get }
    $request = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Uri)
    if ($Method -eq 'POST') {
        if ($null -ne $FormPairs) { $pairs = $FormPairs } else { $pairs = New-BenchFormFieldList -From $Form }
        $request.Content = New-Object System.Net.Http.FormUrlEncodedContent -ArgumentList (, $pairs)
    }
    if ($Headers) {
        foreach ($name in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation([string] $name, [string] $Headers[$name]) }
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    }
    finally {
        $request.Dispose()
    }
    $location = $null
    if ($response.Headers.Location) { $location = $response.Headers.Location.ToString() }
    $contentType = $null
    $encoding = [System.Text.Encoding]::UTF8
    if ($response.Content.Headers.ContentType) {
        $contentType = $response.Content.Headers.ContentType.MediaType
        $charset = $response.Content.Headers.ContentType.CharSet
        if ($charset) { try { $encoding = [System.Text.Encoding]::GetEncoding($charset.Trim('"')) } catch { $null = $_ } }
    }
    $result = [pscustomobject]@{
        StatusCode  = [int] $response.StatusCode
        Location    = $location
        ContentType = $contentType
        Body        = $encoding.GetString($bytes)
        Length      = $bytes.Length
        Ms          = [int] $watch.ElapsedMilliseconds
    }
    $response.Dispose()
    return $result
}

function Wait-BenchHttp {
    # Polls $Uri until it answers with one of $ExpectStatus or the deadline passes. The
    # first request to a cold ASP.NET site compiles views and loads plugins, so a single
    # request can itself take minutes: the client timeout must be generous too.
    param(
        [Parameter(Mandatory = $true)] $Client,
        [Parameter(Mandatory = $true)][string] $Uri,
        [int[]] $ExpectStatus = @(200),
        [int] $TimeoutSeconds = 600,
        [int] $IntervalSeconds = 5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $last = 'no response yet'
    while ($true) {
        try {
            $response = Invoke-BenchHttp -Client $Client -Uri $Uri
            if ($ExpectStatus -contains $response.StatusCode) {
                Write-BenchLog ('{0} answered {1} after {2:N0} s' -f $Uri, $response.StatusCode, $watch.Elapsed.TotalSeconds)
                return $response
            }
            $last = 'HTTP {0}' -f $response.StatusCode
        }
        catch {
            $last = $_.Exception.GetBaseException().Message
        }
        if ((Get-Date) -ge $deadline) {
            throw ('{0} did not answer {1} within {2} s (last: {3})' -f $Uri, ($ExpectStatus -join '/'), $TimeoutSeconds, $last)
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

# --- SQL Server ---------------------------------------------------------------------

function Invoke-BenchSqlScalar {
    # Runs one statement as the current Windows identity and returns the first column of
    # the first row. Used for administration only (logins, drop/create checks).
    param(
        [Parameter(Mandatory = $true)][string] $Server,
        [Parameter(Mandatory = $true)][string] $Query,
        [string] $Database = 'master',
        [int] $TimeoutSeconds = 120
    )
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = $Database
    $builder['Integrated Security'] = $true
    $builder['Connect Timeout'] = 30
    $connection = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Dispose()
    }
}

function New-BenchDatabaseSnapshot {
    # A database snapshot of -Database named -Snapshot (default <Database>_snapshot), its
    # sparse files next to the database's data files - unless that snapshot exists already.
    # Snapshots exist in every SQL Server edition since 2016 SP1, Express included.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runbook helper: the calling step is the unit of confirmation.')]
    param(
        [Parameter(Mandatory = $true)][string] $Server,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_]+$')][string] $Database,
        [ValidatePattern('^[A-Za-z0-9_]*$')][string] $Snapshot
    )
    if (-not $Snapshot) { $Snapshot = '{0}_snapshot' -f $Database }
    $query = @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$Snapshot' AND source_database_id = DB_ID(N'$Database'))
    SELECT N'reused';
ELSE
BEGIN
    DECLARE @files nvarchar(max) = (
        SELECT STRING_AGG(N'(NAME = ' + QUOTENAME(name) + N', FILENAME = N''' + REPLACE(LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'\', REVERSE(physical_name)) + 1) + N'${Snapshot}_' + name + N'.ss', N'''', N'''''') + N''')', N', ')
        FROM sys.master_files WHERE database_id = DB_ID(N'$Database') AND type = 0);
    IF @files IS NULL THROW 50000, N'Database $Database was not found.', 1;
    DECLARE @sql nvarchar(max) = N'CREATE DATABASE ' + QUOTENAME(N'$Snapshot') + N' ON ' + @files + N' AS SNAPSHOT OF ' + QUOTENAME(N'$Database');
    EXEC (@sql);
    SELECT N'created';
END
"@
    $outcome = [string] (Invoke-BenchSqlScalar -Server $Server -Query $query -TimeoutSeconds 300)
    return [pscustomobject]@{ Snapshot = $Snapshot; Outcome = $outcome }
}

function Restore-BenchDatabaseSnapshot {
    # Reverts -Database to -Snapshot, as `sk replay`'s sqlServerSnapshot reset does, and returns
    # the milliseconds it took. Open connections to the database - the shop's included - are
    # rolled back and closed. Retried when another connection takes the single-user slot
    # between the two statements.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runbook helper: the calling step is the unit of confirmation.')]
    param(
        [Parameter(Mandatory = $true)][string] $Server,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_]+$')][string] $Database,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_]+$')][string] $Snapshot,
        [int] $Attempts = 3
    )
    $query = @"
ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [$Database] FROM DATABASE_SNAPSHOT = N'$Snapshot';
ALTER DATABASE [$Database] SET MULTI_USER;
SELECT N'restored';
"@
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $null = Invoke-BenchSqlScalar -Server $Server -Query $query -TimeoutSeconds 300
            return [int] $watch.ElapsedMilliseconds
        }
        catch {
            if ($attempt -eq $Attempts) { throw }
            Write-BenchLog ('Restoring {0} from {1} failed ({2}); trying again.' -f $Database, $Snapshot, $_.Exception.GetBaseException().Message)
            try { $null = Invoke-BenchSqlScalar -Server $Server -Query ("IF DB_ID(N'{0}') IS NOT NULL ALTER DATABASE [{0}] SET MULTI_USER;" -f $Database) } catch { $null = $_ }
            Start-Sleep -Seconds 2
        }
    }
}
