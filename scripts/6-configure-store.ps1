<#
.SYNOPSIS
    Runbook step 6 (P4): configure the sample store the way the traffic plan needs it -
    taxes, shipping, discounts, catalog - through nopCommerce's own admin UI.

.DESCRIPTION
    The installer's sample data leaves the rules the traffic set is about switched off:
    every tax rate reads 0, every shipping rate reads 0, and neither sample coupon changes
    a price (docs/P4-TRAFFIC-PLAN.md section 2). This step signs in as the administrator
    step 4 created and applies section 2 of the plan through the same admin pages and
    AJAX endpoints a person clicks through - seeding through the running system, never
    through SQL:

      tax        "Fixed or by country/state/zip" switched to country/state/zip; five rates
                 for Electronics & Software (US/NY/10001 9%, US/NY/* 8.875%, US/CA 7.25%,
                 US/* 5%, CA/ON/K1A 0B1 13%); "Apple MacBook Pro 13-inch" tax exempt
      shipping   fixed rates Ground $10, 2nd Day Air $25, Next Day Air $40; free shipping
                 over $1,000.00 excluding tax
      discounts  SAVE10, TAKE50, PCT20MAX100, SHIPFREE, ONCE5, FUTURE10, MEMBERS15 (the
                 last with the requirement "customer role is Registered")
      catalog    "HP Envy 6-1180ca 15.6-Inch Sleekbook" unpublished, and the catalog
                 setting that lets visitors open unpublished product pages switched off;
                 stock of "Lenovo IdeaCentre 600 All-in-One PC" set to 3
      tasks      every schedule task disabled and the application restarted: a task
                 that runs under a database restore takes the worker process down

    Every change is read back from the admin UI afterwards, and a product or settings form
    that is posted back is re-read and compared field by field, so a field the script did
    not mean to touch cannot change unnoticed. The requests go straight to the site, not
    through the recording proxy: configuration is not traffic, and the administrator's
    password must never reach a recording.

    Run once, after step 4 and before step 7. Needs the administrator credentials step 4
    wrote to <WorkRoot>\secrets\legacy-admin.json.

.PARAMETER WorkRoot
    Default: $env:NOPBENCH_WORK, else C:\nopbench.

.PARAMETER BaseUrl
    Default: the URL recorded in state\deploy.json, else http://localhost:8080/.

.EXAMPLE
    .\scripts\6-configure-store.ps1
#>
[CmdletBinding()]
param(
    [string] $WorkRoot,
    [string] $BaseUrl
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Common.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'NopBench.Chain.ps1')

$work = Resolve-BenchWorkRoot -WorkRoot $WorkRoot
$deploy = Read-BenchState -WorkRoot $work -Name 'deploy'
if (-not $BaseUrl) {
    if ($deploy) { $BaseUrl = $deploy.url } else { $BaseUrl = 'http://localhost:8080/' }
}
$secretsFile = Join-Path (Join-Path $work 'secrets') 'legacy-admin.json'
if (-not (Test-Path -LiteralPath $secretsFile)) { throw ('No administrator credentials at {0}: run scripts\4-deploy-and-install.ps1 first.' -f $secretsFile) }
$admin = Get-Content -LiteralPath $secretsFile -Raw | ConvertFrom-Json
Add-BenchSecretMask $admin.password

# One administrator session, straight to the site. The scenario header is not set: this is
# not scenario traffic, and it never passes the recording proxy anyway.
$session = New-BenchSession -BaseUrl $BaseUrl -Scenario 'admin' -HeaderName 'x-bench-configuration'
$ajax = @{ 'X-Requested-With' = 'XMLHttpRequest' }
$applied = New-Object System.Collections.Generic.List[string]

function Get-Token {
    # The anti-forgery token of a page: every admin POST validates one.
    param([Parameter(Mandatory = $true)][string] $Html)
    $match = [regex]::Match($Html, 'name="__RequestVerificationToken" type="hidden" value="([^"]+)"')
    if (-not $match.Success) { throw 'No anti-forgery token on the admin page.' }
    return $match.Groups[1].Value
}

function Get-OptionValue {
    # The value of the <option> whose text is -Text, inside the <select name="-Name">.
    param([string] $Html, [string] $Name, [string] $Text)
    $select = [regex]::Match($Html, ('(?is)<select\b[^>]*\bname="{0}"[^>]*>(.*?)</select>' -f [regex]::Escape($Name)))
    if (-not $select.Success) { throw ('No select {0} on the page.' -f $Name) }
    foreach ($option in [regex]::Matches($select.Groups[1].Value, '(?is)<option\b([^>]*)>(.*?)</option>')) {
        if ([System.Net.WebUtility]::HtmlDecode($option.Groups[2].Value).Trim() -eq $Text) {
            return (Get-BenchTagAttribute -Tag $option.Groups[1].Value)['value']
        }
    }
    throw ('Select {0} has no option "{1}".' -f $Name, $Text)
}

function Get-JsUrl {
    # A URL the admin page's own script posts to, e.g. url: '/FixedOrByCountryStateZip/SaveMode'.
    param([string] $Html, [string] $Pattern)
    $match = [regex]::Match($Html, ('(?:url:\s*|")(''|")?(?<url>/[^''"\s]*{0}[^''"\s]*)' -f $Pattern))
    if (-not $match.Success) { throw ('The admin page does not post to anything matching {0}.' -f $Pattern) }
    return [System.Net.WebUtility]::HtmlDecode($match.Groups['url'].Value)
}

function Invoke-AdminJson {
    param([string] $Path, [System.Collections.IDictionary] $Form, [string] $Token, [int[]] $ExpectStatus = @(200))
    $pairs = New-BenchFormFieldList -From $Form
    Add-BenchFormField -Fields $pairs -Name '__RequestVerificationToken' -Value $Token
    $response = Invoke-BenchStep -Session $session -Path $Path -Method POST -FormPairs $pairs -Headers $ajax -ExpectStatus $ExpectStatus
    if ($response.ContentType -ne 'application/json') { return $response.Body }
    # NullJsonResult answers "null"; an empty body is treated the same.
    if ([string]::IsNullOrWhiteSpace($response.Body)) { return $null }
    return ($response.Body | ConvertFrom-Json)
}

function Compare-FormField {
    # Posted form against the form re-read after saving: only -Changed may differ. Fields
    # whose name the page makes up anew on every render - the download editor's
    # downloadurl<random number> - are not settings and are left out.
    param($Before, $After, [string[]] $Changed, [string] $What)
    $ignore = @('__RequestVerificationToken') + $Changed
    $generated = '^downloadurl[0-9]+$'
    $left = @($Before | Where-Object { $ignore -notcontains $_.Key -and $_.Key -notmatch $generated } | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
    $right = @($After | Where-Object { $ignore -notcontains $_.Key -and $_.Key -notmatch $generated } | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
    $differences = @(Compare-Object -ReferenceObject $left -DifferenceObject $right)
    if ($differences.Count -gt 0) {
        $differences | Select-Object -First 20 | ForEach-Object { Write-BenchLog ('  changed: {0} {1}' -f $_.SideIndicator, $_.InputObject) }
        throw ('{0}: saving changed {1} field(s) it was not meant to change.' -f $What, $differences.Count)
    }
    Write-BenchLog ('{0}: {1} fields re-read; only {2} changed.' -f $What, $right.Count, ($Changed -join ', '))
}

$failures = New-Object System.Collections.Generic.List[string]
function Add-ConfigFailure {
    # An area of section 2 that did not apply. The next area still runs, so one run shows
    # every area that fails; the step fails once all have run.
    param([Parameter(Mandatory = $true)][string] $Area, [Parameter(Mandatory = $true)] $ErrorRecord)
    $failures.Add(('{0}: {1}' -f $Area, $ErrorRecord.Exception.Message))
    Write-Host ('::error::Store configuration, {0}: {1}' -f $Area, $ErrorRecord.Exception.Message)
    Write-BenchLog ('{0} failed at {1}' -f $Area, $ErrorRecord.InvocationInfo.PositionMessage)
}

# --- Sign in ------------------------------------------------------------------------
Enter-BenchGroup ('Sign in to {0} as {1}' -f $BaseUrl, $admin.email)
$null = Invoke-BenchStep -Session $session -Path '/login'
$null = Invoke-BenchStep -Session $session -Path '/login' -Method POST -Form ([ordered]@{ Email = $admin.email; Password = $admin.password; RememberMe = 'false' }) -ExpectStatus @(302)
$null = Invoke-BenchStep -Session $session -Path '/Admin' -ExpectStatus @(200, 302)
$dashboard = Invoke-BenchStep -Session $session -Path '/Admin/Home/Index' -MustContain @('Dashboard')
$null = Get-Token -Html $dashboard.Body
Exit-BenchGroup

# --- Tax ----------------------------------------------------------------------------
Enter-BenchGroup 'Tax: rates by country, state and zip'
try {
    $page = Invoke-BenchStep -Session $session -Path '/Admin/Tax/ConfigureProvider?systemName=Tax.FixedOrByCountryStateZip' -MustContain @('advanced-settings-mode')
    $token = Get-Token -Html $page.Body
    $saveMode = Get-JsUrl -Html $page.Body -Pattern 'SaveMode'
    $addRate = Get-JsUrl -Html $page.Body -Pattern 'AddRateByCountryStateZip'
    $listRates = Get-JsUrl -Html $page.Body -Pattern 'RatesByCountryStateZipList'
    $taxCategory = Get-OptionValue -Html $page.Body -Name 'AddTaxCategoryId' -Text 'Electronics & Software'
    $us = Get-OptionValue -Html $page.Body -Name 'AddCountryId' -Text 'United States'
    $canada = Get-OptionValue -Html $page.Body -Name 'AddCountryId' -Text 'Canada'
    # ConvertFrom-Json is given the text as an argument, not through the pipeline: Windows
    # PowerShell 5.1 writes a parsed JSON array to the pipeline as one object, and a foreach
    # over that pipeline would see one "state" holding every name.
    $usStates = @{}
    $usStateList = ConvertFrom-Json (Invoke-BenchStep -Session $session -Path ('/Admin/Country/GetStatesByCountryId?countryId={0}&addAsterisk=true' -f $us) -Headers $ajax).Body
    foreach ($state in $usStateList) { $usStates[[string] $state.name] = [string] $state.id }
    $caStates = @{}
    $caStateList = ConvertFrom-Json (Invoke-BenchStep -Session $session -Path ('/Admin/Country/GetStatesByCountryId?countryId={0}&addAsterisk=true' -f $canada) -Headers $ajax).Body
    foreach ($state in $caStateList) { $caStates[[string] $state.name] = [string] $state.id }
    foreach ($name in @('New York', 'California')) { if (-not $usStates[$name]) { throw ('The admin state list of the United States has no "{0}" ({1} states).' -f $name, $usStates.Count) } }
    if (-not $caStates['Ontario']) { throw ('The admin state list of Canada has no "Ontario" ({0} states).' -f $caStates.Count) }
    $mode = Invoke-AdminJson -Path $saveMode -Form ([ordered]@{ value = 'true' }) -Token $token
    if (-not $mode.Result) { throw 'Switching the tax provider to country/state/zip failed.' }
    $rates = @(
        [ordered]@{ Country = $us; State = $usStates['New York']; Zip = '10001'; Percentage = '9'; Label = 'US / New York / 10001 9%' },
        [ordered]@{ Country = $us; State = $usStates['New York']; Zip = ''; Percentage = '8.875'; Label = 'US / New York / * 8.875%' },
        [ordered]@{ Country = $us; State = $usStates['California']; Zip = ''; Percentage = '7.25'; Label = 'US / California / * 7.25%' },
        [ordered]@{ Country = $us; State = '0'; Zip = ''; Percentage = '5'; Label = 'US / * / * 5%' },
        [ordered]@{ Country = $canada; State = $caStates['Ontario']; Zip = 'K1A 0B1'; Percentage = '13'; Label = 'Canada / Ontario / K1A 0B1 13%' }
    )
    foreach ($rate in $rates) {
        $result = Invoke-AdminJson -Path $addRate -Token $token -Form ([ordered]@{
                AddStoreId = '0'; AddCountryId = $rate.Country; AddStateProvinceId = $rate.State; AddZip = $rate.Zip
                AddTaxCategoryId = $taxCategory; AddPercentage = $rate.Percentage
            })
        if (-not $result.Result) { throw ('Adding the tax rate {0} failed.' -f $rate.Label) }
    }
    $stored = Invoke-AdminJson -Path $listRates -Token $token -Form ([ordered]@{ page = '1'; pageSize = '50' })
    $storedRows = @($stored.Data | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.CountryName, $_.StateProvinceName, $_.Zip, $_.TaxCategoryName, ([decimal] $_.Percentage).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture) } | Sort-Object)
    $expectedRows = @('Canada|Ontario|K1A 0B1|Electronics & Software|13', 'United States|*|*|Electronics & Software|5', 'United States|California|*|Electronics & Software|7.25', 'United States|New York|*|Electronics & Software|8.875', 'United States|New York|10001|Electronics & Software|9') | Sort-Object
    if (($storedRows -join ';') -ne ($expectedRows -join ';')) { throw ('Tax rates read back: {0}' -f ($storedRows -join '; ')) }
    $storedRows | ForEach-Object { Write-BenchLog ('  tax rate {0}' -f $_) }
    $applied.Add('Tax provider "Fixed or by country/state/zip" in country/state/zip mode; 5 rates for Electronics & Software')
}
catch { Add-ConfigFailure -Area 'Tax' -ErrorRecord $_ }
finally { Exit-BenchGroup }

# --- Products: tax exemption, publishing, stock ------------------------------------
Enter-BenchGroup 'Catalog: MacBook tax exempt, HP Envy unpublished and its page closed, Lenovo stock 3'
try {
    function Find-BulkProduct {
        param([string] $Name, [string] $Token)
        $found = Invoke-AdminJson -Path '/Admin/Product/BulkEditSelect' -Token $Token -Form ([ordered]@{ page = '1'; pageSize = '15'; SearchProductName = $Name; SearchCategoryId = '0'; SearchManufacturerId = '0'; SearchProductTypeId = '0' })
        $row = @($found.Data | Where-Object { $_.Name -eq $Name })
        if ($row.Count -ne 1) { throw ('Bulk edit finds {0} products named "{1}".' -f $row.Count, $Name) }
        return $row[0]
    }
    $bulkPage = Invoke-BenchStep -Session $session -Path '/Admin/Product/BulkEdit'
    $bulkToken = Get-Token -Html $bulkPage.Body
    $macbook = Find-BulkProduct -Name 'Apple MacBook Pro 13-inch' -Token $bulkToken
    $hpEnvy = Find-BulkProduct -Name 'HP Envy 6-1180ca 15.6-Inch Sleekbook' -Token $bulkToken
    $lenovo = Find-BulkProduct -Name 'Lenovo IdeaCentre 600 All-in-One PC' -Token $bulkToken

    # The traffic reaches the unpublished product by its URL; prove the URL is the product's
    # own before it disappears, or a 404 later would prove nothing.
    $null = Invoke-BenchStep -Session $session -Path '/hp-envy-6-1180ca-156-inch-sleekbook' -MustContain @('HP Envy 6-1180ca 15.6-Inch Sleekbook')

    $editPath = '/Admin/Product/Edit/{0}' -f $macbook.Id
    $edit = Invoke-BenchStep -Session $session -Path $editPath -MustContain @('Apple MacBook Pro 13-inch')
    $fields = Get-BenchForm -Html $edit.Body -FormPattern 'id="product-form"'
    if ((Get-BenchFormField -Fields $fields -Name 'IsTaxExempt') -ne 'false') { throw 'The MacBook is already tax exempt, or the form has no IsTaxExempt field.' }
    Set-BenchFormField -Fields $fields -Name 'IsTaxExempt' -Value 'true'
    Add-BenchFormField -Fields $fields -Name 'save-continue' -Value ''
    $null = Invoke-BenchStep -Session $session -Path $editPath -Method POST -FormPairs $fields -ExpectStatus @(302) -ExpectLocation ('/Admin/Product/Edit/{0}$' -f $macbook.Id)
    $reread = Get-BenchForm -Html (Invoke-BenchStep -Session $session -Path $editPath).Body -FormPattern 'id="product-form"'
    if ((Get-BenchFormField -Fields $reread -Name 'IsTaxExempt') -ne 'true') { throw 'The MacBook did not become tax exempt.' }
    Remove-BenchFormField -Fields $fields -Name 'save-continue'
    Compare-FormField -Before $fields -After $reread -Changed @('IsTaxExempt') -What 'Product "Apple MacBook Pro 13-inch"'

    foreach ($change in @(@{ Row = $hpEnvy; Field = 'Published'; Value = 'false' }, @{ Row = $lenovo; Field = 'StockQuantity'; Value = '3' })) {
        $row = $change.Row
        $form = [ordered]@{}
        foreach ($name in @('Id', 'Name', 'Sku', 'Price', 'OldPrice', 'ManageInventoryMethod', 'StockQuantity', 'Published')) {
            $value = $row.$name
            if ($value -is [bool]) { $value = $value.ToString().ToLowerInvariant() }
            elseif ($value -is [decimal] -or $value -is [double]) { $value = ([decimal] $value).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            $form[('products[0].{0}' -f $name)] = [string] $value
        }
        $form[('products[0].{0}' -f $change.Field)] = $change.Value
        $null = Invoke-AdminJson -Path '/Admin/Product/BulkEditUpdate' -Token $bulkToken -Form $form
        $after = Find-BulkProduct -Name $row.Name -Token $bulkToken
        foreach ($name in @('Name', 'Sku', 'Price', 'OldPrice', 'StockQuantity', 'Published')) {
            $expected = [string] $row.$name
            if ($name -eq $change.Field) { $expected = $change.Value }
            if ("$($after.$name)".ToLowerInvariant() -ne $expected.ToLowerInvariant()) { throw ('{0}: {1} is "{2}" after bulk edit, expected "{3}".' -f $row.Name, $name, $after.$name, $expected) }
        }
        Write-BenchLog ('  {0}: {1} = {2}' -f $row.Name, $change.Field, $change.Value)
    }
    # The sample install lets anyone open an unpublished product's page (it then reads
    # "discontinued"); the plan's T05 and R05 need it closed: catalog setting "Allow viewing
    # of unpublished product details page" off.
    $catalogPath = '/Admin/Setting/Catalog'
    $catalog = Get-BenchForm -Html (Invoke-BenchStep -Session $session -Path $catalogPath).Body -FormPattern ('action="{0}"' -f $catalogPath)
    if ((Get-BenchFormField -Fields $catalog -Name 'AllowViewUnpublishedProductPage') -ne 'true') { throw 'The catalog settings form has no AllowViewUnpublishedProductPage switched on.' }
    Set-BenchFormField -Fields $catalog -Name 'AllowViewUnpublishedProductPage' -Value 'false'
    Add-BenchFormField -Fields $catalog -Name 'save' -Value ''
    $null = Invoke-BenchStep -Session $session -Path $catalogPath -Method POST -FormPairs $catalog -ExpectStatus @(302)
    $reread = Get-BenchForm -Html (Invoke-BenchStep -Session $session -Path $catalogPath).Body -FormPattern ('action="{0}"' -f $catalogPath)
    if ((Get-BenchFormField -Fields $reread -Name 'AllowViewUnpublishedProductPage') -ne 'false') { throw 'AllowViewUnpublishedProductPage did not switch off.' }
    Remove-BenchFormField -Fields $catalog -Name 'save'
    Compare-FormField -Before $catalog -After $reread -Changed @('AllowViewUnpublishedProductPage') -What 'Catalog settings'

    # The administrator may still preview an unpublished product; a visitor may not.
    $visitor = New-BenchSession -BaseUrl $BaseUrl -Scenario 'visitor' -HeaderName 'x-bench-configuration'
    $null = Invoke-BenchStep -Session $visitor -Path '/hp-envy-6-1180ca-156-inch-sleekbook' -ExpectStatus @(404)
    $visitor.Client.Dispose()
    $applied.Add('"Apple MacBook Pro 13-inch" tax exempt; "HP Envy 6-1180ca 15.6-Inch Sleekbook" unpublished, and unpublished product pages closed to visitors (catalog setting); "Lenovo IdeaCentre 600 All-in-One PC" stock 3')
}
catch { Add-ConfigFailure -Area 'Catalog' -ErrorRecord $_ }
finally { Exit-BenchGroup }

# --- Shipping -----------------------------------------------------------------------
Enter-BenchGroup 'Shipping: fixed rates, free over $1,000.00'
try {
    $page = Invoke-BenchStep -Session $session -Path '/Admin/Shipping/ConfigureProvider?systemName=Shipping.FixedOrByWeight'
    $token = Get-Token -Html $page.Body
    $listShipping = Get-JsUrl -Html $page.Body -Pattern 'FixedShippingRateList'
    $updateShipping = Get-JsUrl -Html $page.Body -Pattern 'UpdateFixedShippingRate'
    $methods = @{}
    foreach ($row in (Invoke-AdminJson -Path $listShipping -Token $token -Form ([ordered]@{ page = '1'; pageSize = '50' })).Data) { $methods[$row.ShippingMethodName] = $row }
    $shippingRates = [ordered]@{ 'Ground' = '10'; '2nd Day Air' = '25'; 'Next Day Air' = '40' }
    foreach ($name in $shippingRates.Keys) {
        if (-not $methods.ContainsKey($name)) { throw ('No shipping method "{0}" (have: {1}).' -f $name, (($methods.Keys | Sort-Object) -join ', ')) }
        $null = Invoke-AdminJson -Path $updateShipping -Token $token -Form ([ordered]@{ ShippingMethodId = [string] $methods[$name].ShippingMethodId; ShippingMethodName = $name; Rate = $shippingRates[$name] })
    }
    foreach ($row in (Invoke-AdminJson -Path $listShipping -Token $token -Form ([ordered]@{ page = '1'; pageSize = '50' })).Data) {
        if ($shippingRates.Contains($row.ShippingMethodName) -and [decimal] $row.Rate -ne [decimal] $shippingRates[$row.ShippingMethodName]) { throw ('Shipping rate of {0} reads {1}.' -f $row.ShippingMethodName, $row.Rate) }
        Write-BenchLog ('  {0}: {1}' -f $row.ShippingMethodName, $row.Rate)
    }

    $settingsPath = '/Admin/Setting/Shipping'
    $settings = Get-BenchForm -Html (Invoke-BenchStep -Session $session -Path $settingsPath).Body -FormPattern ('action="{0}"' -f $settingsPath)
    Set-BenchFormField -Fields $settings -Name 'FreeShippingOverXEnabled' -Value 'true'
    Set-BenchFormField -Fields $settings -Name 'FreeShippingOverXValue' -Value '1000'
    Set-BenchFormField -Fields $settings -Name 'FreeShippingOverXIncludingTax' -Value 'false'
    Add-BenchFormField -Fields $settings -Name 'save' -Value ''
    $null = Invoke-BenchStep -Session $session -Path $settingsPath -Method POST -FormPairs $settings -ExpectStatus @(302)
    $reread = Get-BenchForm -Html (Invoke-BenchStep -Session $session -Path $settingsPath).Body -FormPattern ('action="{0}"' -f $settingsPath)
    if ((Get-BenchFormField -Fields $reread -Name 'FreeShippingOverXEnabled') -ne 'true' -or [decimal] (Get-BenchFormField -Fields $reread -Name 'FreeShippingOverXValue') -ne 1000) { throw 'Free shipping over $1,000.00 did not stick.' }
    Remove-BenchFormField -Fields $settings -Name 'save'
    # Saving the page also saves its shipping origin address; the first save creates that
    # (empty) address record, so its id changes from 0 - as it does when a person saves.
    Compare-FormField -Before $settings -After $reread -Changed @('FreeShippingOverXEnabled', 'FreeShippingOverXValue', 'FreeShippingOverXIncludingTax', 'ShippingOriginAddress.Id') -What 'Shipping settings'
    $applied.Add('Fixed shipping rates Ground $10, 2nd Day Air $25, Next Day Air $40; free shipping over $1,000.00 excluding tax')
}
catch { Add-ConfigFailure -Area 'Shipping' -ErrorRecord $_ }
finally { Exit-BenchGroup }

# --- Discounts ----------------------------------------------------------------------
Enter-BenchGroup 'Discounts'
try {
    # DiscountTypeId: 1 order total, 2 SKUs, 10 shipping, 20 order subtotal. DiscountLimitationId:
    # 0 unlimited, 25 N times per customer (Nop.Core.Domain.Discounts).
    $discounts = @(
        [ordered]@{ Name = 'Bench SAVE10'; CouponCode = 'SAVE10'; DiscountTypeId = '20'; UsePercentage = 'true'; DiscountPercentage = '10' },
        [ordered]@{ Name = 'Bench TAKE50'; CouponCode = 'TAKE50'; DiscountTypeId = '1'; UsePercentage = 'false'; DiscountAmount = '50' },
        [ordered]@{ Name = 'Bench PCT20MAX100'; CouponCode = 'PCT20MAX100'; DiscountTypeId = '20'; UsePercentage = 'true'; DiscountPercentage = '20'; MaximumDiscountAmount = '100' },
        [ordered]@{ Name = 'Bench SHIPFREE'; CouponCode = 'SHIPFREE'; DiscountTypeId = '10'; UsePercentage = 'true'; DiscountPercentage = '100' },
        [ordered]@{ Name = 'Bench ONCE5'; CouponCode = 'ONCE5'; DiscountTypeId = '1'; UsePercentage = 'false'; DiscountAmount = '5'; DiscountLimitationId = '25'; LimitationTimes = '1' },
        [ordered]@{ Name = 'Bench FUTURE10'; CouponCode = 'FUTURE10'; DiscountTypeId = '20'; UsePercentage = 'true'; DiscountPercentage = '10'; StartDateUtc = '2099-01-01 00:00' },
        [ordered]@{ Name = 'Bench MEMBERS15'; CouponCode = 'MEMBERS15'; DiscountTypeId = '20'; UsePercentage = 'true'; DiscountPercentage = '15' }
    )
    $discountIds = [ordered]@{}
    foreach ($discount in $discounts) {
        $create = Invoke-BenchStep -Session $session -Path '/Admin/Discount/Create'
        $fields = Get-BenchForm -Html $create.Body -FormPattern 'id="discount-form"'
        Set-BenchFormField -Fields $fields -Name 'RequiresCouponCode' -Value 'true'
        foreach ($name in $discount.Keys) { Set-BenchFormField -Fields $fields -Name $name -Value $discount[$name] }
        Add-BenchFormField -Fields $fields -Name 'save-continue' -Value ''
        $saved = Invoke-BenchStep -Session $session -Path '/Admin/Discount/Create' -Method POST -FormPairs $fields -ExpectStatus @(302) -ExpectLocation '/Admin/Discount/Edit/[0-9]+$'
        $id = [regex]::Match($saved.Location, '/Edit/([0-9]+)$').Groups[1].Value
        $discountIds[$discount.CouponCode] = [int] $id
        # Read the discount back from its own edit page.
        $back = Get-BenchForm -Html (Invoke-BenchStep -Session $session -Path ('/Admin/Discount/Edit/{0}' -f $id)).Body -FormPattern 'id="discount-form"'
        foreach ($name in @('CouponCode', 'DiscountTypeId', 'UsePercentage', 'RequiresCouponCode')) {
            $expected = $discount[$name]
            if ($name -eq 'RequiresCouponCode') { $expected = 'true' }
            if ($null -ne $expected -and (Get-BenchFormField -Fields $back -Name $name) -ne $expected) { throw ('Discount {0}: {1} reads "{2}", expected "{3}".' -f $discount.CouponCode, $name, (Get-BenchFormField -Fields $back -Name $name), $expected) }
        }
        Write-BenchLog ('  discount {0} -> id {1}' -f $discount.CouponCode, $id)
    }

    # MEMBERS15: requirement "customer role is Registered", attached to the default requirement
    # group - which is what the admin page's script does after the plugin's form is saved.
    $membersId = $discountIds['MEMBERS15']
    $rule = Invoke-BenchStep -Session $session -Path ('/Plugins/DiscountRulesCustomerRoles/Configure?discountId={0}' -f $membersId)
    $registered = Get-OptionValue -Html $rule.Body -Name ('DiscountRulesCustomerRoles0.CustomerRoleId') -Text 'Registered'
    $requirement = Invoke-AdminJson -Path '/Plugins/DiscountRulesCustomerRoles/Configure' -Token (Get-Token -Html $dashboard.Body) -Form ([ordered]@{ discountId = [string] $membersId; discountRequirementId = '0'; customerRoleId = $registered })
    if (-not $requirement.Result) { throw 'Adding the customer role requirement to MEMBERS15 failed.' }
    $attached = (Invoke-BenchStep -Session $session -Path ('/Admin/Discount/GetDiscountRequirements?discountId={0}&discountRequirementId={1}&deleteRequirement=false' -f $membersId, $requirement.NewRequirementId) -Headers $ajax).Body | ConvertFrom-Json
    $rules = @($attached.Requirements | ForEach-Object { $_; $_.ChildRequirements } | Where-Object { $_ -and -not $_.IsGroup })
    if (@($rules | Where-Object { $_.DiscountRequirementId -eq $requirement.NewRequirementId }).Count -ne 1) { throw 'The MEMBERS15 requirement is not in the discount''s requirement group.' }
    Write-BenchLog ('  MEMBERS15 requires customer role {0} (Registered), requirement {1}' -f $registered, $requirement.NewRequirementId)
    $applied.Add('Discounts SAVE10, TAKE50, PCT20MAX100, SHIPFREE, ONCE5, FUTURE10, MEMBERS15 (Registered role only)')
}
catch { Add-ConfigFailure -Area 'Discounts' -ErrorRecord $_ }
finally { Exit-BenchGroup }

# --- Background tasks ---------------------------------------------------------------
Enter-BenchGroup 'Background tasks: disabled, application restarted'
try {
    # nopCommerce 3.90 runs its schedule tasks on timers inside the web application, and each
    # run first reads its task row (Task.Execute calls GetTaskByType before its try/catch).
    # A database restore under a running task makes that read throw on a timer thread, which
    # takes the worker process down: the shop answers 500 until it has restarted. Every
    # scenario starts with a restore, when recording and in each replay, so no task may run.
    # Tasks are started from the enabled rows when the application starts, hence the restart.
    $tasksPage = Invoke-BenchStep -Session $session -Path '/Admin/ScheduleTask/List'
    $tasksToken = Get-Token -Html $tasksPage.Body
    $tasks = @((Invoke-AdminJson -Path '/Admin/ScheduleTask/List' -Token $tasksToken -Form ([ordered]@{ page = '1'; pageSize = '50' })).Data)
    if ($tasks.Count -eq 0) { throw 'The schedule task list is empty.' }
    $enabled = @($tasks | Where-Object { $_.Enabled })
    foreach ($task in $enabled) {
        $null = Invoke-AdminJson -Path '/Admin/ScheduleTask/TaskUpdate' -Token $tasksToken -Form ([ordered]@{
                Id = [string] $task.Id; Name = [string] $task.Name; Seconds = [string] $task.Seconds
                Enabled = 'false'; StopOnError = ([string] $task.StopOnError).ToLowerInvariant()
            })
    }
    $after = @((Invoke-AdminJson -Path '/Admin/ScheduleTask/List' -Token $tasksToken -Form ([ordered]@{ page = '1'; pageSize = '50' })).Data)
    $stillEnabled = @($after | Where-Object { $_.Enabled })
    if ($stillEnabled.Count -gt 0) { throw ('Schedule tasks still enabled: {0}' -f (($stillEnabled | ForEach-Object { $_.Name }) -join ', ')) }
    $taskNames = @($enabled | ForEach-Object { '{0} ({1} s)' -f $_.Name, $_.Seconds })
    if ($taskNames.Count -eq 0) { $taskNames = @('none was enabled') }
    Write-BenchLog ('  disabled: {0}; all {1} schedule tasks now disabled' -f ($taskNames -join '; '), $after.Count)
    # The admin layout's "Restart application" is a form: the action accepts POST only and,
    # like every admin POST, validates the anti-forgery token. It redirects to the dashboard
    # and unloads the application once the request has completed; the next request starts
    # it again, which writes "Application started" to the nopCommerce log. That entry - not
    # just an answer, which the application being unloaded may still give - shows the
    # restart happened.
    if (-not $deploy) { throw 'No state\deploy.json (step 4): the restart is confirmed from the nopCommerce log in the database step 4 created.' }
    $startsQuery = "SELECT COUNT(*) FROM dbo.[Log] WHERE ShortMessage = N'Application started'"
    $startsBefore = [int] (Invoke-BenchSqlScalar -Server $deploy.sqlServer -Database $deploy.database -Query $startsQuery)
    $null = Invoke-BenchStep -Session $session -Path '/Admin/Common/RestartApplication' -Method POST -Form ([ordered]@{ __RequestVerificationToken = $tasksToken }) -ExpectStatus @(302) -ExpectLocation '^(https?://[^/]+)?/Admin/?$'
    $probe = New-BenchHttpClient -TimeoutSeconds 300
    try {
        $deadline = (Get-Date).AddSeconds(300)
        while ($true) {
            $null = Wait-BenchHttp -Client $probe -Uri $BaseUrl -TimeoutSeconds 300 -IntervalSeconds 3
            $starts = [int] (Invoke-BenchSqlScalar -Server $deploy.sqlServer -Database $deploy.database -Query $startsQuery)
            if ($starts -gt $startsBefore) { break }
            if ((Get-Date) -ge $deadline) { throw 'The application did not restart: no new "Application started" entry in the nopCommerce log within 300 s.' }
            Start-Sleep -Seconds 3
        }
    }
    finally { $probe.Dispose() }
    Write-BenchLog ('  application restarted: "Application started" logged {0} time(s) before, {1} now' -f $startsBefore, $starts)
    $applied.Add(('Schedule tasks disabled - {0}; all {1} now disabled - and the application restarted, so no task timer runs under a database restore' -f ($taskNames -join ', '), $after.Count))
}
catch { Add-ConfigFailure -Area 'Background tasks' -ErrorRecord $_ }
finally { Exit-BenchGroup }

$session.Client.Dispose()
if ($failures.Count -gt 0) {
    Add-BenchSummary -Lines (@('### Store configuration (traffic plan section 2): failed', '') + @($failures | ForEach-Object { '- ' + $_ }) + @(''))
    throw ('{0} area(s) of the store configuration did not apply: {1}' -f $failures.Count, ($failures -join ' | '))
}

Write-BenchState -WorkRoot $work -Name 'store-config' -Data ([ordered]@{
        baseUrl = $BaseUrl
        applied = $applied.ToArray()
        taxCategoryId = [int] $taxCategory
        countries = [ordered]@{ unitedStates = [int] $us; canada = [int] $canada }
        products = [ordered]@{ macbook = [int] $macbook.Id; hpEnvy = [int] $hpEnvy.Id; lenovo = [int] $lenovo.Id }
        discounts = $discountIds
        registeredRoleId = [int] $registered
        configuredAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })

$summary = @('### Store configuration (traffic plan section 2)', '', 'Applied through the admin UI and read back:', '')
foreach ($line in $applied) { $summary += ('- {0}' -f $line) }
$summary += ''
Add-BenchSummary -Lines $summary
exit 0
