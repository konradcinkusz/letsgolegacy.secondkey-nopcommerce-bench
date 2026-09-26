<#
.SYNOPSIS
    Warm-up step 3 (P3): record the scripted traffic through `sk capture` into a *.skcap.

.DESCRIPTION
    Starts the recording proxy in front of the IIS site (docs/TOPOLOGY.md: proxy
    http://127.0.0.1:8001/ -> site http://localhost:8081/), plays the scenarios of
    EShop.Scenarios.ps1 through it - each from a restarted application
    (Reset-EShop.ps1), each as its own session - then stops the proxy once it has written
    every exchange, and validates the file with `sk validate`.

    Every request of a scenario carries the header x-bench-scenario: <id>, which the proxy
    is told to use as the session key; so each scenario is one session in the capture and
    one scenario in the replay, and the verdict can be read back to the scenario list.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER Out
    The capture to write. Default: <WorkRoot>\eshop\traffic.skcap.

.PARAMETER ProxyUrl
    Where the recording proxy listens. Default: http://127.0.0.1:8001/.

.EXAMPLE
    .\scripts\eshop\3-record-eshop.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $Out,
    [string] $ProxyUrl = 'http://127.0.0.1:8001/'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'NopBench.Common.ps1')
. (Join-Path $libDir 'NopBench.Chain.ps1')
. (Join-Path $PSScriptRoot 'EShop.Scenarios.ps1')

$sessionKey = 'x-bench-scenario'
$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$deploy = Read-BenchState -WorkRoot $work -Name 'eshop-deploy'
if (-not $deploy) { throw 'No state\eshop-deploy.json: run scripts\eshop\2-deploy-eshop.ps1 first.' }
$outDir = Join-Path $work 'eshop'
if ($Out) { $Out = Get-BenchFullPath $Out } else { $Out = Join-Path $outDir 'traffic.skcap' }
$sk = Resolve-BenchChainTool -WorkRoot $work -Name 'secondkey'
$reset = Join-Path $PSScriptRoot 'Reset-EShop.ps1'
$scenarios = Get-EShopScenario

Enter-BenchGroup ('Start the recording proxy {0} -> {1}' -f $ProxyUrl, $deploy.url)
$logPath = Join-Path (Join-Path $work 'logs') 'eshop-capture.log'
$capture = Start-BenchCapture -Sk $sk -Listen $ProxyUrl.TrimEnd('/') -Target $deploy.url -Out $Out -SessionKey $sessionKey -LogPath $logPath
Exit-BenchGroup

$rows = New-Object System.Collections.Generic.List[object]
$sent = 0
try {
    foreach ($scenario in $scenarios) {
        Enter-BenchGroup ('{0}: {1}' -f $scenario.Id, $scenario.Title)
        & $reset -WorkRoot $work
        $session = New-BenchSession -BaseUrl $ProxyUrl -Scenario $scenario.Id -HeaderName $sessionKey
        try {
            & $scenario.Run $session
        }
        finally {
            $sent += $session.Requests
            $session.Client.Dispose()
        }
        $rows.Add([pscustomobject]@{
                id = $scenario.Id
                title = $scenario.Title
                requests = $session.Requests
                session = (Get-BenchSessionId -Key $sessionKey -Value $scenario.Id)
            })
        Exit-BenchGroup
    }
}
finally {
    Enter-BenchGroup 'Stop the recording proxy'
    Stop-BenchCapture -Process $capture -Out $Out -Expected $sent -LogPath $logPath
    Exit-BenchGroup
}

Enter-BenchGroup 'sk validate'
$null = Invoke-BenchChainTool -Tool $sk -Arguments @('validate', $Out)
Exit-BenchGroup

Write-BenchState -WorkRoot $work -Name 'eshop-traffic' -Data ([ordered]@{
        capture = $Out
        captureSha256 = (Get-BenchSha256 $Out)
        target = $deploy.url
        proxy = $ProxyUrl
        sessionKey = $sessionKey
        scenarios = $rows.Count
        exchanges = $sent
        scenarioList = $rows.ToArray()
        recordedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$summary = @('### Warm-up: recorded traffic', '', ('{0} scenarios, {1} exchanges, recorded through `sk capture` in front of {2}.' -f $rows.Count, $sent, $deploy.url), '', '| Scenario | Session id | Requests | What it does |', '|---|---|---|---|')
foreach ($row in $rows) { $summary += ('| {0} | `{1}` | {2} | {3} |' -f $row.id, $row.session, $row.requests, $row.title) }
$summary += ''
Add-BenchSummary -Lines $summary
Write-BenchLog ('Recorded {0} scenarios, {1} exchanges into {2}' -f $rows.Count, $sent, $Out)

exit 0
