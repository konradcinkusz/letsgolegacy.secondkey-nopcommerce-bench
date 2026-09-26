<#
.SYNOPSIS
    Runbook step 7 (P4): record the nopCommerce traffic set through `sk capture` into a
    *.skcap, every scenario from the same database snapshot.

.DESCRIPTION
    docs/P4-TRAFFIC-PLAN.md, section 1:

      1. Takes a SQL Server database snapshot of the configured store (after step 6), unless
         one exists: the state every scenario starts from, when recording and on both sides
         of every replay (`sk replay` restores the same snapshot, contract/secondkey.yaml).
      2. Starts the recording proxy in front of the IIS site (docs/TOPOLOGY.md: proxy
         http://127.0.0.1:8000/ -> site http://localhost:8080/).
      3. For each scenario of traffic/NopCommerce.Scenarios.ps1: restores the snapshot, then
         plays the scenario through the proxy as one browser session whose every request
         carries x-bench-scenario: <id> - the capture's session key, so one scenario is one
         session in the capture and one scenario in the replay.
      4. Stops the proxy once it has written every exchange sent, and validates the file.

    What was recorded - scenarios, requests, session ids, the site's manifest digest - goes
    to state\traffic.json and the job summary.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER Out
    Default: <WorkRoot>\traffic\nopcommerce.skcap.

.PARAMETER ProxyUrl
    Where the recording proxy listens. Default: http://127.0.0.1:8000/.

.PARAMETER Only
    Scenario ids to record (default: all). For working on one scenario; a recording of part
    of the set is not the traffic set.

.EXAMPLE
    .\scripts\7-record-traffic.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Out,
    [string] $ProxyUrl = 'http://127.0.0.1:8000/',
    [string[]] $Only = @()
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Chain.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Shop.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'traffic') 'NopCommerce.Scenarios.ps1')

$sessionKey = 'x-bench-scenario'
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$deploy = Read-BenchState -WorkRoot $work -Name 'deploy'
if (-not $deploy) { throw 'No state\deploy.json: run scripts\4-deploy-and-install.ps1 first.' }
if (-not (Read-BenchState -WorkRoot $work -Name 'store-config')) { throw 'No state\store-config.json: run scripts\6-configure-store.ps1 first; without it every tax and shipping amount is $0.00.' }
$outDir = Join-Path $work 'traffic'
if ($Out) { $Out = Get-BenchFullPath $Out } else { $Out = Join-Path $outDir 'nopcommerce.skcap' }
$sk = Resolve-BenchChainTool -WorkRoot $work -Name 'secondkey'
$scenarios = Get-NopScenario
if ($Only.Count -gt 0) { $scenarios = @($scenarios | Where-Object { $Only -contains $_.Id }) }
if ($scenarios.Count -eq 0) { throw 'No scenario to record.' }

# --- 1. The snapshot every scenario starts from ------------------------------------------
Enter-BenchGroup 'Database snapshot of the configured store'
$snapshot = New-BenchDatabaseSnapshot -Server $deploy.sqlServer -Database $deploy.database
Write-BenchLog ('Snapshot [{0}] of [{1}] on {2}: {3}' -f $snapshot.Snapshot, $deploy.database, $deploy.sqlServer, $snapshot.Outcome)
Exit-BenchGroup

# --- 2-4. Record -------------------------------------------------------------------------
Enter-BenchGroup ('Start the recording proxy {0} -> {1}' -f $ProxyUrl, $deploy.url)
$logPath = Join-Path (Join-Path $work 'logs') 'traffic-capture.log'
$capture = Start-BenchCapture -Sk $sk -Listen $ProxyUrl.TrimEnd('/') -Target $deploy.url -Out $Out -SessionKey $sessionKey -LogPath $logPath
Exit-BenchGroup

$warm = New-BenchHttpClient -TimeoutSeconds 300
$rows = New-Object System.Collections.Generic.List[object]
$failed = New-Object System.Collections.Generic.List[string]
$firstAnswers = New-Object System.Collections.Generic.List[string]
$sent = 0
$watch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    foreach ($scenario in $scenarios) {
        Enter-BenchGroup ('{0} ({1}, {2}): {3}' -f $scenario.Id, $scenario.Area, $scenario.Persona, $scenario.Title)
        $session = $null
        try {
            $restore = Restore-BenchDatabaseSnapshot -Server $deploy.sqlServer -Database $deploy.database -Snapshot $snapshot.Snapshot
            # Straight to the site, not through the proxy: whether the first request after a
            # restore is answered at once tells whether a replay can restore and go (sk
            # replay's reset does not wait). Not recorded. Anything but an immediate 200 is
            # reported, and waited out for up to two minutes so the scenario still records.
            $answers = New-Object System.Collections.Generic.List[string]
            $deadline = (Get-Date).AddSeconds(120)
            $ready = $false
            $firstMs = 0
            while (-not $ready) {
                try {
                    $first = Invoke-BenchHttp -Client $warm -Uri $deploy.url
                    $answers.Add([string] $first.StatusCode)
                    if ($answers.Count -eq 1) { $firstMs = $first.Ms }
                    $ready = $first.StatusCode -eq 200
                }
                catch { $answers.Add('no answer') }
                if (-not $ready) {
                    if ((Get-Date) -ge $deadline) { throw ('The shop does not answer after the snapshot was restored: {0}.' -f ($answers -join ', ')) }
                    Start-Sleep -Seconds 2
                }
            }
            if ($answers.Count -gt 1) { Write-Host ('::warning::{0}: after the snapshot was restored the shop answered {1} before it answered 200.' -f $scenario.Id, (@($answers | Select-Object -First ($answers.Count - 1)) -join ', ')) }
            $firstAnswers.Add(('{0}: {1}' -f $scenario.Id, ($answers -join ', ')))
            Write-BenchLog ('  restored in {0} ms; first requests after it: {1} (first in {2} ms)' -f $restore, ($answers -join ', '), $firstMs)

            $session = New-BenchSession -BaseUrl $ProxyUrl -Scenario $scenario.Id -HeaderName $sessionKey
            & $scenario.Run $session $scenario.Data
            $rows.Add([pscustomobject]@{
                    id = $scenario.Id
                    area = $scenario.Area
                    persona = $scenario.Persona
                    title = $scenario.Title
                    requests = $session.Requests
                    session = (Get-BenchSessionId -Key $sessionKey -Value $scenario.Id)
                })
        }
        catch {
            # The next scenario still runs, so one recording shows every scenario that does
            # not reach what it exercises; the step fails at the end. The shop's own log goes
            # with the error: the next restore erases it.
            $failed.Add(('{0}: {1}' -f $scenario.Id, $_.Exception.Message))
            Write-Host ('::error::{0}: {1}' -f $scenario.Id, $_.Exception.Message)
            try {
                $recent = Invoke-BenchSqlScalar -Server $deploy.sqlServer -Database $deploy.database -Query "SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(CONVERT(nvarchar(30), CreatedOnUtc, 126), N' | ', ShortMessage, N' | ', PageUrl, N' | ', LEFT(FullMessage, 1200))), NCHAR(10)) FROM (SELECT TOP (5) * FROM dbo.[Log] ORDER BY Id DESC) AS recent"
                if ($recent -is [string] -and $recent) { Write-BenchLog ('  nopCommerce log, newest first:{0}{1}' -f [Environment]::NewLine, $recent) }
            }
            catch { Write-BenchLog ('  (the nopCommerce log could not be read: {0})' -f $_.Exception.Message) }
        }
        finally {
            if ($session) {
                $sent += $session.Requests
                $session.Client.Dispose()
            }
            Exit-BenchGroup
        }
    }
}
finally {
    $warm.Dispose()
    Enter-BenchGroup 'Stop the recording proxy'
    Stop-BenchCapture -Process $capture -Out $Out -Expected $sent -LogPath $logPath
    Exit-BenchGroup
}
$seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
if ($failed.Count -gt 0) {
    Add-BenchSummary -Lines (@('### nopCommerce traffic set (P4): not recorded', '', ('{0} of {1} scenarios did not reach what they exercise:' -f $failed.Count, $scenarios.Count), '') + @($failed | ForEach-Object { '- ' + $_ }) + @(''))
    throw ('{0} scenario(s) failed: {1}' -f $failed.Count, (($failed | ForEach-Object { $_.Split(':')[0] }) -join ', '))
}

Enter-BenchGroup 'sk validate'
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $Out)
Exit-BenchGroup

$partial = $Only.Count -gt 0
Write-BenchState -WorkRoot $work -Name 'traffic' -Data ([ordered]@{
        capture = $Out
        captureSha256 = (Get-BenchSha256 $Out)
        target = $deploy.url
        proxy = $ProxyUrl
        sessionKey = $sessionKey
        partial = $partial
        scenarios = $rows.Count
        exchanges = $sent
        seconds = $seconds
        database = $deploy.database
        snapshot = $snapshot.Snapshot
        firstAnswersAfterRestore = $firstAnswers.ToArray()
        siteManifestSha256 = $deploy.siteManifestSha256
        scenarioList = $rows.ToArray()
        recordedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$summary = @(
    '### nopCommerce traffic set (P4)',
    '',
    ('**{0} scenarios, {1} exchanges** recorded through `sk capture` in front of {2}, in {3} s; every scenario from snapshot `{4}`. Site manifest `{5}`.' -f $rows.Count, $sent, $deploy.url, $seconds, $snapshot.Snapshot, $deploy.siteManifestSha256),
    '',
    '| Scenario | Area | Persona | Requests | Session id | What it exercises |',
    '|---|---|---|---|---|---|'
)
foreach ($row in $rows) { $summary += ('| {0} | {1} | {2} | {3} | `{4}` | {5} |' -f $row.id, $row.area, $row.persona, $row.requests, $row.session, $row.title) }
$retried = @($firstAnswers | Where-Object { $_ -notmatch ': 200$' })
$summary += ''
if ($retried.Count -eq 0) { $summary += ('The first request after each of the {0} restores was answered 200.' -f $firstAnswers.Count) }
else { $summary += ('First requests after a restore that were not answered 200 at once: {0}.' -f ($retried -join '; ')) }
if ($partial) { $summary += ''; $summary += ('Partial recording (-Only {0}): not the traffic set.' -f ($Only -join ', ')) }
$summary += ''
Add-BenchSummary -Lines $summary
Write-BenchLog ('Recorded {0} scenarios, {1} exchanges into {2} in {3} s' -f $rows.Count, $sent, $Out, $seconds)

exit 0
