<#
.SYNOPSIS
    Runbook step 5: prove the legacy shop answers - home, category, product and cart.

.DESCRIPTION
    Plain HTTP against the running shop, as one guest customer (one cookie jar):

      home      GET  /                                      200, sample-data home page
      category  GET  /desktops                              200, category name and a product in it
      product   GET  /lenovo-ideacentre-600-all-in-one-pc   200, name, SKU and price; product id read from the page
      add       POST /addproducttocart/catalog/{id}/1/1     200, JSON success = true
      cart      GET  /cart                                  200, the product is in the cart

    Every page must also carry nopCommerce's "Powered by nopCommerce" footer: it proves
    the response came from nopCommerce, and its licence requires it on every page.

    Each check asserts its status code and its content unconditionally; a check that
    cannot find what it looks for fails, it is never skipped. The results go to the
    console, state\smoke.json and the CI job summary. Works from any machine that can
    reach the shop (no administrator rights needed).

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER BaseUrl
    Default: the URL recorded in state\deploy.json, else http://localhost:8080/.

.PARAMETER WarmupTimeoutSeconds
    How long the home page may take to answer the first time. Default: 600.

.EXAMPLE
    .\scripts\5-smoke.ps1

.EXAMPLE
    .\scripts\5-smoke.ps1 -BaseUrl http://legacy-vm:8080/
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $BaseUrl,
    [int] $WarmupTimeoutSeconds = 600
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')

$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
if (-not $BaseUrl) {
    $deploy = Read-BenchState -WorkRoot $work -Name 'deploy'
    if ($deploy) { $BaseUrl = $deploy.url } else { $BaseUrl = 'http://localhost:8080/' }
}
if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }

# Sample data installed by nopCommerce 3.90 (Nop.Services\Installation\CodeFirstInstallationService.cs):
# category "Desktops"; product "Lenovo IdeaCentre 600 All-in-One PC", SKU LE_IC_600,
# price 500, simple product, minimum order quantity 1 (so it can be added from a list).
$categorySlug = 'desktops'
$categoryName = 'Desktops'
$productSlug = 'lenovo-ideacentre-600-all-in-one-pc'
$productName = 'Lenovo IdeaCentre 600 All-in-One PC'
$productSku = 'LE_IC_600'
$productPrice = '$500.00'
$poweredBy = 'Powered by <a href="http://www.nopcommerce.com/">nopCommerce</a>'

$client = New-BenchHttpClient -TimeoutSeconds ([math]::Max($WarmupTimeoutSeconds, 120))
$results = New-Object System.Collections.Generic.List[object]

function Test-Page {
    # Runs one request and its assertions; records a result instead of throwing so that
    # every check is reported even when an earlier one fails.
    param(
        [string] $Name,
        [string] $Path,
        [string] $Method = 'GET',
        [string[]] $MustContain = @(),
        [string[]] $MustNotContain = @(),
        [switch] $Html
    )
    $uri = $BaseUrl + $Path
    $failures = New-Object System.Collections.Generic.List[string]
    $response = $null
    try {
        $response = Invoke-BenchHttp -Client $client -Uri $uri -Method $Method
        if ($response.StatusCode -ne 200) { $failures.Add(('status {0}, expected 200 (Location: {1})' -f $response.StatusCode, $response.Location)) }
        $expected = @($MustContain)
        if ($Html) { $expected += $poweredBy }
        foreach ($text in $expected) {
            if ($response.Body.IndexOf($text, [System.StringComparison]::Ordinal) -lt 0) { $failures.Add(('missing "{0}"' -f $text)) }
        }
        foreach ($text in $MustNotContain) {
            if ($response.Body.IndexOf($text, [System.StringComparison]::Ordinal) -ge 0) { $failures.Add(('unexpected "{0}"' -f $text)) }
        }
    }
    catch {
        $failures.Add(('request failed: {0}' -f $_.Exception.GetBaseException().Message))
    }
    $status = $null
    $ms = $null
    if ($response) { $status = $response.StatusCode; $ms = $response.Ms }
    $passed = ($failures.Count -eq 0)
    $results.Add([pscustomobject]@{
            check  = $Name
            method = $Method
            path   = '/' + $Path
            status = $status
            ms     = $ms
            passed = $passed
            detail = ($failures -join '; ')
        })
    if ($passed) { Write-BenchLog ('PASS {0,-9} {1} /{2} -> {3} in {4} ms' -f $Name, $Method, $Path, $status, $ms) }
    else { Write-BenchLog ('FAIL {0,-9} {1} /{2} -> {3}' -f $Name, $Method, $Path, ($failures -join '; ')) }
    return $response
}

Enter-BenchGroup ('Smoke test {0}' -f $BaseUrl)
# The first request after a start compiles views and loads plugins; wait for it before
# timing anything.
$null = Wait-BenchHttp -Client $client -Uri $BaseUrl -TimeoutSeconds $WarmupTimeoutSeconds

$null = Test-Page -Name 'home' -Path '' -Html -MustContain @('Welcome to our store')
$null = Test-Page -Name 'category' -Path $categorySlug -Html -MustContain @(('<h1>{0}</h1>' -f $categoryName), $productName)
$product = Test-Page -Name 'product' -Path $productSlug -Html -MustContain @($productName, $productSku, $productPrice)

$productId = $null
if ($product -and $product.StatusCode -eq 200) {
    $match = [regex]::Match($product.Body, 'itemtype="http://schema\.org/Product" data-productid="(\d+)"')
    if ($match.Success) { $productId = $match.Groups[1].Value }
}
if ($productId) {
    Write-BenchLog ('{0} has product id {1}' -f $productName, $productId)
    $added = Test-Page -Name 'add' -Path ('addproducttocart/catalog/{0}/1/1' -f $productId) -Method 'POST' -MustContain @('"success":true')
    if ($added -and $added.StatusCode -eq 200) { Write-BenchLog ('add-to-cart answered: {0}' -f $added.Body.Substring(0, [math]::Min(160, $added.Body.Length))) }
}
else {
    $results.Add([pscustomobject]@{ check = 'add'; method = 'POST'; path = '/addproducttocart/catalog/{id}/1/1'; status = $null; ms = $null; passed = $false; detail = 'no product id found on the product page' })
    Write-BenchLog 'FAIL add       no product id found on the product page'
}
$null = Test-Page -Name 'cart' -Path 'cart' -Html -MustContain @('<h1>Shopping cart</h1>', $productName) -MustNotContain @('Your Shopping Cart is empty!')
Exit-BenchGroup

$failed = @($results | Where-Object { -not $_.passed })
Write-BenchState -WorkRoot $work -Name 'smoke' -Data ([ordered]@{
        baseUrl = $BaseUrl
        passed = ($failed.Count -eq 0)
        checks = $results.ToArray()
        ranAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$summary = @('### Legacy smoke test', '', ('Base URL: {0}' -f $BaseUrl), '', '| Check | Request | Status | ms | Result |', '|---|---|---|---|---|')
foreach ($r in $results) {
    $verdict = 'pass'
    if (-not $r.passed) { $verdict = 'FAIL: ' + $r.detail }
    $summary += ('| {0} | `{1} {2}` | {3} | {4} | {5} |' -f $r.check, $r.method, $r.path, $r.status, $r.ms, $verdict)
}
$summary += ''
Add-BenchSummary -Lines $summary

if ($failed.Count -gt 0) { throw ('{0} of {1} smoke checks failed.' -f $failed.Count, $results.Count) }
Write-BenchLog ('All {0} smoke checks passed against {1}' -f $results.Count, $BaseUrl)

# The step succeeded; do not let the exit code of the last native command decide.
exit 0
