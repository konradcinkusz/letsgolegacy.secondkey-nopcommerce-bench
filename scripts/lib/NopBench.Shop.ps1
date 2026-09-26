# The nopCommerce 3.90 storefront as a browser uses it: product pages, the cart, coupons,
# shipping estimates, the one-page checkout, sign-in and registration. Each helper sends
# exactly the requests the shop's own pages and scripts send, through the session it is
# given (Invoke-BenchStep), and checks the answer it needs to carry on. Dot-source
# NopBench.Common.ps1 and NopBench.Chain.ps1 first; this file only defines functions.
#
# Markup and endpoints are nopCommerce 3.90's (release-3.90, commit 12d1f01): Views/Product,
# Views/ShoppingCart, Views/Checkout, Scripts/public.ajaxcart.js, public.onepagecheckout.js.
#
# A "probe" is a query parameter, probe=<name>, added to a request whose answer the
# contract (P5) asserts a scenario-specific fact on. nopCommerce ignores unknown query
# parameters on these routes; the contract language scopes clauses by method, path and
# query only, so this is how a clause names one scenario's request (docs/P4-TRAFFIC-PLAN.md).

function Add-NopProbe {
    param([Parameter(Mandatory = $true)][string] $Path, [string] $Probe)
    if (-not $Probe) { return $Path }
    if ($Path.Contains('?')) { return ('{0}&probe={1}' -f $Path, $Probe) }
    return ('{0}?probe={1}' -f $Path, $Probe)
}

function ConvertFrom-NopJson {
    param([Parameter(Mandatory = $true)] $Response)
    if ($Response.ContentType -ne 'application/json') { throw ('Expected JSON, got {0}: {1}' -f $Response.ContentType, $Response.Body.Substring(0, [math]::Min(200, $Response.Body.Length))) }
    return ($Response.Body | ConvertFrom-Json)
}

function Get-NopText {
    # The text of an HTML fragment: tags dropped, entities decoded, white space collapsed.
    param([AllowEmptyString()][string] $Html)
    return (([System.Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>', ' '))) -replace '\s+', ' ').Trim()
}

# --- Catalog and product pages ------------------------------------------------------

function Get-NopProductId {
    param([Parameter(Mandatory = $true)][string] $Html)
    $match = [regex]::Match($Html, 'itemtype="http://schema\.org/Product" data-productid="(\d+)"')
    if (-not $match.Success) { throw 'No product id on the page.' }
    return [int] $match.Groups[1].Value
}

function Get-NopProductName {
    # Product names of a listing (category, search, home page): the product boxes' titles.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Html)
    return @([regex]::Matches($Html, '(?is)<h2 class="product-title">\s*<a [^>]*>(.*?)</a>') | ForEach-Object { Get-NopText $_.Groups[1].Value })
}

function Add-NopProductFromCatalog {
    # The "Add to cart" button of a product box: POST /addproducttocart/catalog/{id}/1/{quantity}.
    param([Parameter(Mandatory = $true)] $Session, [Parameter(Mandatory = $true)][int] $ProductId, [int] $Quantity = 1, [string] $Probe)
    $path = Add-NopProbe -Path ('/addproducttocart/catalog/{0}/1/{1}' -f $ProductId, $Quantity) -Probe $Probe
    $json = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path $path -Method POST -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' })
    if (-not ($json.PSObject.Properties.Name -contains 'success') -or -not $json.success) { throw ('{0}: adding product {1} from a listing did not succeed: {2}' -f $Session.Scenario, $ProductId, ($json | ConvertTo-Json -Compress)) }
    return $json
}

function Add-NopProductFromPage {
    # "Add to cart" on a product page: the whole product-details-form, as the page's script
    # posts it to /addproducttocart/details/{id}/1. -Set overrides form fields (attributes,
    # gift card fields); -Remove drops fields. Returns the JSON answer; -ExpectRefusal
    # requires success=false and each of -ExpectMessage among the warnings.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)][string] $Slug,
        [int] $Quantity = 1,
        [System.Collections.IDictionary] $Set,
        [string[]] $Remove = @(),
        [string] $Probe,
        [switch] $ExpectRefusal,
        [string[]] $ExpectMessage = @(),
        $Page
    )
    if (-not $Page) { $Page = Invoke-BenchStep -Session $Session -Path ('/{0}' -f $Slug) }
    $id = Get-NopProductId -Html $Page.Body
    $fields = Get-BenchForm -Html $Page.Body -FormPattern 'id="product-details-form"'
    Set-BenchFormField -Fields $fields -Name ('addtocart_{0}.EnteredQuantity' -f $id) -Value ([string] $Quantity)
    foreach ($name in $Remove) { Remove-BenchFormField -Fields $fields -Name $name }
    if ($Set) { foreach ($name in $Set.Keys) { Set-BenchFormField -Fields $fields -Name $name -Value ([string] $Set[$name]) } }
    $path = Add-NopProbe -Path ('/addproducttocart/details/{0}/1' -f $id) -Probe $Probe
    $json = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path $path -Method POST -FormPairs $fields -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' })
    $messages = @()
    if ($json.PSObject.Properties.Name -contains 'message') { $messages = @($json.message) }
    $succeeded = ($json.PSObject.Properties.Name -contains 'success') -and $json.success
    if ($ExpectRefusal) {
        if ($succeeded) { throw ('{0}: adding {1} was accepted; the scenario needs it refused.' -f $Session.Scenario, $Slug) }
        foreach ($text in $ExpectMessage) {
            if (-not ($messages | Where-Object { "$_".Contains($text) })) { throw ('{0}: the refusal does not say "{1}": {2}' -f $Session.Scenario, $text, ($messages -join ' | ')) }
        }
        Write-BenchLog ('  {0,-5} refused: {1}' -f $Session.Scenario, ($messages -join ' | '))
    }
    elseif (-not $succeeded) {
        throw ('{0}: adding {1} did not succeed: {2}' -f $Session.Scenario, $Slug, ($json | ConvertTo-Json -Compress))
    }
    return $json
}

function Get-NopAttributeControl {
    # The form field name (product_attribute_{id}) of the attribute labelled -Label on a
    # product page, and its options as text -> value.
    param([Parameter(Mandatory = $true)][string] $Html, [Parameter(Mandatory = $true)][string] $Label)
    foreach ($dt in [regex]::Matches($Html, '(?is)<dt id="product_attribute_label_(\d+)">(.*?)</dt>')) {
        if ((Get-NopText $dt.Groups[2].Value) -match ('^{0}\b' -f [regex]::Escape($Label))) {
            $name = 'product_attribute_{0}' -f $dt.Groups[1].Value
            $dd = [regex]::Match($Html, ('(?is)<dd id="product_attribute_input_{0}">(.*?)</dd>' -f $dt.Groups[1].Value)).Groups[1].Value
            $options = [ordered]@{}
            foreach ($option in [regex]::Matches($dd, '(?is)<option\b[^>]*value="(\d+)"[^>]*>(.*?)</option>')) { $options[(Get-NopText $option.Groups[2].Value)] = $option.Groups[1].Value }
            foreach ($radio in [regex]::Matches($dd, '(?is)<input id="[^"]*" type="(?:radio|checkbox)" name="[^"]*" value="(\d+)"[^>]*>\s*<label[^>]*>(.*?)</label>')) { $options[(Get-NopText $radio.Groups[2].Value)] = $radio.Groups[1].Value }
            return [pscustomobject]@{ Name = $name; Options = $options }
        }
    }
    throw ('No product attribute labelled "{0}" on the page.' -f $Label)
}

function Get-NopOptionValue {
    # The value of the option of -Control whose text starts with -Text.
    param([Parameter(Mandatory = $true)] $Control, [Parameter(Mandatory = $true)][string] $Text)
    foreach ($key in $Control.Options.Keys) { if ($key.StartsWith($Text)) { return $Control.Options[$key] } }
    throw ('{0} has no option starting "{1}" (has: {2}).' -f $Control.Name, $Text, (@($Control.Options.Keys) -join ' | '))
}

# --- The cart ------------------------------------------------------------------------

function Get-NopCartItem {
    # The lines of a cart page: cart item id, product name, quantity, unit price, line total.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Html)
    $items = @()
    foreach ($row in [regex]::Matches($Html, '(?is)<tr>\s*<td class="remove-from-cart">(.*?)</tr>')) {
        $cells = $row.Groups[1].Value
        $items += [pscustomobject]@{
            Id        = [int] [regex]::Match($cells, 'name="itemquantity(\d+)"').Groups[1].Value
            Name      = Get-NopText ([regex]::Match($cells, '(?is)class="product-name">(.*?)</a>').Groups[1].Value)
            Quantity  = [regex]::Match($cells, 'name="itemquantity\d+" type="text" value="(\d+)"').Groups[1].Value
            UnitPrice = Get-NopText ([regex]::Match($cells, '(?is)<span class="product-unit-price">(.*?)</span>').Groups[1].Value)
            LineTotal = Get-NopText ([regex]::Match($cells, '(?is)<span class="product-subtotal">(.*?)</span>').Groups[1].Value)
        }
    }
    return $items
}

function Get-NopCartTotal {
    # The totals block and the coupon box of a cart page (or of a checkout section), as text.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Html)
    $total = [ordered]@{}
    foreach ($row in @('order-subtotal', 'order-subtotal-discount', 'shipping-cost', 'tax-value', 'discount-total', 'order-total')) {
        $match = [regex]::Match($Html, ('(?is)<tr class="{0}">.*?<td class="cart-total-right">(.*?)</td>' -f $row))
        if ($match.Success) { $total[$row] = Get-NopText $match.Groups[1].Value }
    }
    $total['coupon-messages'] = @([regex]::Matches($Html, '(?is)<div class="message-(?:success|failure)">(.*?)</div>') | ForEach-Object { Get-NopText $_.Groups[1].Value })
    $total['applied-coupons'] = @([regex]::Matches($Html, '(?is)<span class="applied-discount-code">(.*?)</span>') | ForEach-Object { Get-NopText $_.Groups[1].Value })
    return $total
}

function Write-NopCart {
    # One log line per cart state: lines, totals, coupon messages. For reading a run back.
    param([Parameter(Mandatory = $true)] $Session, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Html, [string] $Label = 'cart')
    $lines = @(Get-NopCartItem -Html $Html | ForEach-Object { '{0} x{1} @ {2} = {3}' -f $_.Name, $_.Quantity, $_.UnitPrice, $_.LineTotal })
    $totals = Get-NopCartTotal -Html $Html
    $parts = @($totals.Keys | Where-Object { $totals[$_] -and "$($totals[$_])" } | ForEach-Object { '{0}: {1}' -f $_, ($totals[$_] -join ' / ') })
    Write-BenchLog ('  {0,-5} {1}: [{2}] {3}' -f $Session.Scenario, $Label, ($lines -join '; '), ($parts -join '; '))
}

function Invoke-NopCartForm {
    # Submits the cart page's form (shopping-cart-form) with one of its buttons, as the
    # browser does: every field of the form plus the button. The form is multipart in the
    # page; it is sent url-encoded, which the cart actions read the same way and which lets
    # the replay's anti-forgery correlation reach the token field.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)][string] $Button,
        [System.Collections.IDictionary] $Set,
        [string[]] $Add = @(),
        [string] $Probe,
        [string[]] $MustContain = @(),
        $Cart
    )
    if (-not $Cart) { $Cart = Invoke-BenchStep -Session $Session -Path '/cart' }
    $fields = Get-BenchForm -Html $Cart.Body -FormPattern 'id="shopping-cart-form"'
    if ($Set) { foreach ($name in $Set.Keys) { Set-BenchFormField -Fields $fields -Name $name -Value ([string] $Set[$name]) } }
    foreach ($pair in $Add) { $kv = $pair.Split('=', 2); Add-BenchFormField -Fields $fields -Name $kv[0] -Value $kv[1] }
    $label = [regex]::Match($Cart.Body, ('<input type="submit" name="{0}"[^>]*value="([^"]*)"' -f [regex]::Escape($Button))).Groups[1].Value
    Add-BenchFormField -Fields $fields -Name $Button -Value ([System.Net.WebUtility]::HtmlDecode($label))
    $response = Invoke-BenchStep -Session $Session -Path (Add-NopProbe -Path '/cart' -Probe $Probe) -Method POST -FormPairs $fields -MustContain $MustContain
    Write-NopCart -Session $Session -Html $response.Body -Label ('after {0}' -f $Button)
    return $response
}

function Invoke-NopCoupon {
    # Types a coupon code into the cart's coupon box and presses "Apply coupon". Each of
    # -ExpectMessage must be one of the coupon box's messages (compared as text: the page
    # HTML-encodes them).
    param([Parameter(Mandatory = $true)] $Session, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Code, [string] $Probe, [string[]] $ExpectMessage = @(), $Cart)
    $response = Invoke-NopCartForm -Session $Session -Button 'applydiscountcouponcode' -Set @{ discountcouponcode = $Code } -Probe $Probe -Cart $Cart
    $messages = @((Get-NopCartTotal -Html $response.Body)['coupon-messages'])
    foreach ($text in $ExpectMessage) {
        if ($messages -notcontains $text) { throw ('{0}: applying "{1}" did not say "{2}"; the coupon box says: {3}' -f $Session.Scenario, $Code, $text, ($messages -join ' | ')) }
    }
    return $response
}

function Show-NopCart {
    # Views the cart page; with -Probe, the view the contract asserts on.
    param([Parameter(Mandatory = $true)] $Session, [string] $Probe, [string[]] $MustContain = @(), [string[]] $MustNotContain = @())
    $cart = Invoke-BenchStep -Session $Session -Path (Add-NopProbe -Path '/cart' -Probe $Probe) -MustContain $MustContain -MustNotContain $MustNotContain
    Write-NopCart -Session $Session -Html $cart.Body
    return $cart
}

function Get-NopStateId {
    # A state's id, from the endpoint the address forms' scripts call when the country changes.
    param([Parameter(Mandatory = $true)] $Session, [Parameter(Mandatory = $true)][string] $CountryId, [Parameter(Mandatory = $true)][string] $State, [string] $AddSelectStateItem = 'true')
    # Parsed from an argument, not the pipeline: Windows PowerShell 5.1 writes a JSON array
    # to the pipeline as one object.
    $states = ConvertFrom-Json (Invoke-BenchStep -Session $Session -Path ('/country/getstatesbycountryid/?countryId={0}&addSelectStateItem={1}' -f $CountryId, $AddSelectStateItem) -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' }).Body
    $match = @($states | Where-Object { $_.name -eq $State })
    if ($match.Count -ne 1) { throw ('Country {0} has no state "{1}".' -f $CountryId, $State) }
    return [string] $match[0].id
}

function Get-NopSelectValue {
    # The value of the option with text -Text in the <select> named -Name.
    param([Parameter(Mandatory = $true)][string] $Html, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Text)
    $select = [regex]::Match($Html, ('(?is)<select\b[^>]*\bname="{0}"[^>]*>(.*?)</select>' -f [regex]::Escape($Name)))
    if (-not $select.Success) { throw ('No select {0} on the page.' -f $Name) }
    foreach ($option in [regex]::Matches($select.Groups[1].Value, '(?is)<option\b([^>]*)>(.*?)</option>')) {
        if ((Get-NopText $option.Groups[2].Value) -eq $Text) { return (Get-BenchTagAttribute -Tag $option.Groups[1].Value)['value'] }
    }
    throw ('Select {0} has no option "{1}".' -f $Name, $Text)
}

function Invoke-NopEstimateShipping {
    # The cart's "Estimate shipping" box: the whole cart form, posted to /cart/estimateshipping
    # (a [PublicAntiForgery] action). Returns the options as "Name (price)" strings.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)][string] $Country,
        [string] $State,
        [string] $Zip,
        [string] $Probe,
        [string[]] $MustContain = @()
    )
    $cart = Invoke-BenchStep -Session $Session -Path '/cart'
    $fields = Get-BenchForm -Html $cart.Body -FormPattern 'id="shopping-cart-form"'
    $countryId = Get-NopSelectValue -Html $cart.Body -Name 'CountryId' -Text $Country
    Set-BenchFormField -Fields $fields -Name 'CountryId' -Value $countryId
    $stateId = '0'
    if ($State) { $stateId = Get-NopStateId -Session $Session -CountryId $countryId -State $State -AddSelectStateItem 'false' }
    Set-BenchFormField -Fields $fields -Name 'StateProvinceId' -Value $stateId
    Set-BenchFormField -Fields $fields -Name 'ZipPostalCode' -Value ([string] $Zip)
    $result = Invoke-BenchStep -Session $Session -Path (Add-NopProbe -Path '/cart/estimateshipping' -Probe $Probe) -Method POST -FormPairs $fields -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' } -MustContain $MustContain
    $options = @([regex]::Matches($result.Body, '(?is)<strong class="option-name">(.*?)</strong>') | ForEach-Object { Get-NopText $_.Groups[1].Value })
    Write-BenchLog ('  {0,-5} estimate {1}/{2}/{3}: {4}' -f $Session.Scenario, $Country, $State, $Zip, ($options -join '; '))
    return $options
}

# --- Customers ------------------------------------------------------------------------

function Invoke-NopLogin {
    # Signs a customer in through the public login form, as a browser does. The passwords
    # are the sample shop's own: the public sample customer's, or one a scenario registered.
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Sample-shop customers only (public sample data or a customer the scenario registered); the value is typed into a form field, as a browser does.')]
    param([Parameter(Mandatory = $true)] $Session, [Parameter(Mandatory = $true)][string] $Email, [Parameter(Mandatory = $true)][string] $Password)
    $page = Invoke-BenchStep -Session $Session -Path '/login'
    $fields = Get-BenchForm -Html $page.Body -FormPattern 'action="/login"'
    Set-BenchFormField -Fields $fields -Name 'Email' -Value $Email
    Set-BenchFormField -Fields $fields -Name 'Password' -Value $Password
    $null = Invoke-BenchStep -Session $Session -Path '/login' -Method POST -FormPairs $fields -ExpectStatus @(302) -ExpectLocation '^/$'
    $null = Invoke-BenchStep -Session $Session -Path '/' -MustContain @('ico-logout')
}

function Invoke-NopRegister {
    param([Parameter(Mandatory = $true)] $Session, [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Customer)
    $page = Invoke-BenchStep -Session $Session -Path '/register' -MustContain @('__RequestVerificationToken')
    $fields = Get-BenchForm -Html $page.Body -FormPattern 'action="/register"'
    foreach ($name in $Customer.Keys) { Set-BenchFormField -Fields $fields -Name $name -Value ([string] $Customer[$name]) }
    Add-BenchFormField -Fields $fields -Name 'register-button' -Value 'Register'
    $done = Invoke-BenchStep -Session $Session -Path '/register' -Method POST -FormPairs $fields -ExpectStatus @(302) -ExpectLocation '^/registerresult/1'
    $null = Invoke-BenchStep -Session $Session -Path (Get-BenchLocationPath $done.Location) -MustContain @('Your registration completed')
}

# --- One-page checkout ----------------------------------------------------------------

function Get-NopSectionFieldList {
    # The fields of one checkout section's HTML (a JSON update_section), as its form posts them.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Html)
    # The comma keeps the list a list: returned bare, PowerShell would unroll it.
    return , (Get-BenchForm -Html ('<form id="section">{0}</form>' -f $Html) -FormPattern 'id="section"')
}

function Get-NopJsonValue {
    # A property of a JSON answer, or $null when the answer has no such property (strict mode
    # makes a missing property an error; a checkout step that went elsewhere is an answer).
    param($Object, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) { return $null }
    return $Object.$Name
}

function Format-NopStep {
    # A checkout step's JSON answer for an error message, section HTML shortened.
    param($Step)
    $text = $Step | ConvertTo-Json -Compress -Depth 4
    if ($text.Length -gt 700) { $text = $text.Substring(0, 700) + '...' }
    return $text
}

function Enter-NopCheckout {
    # The cart page's Checkout button, as a browser follows it: the cart form is posted with
    # the button (ShoppingCartController.StartCheckout saves the checkout attributes on it -
    # the sample store's required "Gift wrapping" - and an order without them is refused),
    # a guest is shown "Checkout as Guest" and follows it, and /checkout sends everyone on to
    # the one-page checkout, which this answers.
    param([Parameter(Mandatory = $true)] $Session)
    $cart = Invoke-BenchStep -Session $Session -Path '/cart' -MustContain @('id="shopping-cart-form"')
    $fields = Get-BenchForm -Html $cart.Body -FormPattern 'id="shopping-cart-form"'
    Add-BenchFormField -Fields $fields -Name 'checkout' -Value 'checkout'
    $started = Invoke-BenchStep -Session $Session -Path '/cart' -Method POST -FormPairs $fields -ExpectStatus @(302) -ExpectLocation '^/(login/checkoutasguest|checkout)'
    $next = Get-BenchLocationPath $started.Location
    if ($next -match '^/login/checkoutasguest') {
        $null = Invoke-BenchStep -Session $Session -Path $next -MustContain @('checkout-as-guest-button')
    }
    $null = Invoke-BenchStep -Session $Session -Path '/checkout' -ExpectStatus @(302) -ExpectLocation '^/onepagecheckout'
    return (Invoke-BenchStep -Session $Session -Path '/onepagecheckout' -MustContain @('co-billing-form'))
}

function Invoke-NopCheckout {
    # The one-page checkout, step by step, as public.onepagecheckout.js drives it - entered
    # from the cart's Checkout button (Enter-NopCheckout): billing address, shipping address
    # (only when -ShipTo differs), shipping method, payment method, payment info, and - with
    # -PlaceOrder - the order. A billing address is either
    # -Billing (a new address: FirstName, LastName, Email, Country, State, City, Address1,
    # Zip, Phone) or the customer's first saved one. -Card fills the "Manual" payment form;
    # -BadCard is posted first and must be refused. The shop skips the payment steps when
    # the order total is zero (CheckoutController.OpcLoadStepAfterShippingMethod), and so
    # does this; a card given for such an order is an error. Returns the shipping methods
    # offered, the confirm section and the order number.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [System.Collections.IDictionary] $Billing,
        [System.Collections.IDictionary] $ShipTo,
        [string] $ShippingMethod = 'Ground',
        [string] $PaymentMethod = 'Payments.CheckMoneyOrder',
        [System.Collections.IDictionary] $Card,
        [System.Collections.IDictionary] $BadCard,
        [switch] $PlaceOrder,
        [string] $BillingProbe,
        [string] $BadCardProbe,
        [string] $CompletedProbe
    )
    $ajax = @{ 'X-Requested-With' = 'XMLHttpRequest' }
    $opc = Enter-NopCheckout -Session $Session
    $fields = Get-BenchForm -Html $opc.Body -FormPattern 'id="co-billing-form"'
    if ($Billing) {
        if ($null -ne (Get-BenchFormField -Fields $fields -Name 'billing_address_id')) { Set-BenchFormField -Fields $fields -Name 'billing_address_id' -Value '' }
        $countryId = Get-NopSelectValue -Html $opc.Body -Name 'BillingNewAddress.CountryId' -Text $Billing.Country
        $stateId = '0'
        if ($Billing.Contains('State') -and $Billing.State) { $stateId = Get-NopStateId -Session $Session -CountryId $countryId -State $Billing.State }
        $address = [ordered]@{
            'BillingNewAddress.FirstName' = $Billing.FirstName; 'BillingNewAddress.LastName' = $Billing.LastName
            'BillingNewAddress.Email' = $Billing.Email; 'BillingNewAddress.Company' = ''
            'BillingNewAddress.CountryId' = $countryId; 'BillingNewAddress.StateProvinceId' = $stateId
            'BillingNewAddress.City' = $Billing.City; 'BillingNewAddress.Address1' = $Billing.Address1; 'BillingNewAddress.Address2' = ''
            'BillingNewAddress.ZipPostalCode' = $Billing.Zip; 'BillingNewAddress.PhoneNumber' = $Billing.Phone; 'BillingNewAddress.FaxNumber' = ''
        }
        foreach ($name in $address.Keys) { Set-BenchFormField -Fields $fields -Name $name -Value ([string] $address[$name]) }
    }
    elseif ($null -eq (Get-BenchFormField -Fields $fields -Name 'billing_address_id')) {
        throw ('{0}: no saved address to bill to, and no -Billing given.' -f $Session.Scenario)
    }
    if ($ShipTo) { Set-BenchFormField -Fields $fields -Name 'ShipToSameAddress' -Value 'false' }
    else { Set-BenchFormField -Fields $fields -Name 'ShipToSameAddress' -Value 'true' }
    $step = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path (Add-NopProbe -Path '/checkout/OpcSaveBilling/' -Probe $BillingProbe) -Method POST -FormPairs $fields -Headers $ajax)

    if ($ShipTo) {
        if ((Get-NopJsonValue $step 'goto_section') -ne 'shipping') { throw ('{0}: billing did not lead to the shipping address: {1}' -f $Session.Scenario, (Format-NopStep $step)) }
        $shippingHtml = $step.update_section.html
        $shipping = Get-NopSectionFieldList -Html $shippingHtml
        if ($null -ne (Get-BenchFormField -Fields $shipping -Name 'shipping_address_id')) { Set-BenchFormField -Fields $shipping -Name 'shipping_address_id' -Value '' }
        $shipCountry = Get-NopSelectValue -Html $shippingHtml -Name 'ShippingNewAddress.CountryId' -Text $ShipTo.Country
        $shipState = '0'
        if ($ShipTo.Contains('State') -and $ShipTo.State) { $shipState = Get-NopStateId -Session $Session -CountryId $shipCountry -State $ShipTo.State }
        $shipAddress = [ordered]@{
            'ShippingNewAddress.FirstName' = $ShipTo.FirstName; 'ShippingNewAddress.LastName' = $ShipTo.LastName
            'ShippingNewAddress.Email' = $ShipTo.Email; 'ShippingNewAddress.Company' = ''
            'ShippingNewAddress.CountryId' = $shipCountry; 'ShippingNewAddress.StateProvinceId' = $shipState
            'ShippingNewAddress.City' = $ShipTo.City; 'ShippingNewAddress.Address1' = $ShipTo.Address1; 'ShippingNewAddress.Address2' = ''
            'ShippingNewAddress.ZipPostalCode' = $ShipTo.Zip; 'ShippingNewAddress.PhoneNumber' = $ShipTo.Phone; 'ShippingNewAddress.FaxNumber' = ''
        }
        foreach ($name in $shipAddress.Keys) { Set-BenchFormField -Fields $shipping -Name $name -Value ([string] $shipAddress[$name]) }
        $step = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path '/checkout/OpcSaveShipping/' -Method POST -FormPairs $shipping -Headers $ajax)
    }
    if ((Get-NopJsonValue $step 'goto_section') -ne 'shipping_method') { throw ('{0}: expected the shipping method step, got: {1}' -f $Session.Scenario, (Format-NopStep $step)) }
    $methodsHtml = $step.update_section.html
    $offered = @([regex]::Matches($methodsHtml, '(?is)<label for="shippingoption_\d+">(.*?)</label>') | ForEach-Object { Get-NopText $_.Groups[1].Value })
    Write-BenchLog ('  {0,-5} shipping methods offered: {1}' -f $Session.Scenario, ($offered -join '; '))
    $option = [regex]::Match($methodsHtml, ('name="shippingoption" value="({0}___[^"]+)"' -f [regex]::Escape($ShippingMethod)))
    if (-not $option.Success) { throw ('{0}: shipping method "{1}" is not offered.' -f $Session.Scenario, $ShippingMethod) }
    $methodFields = Get-NopSectionFieldList -Html $methodsHtml
    Set-BenchFormField -Fields $methodFields -Name 'shippingoption' -Value ([System.Net.WebUtility]::HtmlDecode($option.Groups[1].Value))
    $step = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path '/checkout/OpcSaveShippingMethod/' -Method POST -FormPairs $methodFields -Headers $ajax)

    if ((Get-NopJsonValue $step 'goto_section') -eq 'payment_method') {
        $paymentFields = Get-NopSectionFieldList -Html $step.update_section.html
        Set-BenchFormField -Fields $paymentFields -Name 'paymentmethod' -Value $PaymentMethod
        $step = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path '/checkout/OpcSavePaymentMethod/' -Method POST -FormPairs $paymentFields -Headers $ajax)
    }
    if ((Get-NopJsonValue $step 'goto_section') -eq 'payment_info') {
        $infoHtml = $step.update_section.html
        foreach ($attempt in @(@{ Card = $BadCard; Probe = $BadCardProbe; Bad = $true }, @{ Card = $Card; Probe = $null; Bad = $false })) {
            if ($attempt.Bad -and -not $attempt.Card) { continue }
            $infoFields = Get-NopSectionFieldList -Html $infoHtml
            if ($attempt.Card) { foreach ($name in $attempt.Card.Keys) { Set-BenchFormField -Fields $infoFields -Name $name -Value ([string] $attempt.Card[$name]) } }
            $step = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path (Add-NopProbe -Path '/checkout/OpcSavePaymentInfo/' -Probe $attempt.Probe) -Method POST -FormPairs $infoFields -Headers $ajax)
            if ($attempt.Bad) {
                if ((Get-NopJsonValue $step 'goto_section') -eq 'confirm_order') { throw ('{0}: the bad card was accepted.' -f $Session.Scenario) }
                $section = Get-NopJsonValue $step 'update_section'
                if (-not $section) { throw ('{0}: the bad card got no payment form back: {1}' -f $Session.Scenario, (Format-NopStep $step)) }
                $errors = @([regex]::Matches($section.html, '(?is)<li>(.*?)</li>') | ForEach-Object { Get-NopText $_.Groups[1].Value })
                Write-BenchLog ('  {0,-5} card refused: {1}' -f $Session.Scenario, ($errors -join ' | '))
                $infoHtml = $section.html
            }
        }
    }
    elseif ($Card -or $BadCard) {
        throw ('{0}: the checkout skipped payment info, but the scenario has a card to enter: {1}' -f $Session.Scenario, (Format-NopStep $step))
    }
    if ((Get-NopJsonValue $step 'goto_section') -ne 'confirm_order') { throw ('{0}: expected the confirm step, got: {1}' -f $Session.Scenario, (Format-NopStep $step)) }
    $confirmHtml = $step.update_section.html
    Write-NopCart -Session $Session -Html $confirmHtml -Label 'confirm'

    $orderId = $null
    if ($PlaceOrder) {
        $placed = ConvertFrom-NopJson (Invoke-BenchStep -Session $Session -Path '/checkout/OpcConfirmOrder/' -Method POST -FormPairs (New-BenchFormFieldList) -Headers $ajax)
        if ((Get-NopJsonValue $placed 'success') -ne 1) { throw ('{0}: the order was not placed: {1}' -f $Session.Scenario, (Format-NopStep $placed)) }
        $completed = Invoke-BenchStep -Session $Session -Path (Add-NopProbe -Path '/checkout/completed/' -Probe $CompletedProbe) -MustContain @('Your order has been successfully processed!')
        $orderId = [int] [regex]::Match($completed.Body, '(?is)Order number:\s*(\d+)').Groups[1].Value
        if (-not $orderId) { throw ('{0}: no order number on the completed page.' -f $Session.Scenario) }
        Write-BenchLog ('  {0,-5} order {1} placed' -f $Session.Scenario, $orderId)
    }
    return [pscustomobject]@{ ShippingMethods = $offered; ConfirmHtml = $confirmHtml; OrderId = $orderId }
}
