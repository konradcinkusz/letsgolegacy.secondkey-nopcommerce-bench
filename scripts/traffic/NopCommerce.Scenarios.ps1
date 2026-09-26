# The P4 traffic set: docs/P4-TRAFFIC-PLAN.md section 4 as scripted sessions. Dot-sourced by
# 7-record-traffic.ps1 after NopBench.Common.ps1, NopBench.Chain.ps1 and NopBench.Shop.ps1;
# defines functions only.
#
# One scenario is one browser session - one person, one cookie jar - and one replayed
# scenario: the database is restored to the post-configuration snapshot before each one,
# when recording and on each side of every replay. Where the plan has two people in one
# story (T18, T30), each person is a scenario of their own; section 4a of the plan lists
# every such refinement.
#
# Every step checks the answer its scenario needs (Invoke-BenchStep, Assert-NopTotal): a
# scenario that does not reach what it exercises fails the recording rather than being
# recorded as evidence. Requests whose answers the contract (P5) asserts a scenario-specific
# fact on carry probe=<name> (NopBench.Shop.ps1).

# Sample data (nopCommerce 3.90 CodeFirstInstallationService) and section 2's configuration.
$script:Lenovo = 'lenovo-ideacentre-600-all-in-one-pc'        # product 3, $500.00, stock 3 after section 2
$script:MacBook = 'apple-macbook-pro-13-inch'                 # product 4, $1,800.00, minimum 2, ships free, tax exempt
$script:Computer = 'build-your-own-computer'                  # product 1, $1,200.00, attributes
$script:Book = 'pride-and-prejudice'                          # product 39, $24.00, Books (no tax rate)
$script:GiftCard = '25-virtual-gift-card'                     # product 43, $25.00 virtual gift card
$script:HpEnvy = 'hp-envy-6-1180ca-156-inch-sleekbook'        # product 8, unpublished in section 2
$script:Steve = @{ Email = 'steve_gates@nopCommerce.com'; Password = '123456' }   # sample customer, public sample data
$script:NewYork10001 = [ordered]@{ FirstName = 'Gina'; LastName = 'Guest'; Email = 'g1@nopbench.invalid'; Country = 'United States'; State = 'New York'; City = 'New York'; Address1 = '1 Bench Street'; Zip = '10001'; Phone = '5550100' }

function Get-NopAddress {
    # The guest's address with some fields replaced.
    param([System.Collections.IDictionary] $Change)
    $address = [ordered]@{}
    foreach ($key in $script:NewYork10001.Keys) { $address[$key] = $script:NewYork10001[$key] }
    foreach ($key in $Change.Keys) { $address[$key] = $Change[$key] }
    return $address
}

function Get-NopCartLineId {
    # The cart item id of the line holding product -Name.
    param([Parameter(Mandatory = $true)] $Session, [AllowEmptyCollection()][object[]] $Items, [Parameter(Mandatory = $true)][string] $Name)
    $line = @($Items | Where-Object { $_.Name -eq $Name })
    if ($line.Count -ne 1) { throw ('{0}: the cart has {1} line(s) of "{2}" (lines: {3}).' -f $Session.Scenario, $line.Count, $Name, (@($Items | ForEach-Object { $_.Name }) -join '; ')) }
    return $line[0].Id
}

function Assert-NopTotal {
    # Checks rows of a totals block (cart page or checkout section): each expected value is a
    # regex the row's text must match; a $null value means the row must be absent.
    param([Parameter(Mandatory = $true)] $Session, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Html, [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Expect)
    $totals = Get-NopCartTotal -Html $Html
    $problems = @()
    foreach ($row in $Expect.Keys) {
        $actual = $null
        if ($totals.Contains($row)) { $actual = $totals[$row] -join ' | ' }
        if ($null -eq $Expect[$row]) { if ($actual) { $problems += ('{0} is "{1}", expected no such row' -f $row, $actual) } }
        elseif (-not $actual -or $actual -notmatch $Expect[$row]) { $problems += ('{0} is "{1}", expected /{2}/' -f $row, $actual, $Expect[$row]) }
    }
    if ($problems.Count -gt 0) { throw ('{0}: {1}' -f $Session.Scenario, ($problems -join '; ')) }
}

# Negative amounts: nopCommerce formats them with the en-US culture of the runtime, which
# writes ($100.00) or -$100.00 depending on the globalization data (the P7 probe). Record-time
# checks accept both; the contract pins what the legacy system writes.
function Get-NopNegative { param([string] $Amount) return ('^(\(\{0}\)|-\{0})$' -f $Amount) }

function Get-NopScenario {
    $list = New-Object System.Collections.Generic.List[object]
    function Add-Scenario { param([string] $Id, [string] $Area, [string] $Persona, [string] $Title, [scriptblock] $Run, $Data) $list.Add([pscustomobject]@{ Id = $Id; Area = $Area; Persona = $Persona; Title = $Title; Run = $Run; Data = $Data }) }

    # --- Catalog -------------------------------------------------------------------------
    Add-Scenario 'T01' 'Catalog' 'G1' 'Home page: featured products, footer' {
        param($s)
        $null = Invoke-BenchStep -Session $s -Path '/' -MustContain @('Welcome to our store', 'Powered by <a href="http://www.nopcommerce.com/">nopCommerce</a>', 'Apple MacBook Pro 13-inch', 'Build your own computer')
    }
    Add-Scenario 'T02' 'Catalog' 'G1' 'Category listing: published products only, sorted by price and by name, paged' {
        param($s)
        foreach ($path in @('/notebooks', '/notebooks?orderby=10', '/notebooks?orderby=5', '/notebooks?pagesize=3&pagenumber=2')) {
            $page = Invoke-BenchStep -Session $s -Path $path -MustNotContain @('HP Envy 6-1180ca 15.6-Inch Sleekbook')
            Write-BenchLog ('  {0,-5} {1}: {2}' -f $s.Scenario, $path, ((Get-NopProductName -Html $page.Body) -join '; '))
        }
    }
    Add-Scenario 'T03' 'Catalog' 'G1' 'A parent category lists its subcategories' {
        param($s)
        $null = Invoke-BenchStep -Session $s -Path '/computers' -MustContain @('Desktops', 'Notebooks', 'Software')
    }
    Add-Scenario 'T04' 'Catalog' 'G1' 'Product pages: name, SKU, price, attributes' {
        param($s)
        $null = Invoke-BenchStep -Session $s -Path ('/{0}' -f $script:Lenovo) -MustContain @('Lenovo IdeaCentre 600 All-in-One PC', 'LE_IC_600', '$500.00')
        $null = Invoke-BenchStep -Session $s -Path ('/{0}' -f $script:MacBook) -MustContain @('Apple MacBook Pro 13-inch', 'AP_MBP_13', '$1,800.00')
        $null = Invoke-BenchStep -Session $s -Path ('/{0}' -f $script:Computer) -MustContain @('Build your own computer', 'COMP_CUST', 'Processor', '[+$15.00]')
    }
    Add-Scenario 'T05' 'Catalog' 'G1' 'An unpublished product is not shown' {
        param($s)
        $null = Invoke-BenchStep -Session $s -Path ('/{0}' -f $script:HpEnvy) -ExpectStatus @(404) -MustNotContain @('HP_ESB_15')
    }
    Add-Scenario 'T06' 'Search' 'G1' 'Keyword search: case, SKU, trimming, minimum length' {
        param($s)
        foreach ($query in @('apple', 'APPLE', 'AP_MBP_13', '%20apple%20')) {
            $page = Invoke-BenchStep -Session $s -Path ('/search?q={0}' -f $query) -MustContain @('Apple MacBook Pro 13-inch')
            Write-BenchLog ('  {0,-5} q={1}: {2}' -f $s.Scenario, $query, ((Get-NopProductName -Html $page.Body) -join '; '))
        }
        $null = Invoke-BenchStep -Session $s -Path '/search?q=ap' -MustContain @('Search term minimum length is 3 characters') -MustNotContain @('Apple MacBook Pro 13-inch')
    }

    # --- Cart ----------------------------------------------------------------------------
    Add-Scenario 'T07' 'Cart' 'G1' 'Add to cart; a quantity above stock is refused' {
        param($s)
        $null = Invoke-BenchStep -Session $s -Path '/desktops' -MustContain @('Lenovo IdeaCentre 600 All-in-One PC')
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $null = Add-NopProductFromPage -Session $s -Slug $script:Lenovo -Quantity 5 -Probe 'T07' -ExpectRefusal -ExpectMessage @('Your quantity exceeds stock on hand. The maximum quantity that can be added is 3.')
        $null = Show-NopCart -Session $s -Probe 'T07' -MustContain @('Lenovo IdeaCentre 600 All-in-One PC')
    }
    Add-Scenario 'T08' 'Cart' 'G1' 'A quantity below the minimum is refused' {
        param($s)
        $page = Invoke-BenchStep -Session $s -Path ('/{0}' -f $script:MacBook)
        $null = Add-NopProductFromPage -Session $s -Slug $script:MacBook -Page $page -Quantity 1 -Probe 'T08' -ExpectRefusal -ExpectMessage @('The minimum quantity allowed for purchase is 2.')
        $null = Add-NopProductFromPage -Session $s -Slug $script:MacBook -Page $page -Quantity 2
        $null = Show-NopCart -Session $s -Probe 'T08' -MustContain @('Apple MacBook Pro 13-inch')
    }
    Add-Scenario 'T09' 'Cart' 'G1' 'Required attributes; attribute price adjustments in the unit price' {
        param($s)
        $page = Invoke-BenchStep -Session $s -Path ('/{0}' -f $script:Computer)
        $null = Add-NopProductFromPage -Session $s -Slug $script:Computer -Page $page -Probe 'T09' -ExpectRefusal -ExpectMessage @('Please select HDD')
        $ram = Get-NopAttributeControl -Html $page.Body -Label 'RAM'
        $hdd = Get-NopAttributeControl -Html $page.Body -Label 'HDD'
        $choice = [ordered]@{}
        $choice[$ram.Name] = Get-NopOptionValue -Control $ram -Text '4GB'
        $choice[$hdd.Name] = Get-NopOptionValue -Control $hdd -Text '400 GB'
        $null = Add-NopProductFromPage -Session $s -Slug $script:Computer -Page $page -Set $choice
        $cart = Show-NopCart -Session $s -Probe 'T09'
        # 1200 + processor 2.5 GHz 15 + RAM 4GB 20 + HDD 400 GB 100 + OS Vista Home 50 + Microsoft Office 50
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$1,435\.00$' }
    }
    Add-Scenario 'T10' 'Cart' 'G1' 'Update quantities; remove by checkbox; quantity 0 removes' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $null = Add-NopProductFromCatalog -Session $s -ProductId 39
        $cart = Show-NopCart -Session $s
        $items = @(Get-NopCartItem -Html $cart.Body)
        $lenovoLine = Get-NopCartLineId -Session $s -Items $items -Name 'Lenovo IdeaCentre 600 All-in-One PC'
        $bookLine = Get-NopCartLineId -Session $s -Items $items -Name 'Pride and Prejudice'
        $three = Invoke-NopCartForm -Session $s -Button 'updatecart' -Set @{ ('itemquantity{0}' -f $lenovoLine) = '3' } -Probe 'T10-quantity' -Cart $cart
        Assert-NopTotal -Session $s -Html $three.Body -Expect @{ 'order-subtotal' = '^\$1,524\.00$' }
        $removed = Invoke-NopCartForm -Session $s -Button 'updatecart' -Add @(('removefromcart={0}' -f $bookLine)) -Probe 'T10-remove' -Cart $three
        if ($removed.Body.Contains('Pride and Prejudice')) { throw 'T10: the book is still in the cart after "remove".' }
        $null = Invoke-NopCartForm -Session $s -Button 'updatecart' -Set @{ ('itemquantity{0}' -f $lenovoLine) = '0' } -Probe 'T10-zero' -Cart $removed -MustContain @('Your Shopping Cart is empty!')
    }

    # --- Discounts -----------------------------------------------------------------------
    Add-Scenario 'T11' 'Discounts' 'G1' 'SAVE10: 10% of the order subtotal' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3 -Quantity 2
        $cart = Invoke-NopCoupon -Session $s -Code 'SAVE10' -Probe 'T11' -ExpectMessage @('The coupon code was applied')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$1,000\.00$'; 'order-subtotal-discount' = (Get-NopNegative '$100.00') }
    }
    Add-Scenario 'T12' 'Discounts' 'G1' 'A coupon code is trimmed and matched without regard to case' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3 -Quantity 2
        $cart = Invoke-NopCoupon -Session $s -Code ' save10 ' -Probe 'T12' -ExpectMessage @('The coupon code was applied')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal-discount' = (Get-NopNegative '$100.00') }
    }
    Add-Scenario 'T12B' 'Discounts' 'G1' 'A coupon code followed by U+180E (white space in older Unicode data only)' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3 -Quantity 2
        # Recorded as the shop answers it; the NLS -> ICU probe of plan section 6.
        $null = Invoke-NopCoupon -Session $s -Code ('SAVE10{0}' -f [char] 0x180E) -Probe 'T12B'
    }
    Add-Scenario 'T13' 'Discounts' 'G1' 'Expired, not-yet-started and unknown coupons are refused' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $cart = Invoke-NopCoupon -Session $s -Code '456' -Probe 'T13-expired' -ExpectMessage @('Sorry, this offer is expired')
        $cart = Invoke-NopCoupon -Session $s -Code 'FUTURE10' -Probe 'T13-future' -ExpectMessage @('Sorry, this offer is not started yet') -Cart $cart
        $cart = Invoke-NopCoupon -Session $s -Code 'NOSUCH' -Probe 'T13-unknown' -ExpectMessage @("The coupon code you entered couldn't be applied to your order") -Cart $cart
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$500\.00$'; 'order-subtotal-discount' = $null; 'discount-total' = $null }
    }
    Add-Scenario 'T14' 'Discounts' 'G1' 'TAKE50 on a $34.00 order: the discount is capped at the order total' {
        param($s)
        # Checked out to the confirm step first, so the cart knows shipping ($10.00) and tax
        # ($0.00: no rate for Books) before the coupon; then the order total is $34.00.
        $null = Add-NopProductFromCatalog -Session $s -ProductId 39
        $null = Invoke-NopCheckout -Session $s -Billing $script:NewYork10001
        $cart = Invoke-NopCoupon -Session $s -Code 'TAKE50' -Probe 'T14' -ExpectMessage @('The coupon code was applied')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$24\.00$'; 'shipping-cost' = '^\$10\.00$'; 'tax-value' = '^\$0\.00$'; 'discount-total' = (Get-NopNegative '$34.00'); 'order-total' = '^\$0\.00$' }
    }
    Add-Scenario 'T15' 'Discounts' 'G1' 'PCT20MAX100: a percentage discount stops at its maximum' {
        param($s)
        $null = Add-NopProductFromPage -Session $s -Slug $script:MacBook -Quantity 2
        $cart = Invoke-NopCoupon -Session $s -Code 'PCT20MAX100' -Probe 'T15' -ExpectMessage @('The coupon code was applied')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$3,600\.00$'; 'order-subtotal-discount' = (Get-NopNegative '$100.00') }
    }
    Add-Scenario 'T16' 'Discounts' 'G1' 'SHIPFREE: a discount on shipping' {
        param($s)
        # As T14: to the confirm step with Ground first, so the cart shows shipping ($10.00)
        # before the coupon takes it to $0.00.
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $null = Invoke-NopCheckout -Session $s -Billing $script:NewYork10001
        $cart = Invoke-NopCoupon -Session $s -Code 'SHIPFREE' -Probe 'T16' -ExpectMessage @('The coupon code was applied')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$500\.00$'; 'shipping-cost' = '^\$0\.00$' }
    }
    Add-Scenario 'T17' 'Discounts' 'G1' 'No subtotal discount while the cart holds a gift card' {
        param($s)
        $page = Invoke-BenchStep -Session $s -Path ('/{0}' -f $script:GiftCard)
        $id = Get-NopProductId -Html $page.Body
        $card = [ordered]@{}
        $card[('giftcard_{0}.RecipientName' -f $id)] = 'Rita Recipient'
        $card[('giftcard_{0}.RecipientEmail' -f $id)] = 'rita@nopbench.invalid'
        $card[('giftcard_{0}.SenderName' -f $id)] = 'Gina Guest'
        $card[('giftcard_{0}.SenderEmail' -f $id)] = 'g1@nopbench.invalid'
        $card[('giftcard_{0}.Message' -f $id)] = 'Recorded by the bench'
        $null = Add-NopProductFromPage -Session $s -Slug $script:GiftCard -Page $page -Set $card
        $null = Add-NopProductFromCatalog -Session $s -ProductId 39
        $cart = Invoke-NopCoupon -Session $s -Code 'SAVE10' -Probe 'T17' -ExpectMessage @('Sorry, this discount cannot be used with gift cards in the cart')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal-discount' = $null }
    }
    Add-Scenario 'T18A' 'Discounts' 'G1' 'MEMBERS15 requires the Registered role: a guest is refused' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        # The customer-role rule refuses without a message of its own (UserError stays null),
        # so the coupon box shows whatever ApplyDiscountCoupon makes of that; recorded as is.
        $cart = Invoke-NopCoupon -Session $s -Code 'MEMBERS15' -Probe 'T18A'
        $totals = Get-NopCartTotal -Html $cart.Body
        Write-BenchLog ('  {0,-5} coupon box: {1} message(s): "{2}"' -f $s.Scenario, @($totals['coupon-messages']).Count, (@($totals['coupon-messages']) -join '" "'))
        if (@($totals['coupon-messages']) -contains 'The coupon code was applied' -or @($totals['applied-coupons']).Count -gt 0) { throw 'T18A: MEMBERS15 was applied for a guest.' }
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$500\.00$'; 'order-subtotal-discount' = $null }
    }
    Add-Scenario 'T18B' 'Discounts' 'S1' 'MEMBERS15 requires the Registered role: a registered customer gets it' {
        param($s)
        Invoke-NopLogin -Session $s -Email $script:Steve.Email -Password $script:Steve.Password
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $cart = Invoke-NopCoupon -Session $s -Code 'MEMBERS15' -Probe 'T18B' -ExpectMessage @('The coupon code was applied')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal-discount' = (Get-NopNegative '$75.00') }
    }
    Add-Scenario 'T19' 'Discounts' 'S1' 'ONCE5: once per customer, counted from placed orders' {
        param($s)
        Invoke-NopLogin -Session $s -Email $script:Steve.Email -Password $script:Steve.Password
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $null = Invoke-NopCoupon -Session $s -Code 'ONCE5' -ExpectMessage @('The coupon code was applied')
        $order = Invoke-NopCheckout -Session $s -PlaceOrder -CompletedProbe 'T19'
        Assert-NopTotal -Session $s -Html $order.ConfirmHtml -Expect @{ 'discount-total' = (Get-NopNegative '$5.00') }
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $null = Invoke-NopCoupon -Session $s -Code 'ONCE5' -Probe 'T19' -ExpectMessage @("Sorry, you've used this discount already")
    }
    Add-Scenario 'T20' 'Discounts' 'G1' 'Sample coupon 123: a SKU discount mapped to no product is applied and changes nothing' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $cart = Invoke-NopCoupon -Session $s -Code '123' -Probe 'T20' -ExpectMessage @('The coupon code was applied')
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$500\.00$'; 'order-subtotal-discount' = $null; 'discount-total' = $null }
    }

    # --- Tax -------------------------------------------------------------------------------
    $taxCases = @(
        @{ Id = 'T21'; Title = 'Tax by country, state and exact zip: US / New York / 10001 (9%)'; Address = $script:NewYork10001; Tax = '^\$45\.00$' },
        @{ Id = 'T22A'; Title = 'Tax fallback to any zip: US / New York / 10002 (8.875%)'; Address = (Get-NopAddress @{ Zip = '10002' }); Tax = '^\$44\.38$' },
        @{ Id = 'T22B'; Title = 'Tax by state: US / California (7.25%)'; Address = (Get-NopAddress @{ State = 'California'; City = 'Los Angeles'; Zip = '90001' }); Tax = '^\$36\.25$' },
        @{ Id = 'T22C'; Title = 'Tax fallback to any state: US / Texas (5%)'; Address = (Get-NopAddress @{ State = 'Texas'; City = 'Austin'; Zip = '73301' }); Tax = '^\$25\.00$' },
        @{ Id = 'T22D'; Title = 'No tax rate for the country: Germany (0)'; Address = (Get-NopAddress @{ Country = 'Germany'; State = ''; City = 'Berlin'; Zip = '10115' }); Tax = '^\$0\.00$' },
        @{ Id = 'T23'; Title = 'The zip match ignores case: Canada / Ontario / k1a 0b1 (13%)'; Address = (Get-NopAddress @{ Country = 'Canada'; State = 'Ontario'; City = 'Ottawa'; Zip = 'k1a 0b1' }); Tax = '^\$65\.00$' }
    )
    foreach ($case in $taxCases) {
        Add-Scenario $case.Id 'Tax' 'G1' $case.Title -Data $case -Run {
            param($s, $case)
            $null = Add-NopProductFromCatalog -Session $s -ProductId 3
            $null = Invoke-NopCheckout -Session $s -Billing $case.Address
            $cart = Show-NopCart -Session $s -Probe $case.Id
            Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$500\.00$'; 'shipping-cost' = '^\$10\.00$'; 'tax-value' = $case.Tax }
        }
    }
    Add-Scenario 'T22E' 'Tax' 'G1' 'A tax-exempt product is not taxed: MacBook x2 billed to US / New York / 10001' {
        param($s)
        $null = Add-NopProductFromPage -Session $s -Slug $script:MacBook -Quantity 2
        $null = Invoke-NopCheckout -Session $s -Billing $script:NewYork10001
        $cart = Show-NopCart -Session $s -Probe 'T22E'
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'order-subtotal' = '^\$3,600\.00$'; 'tax-value' = '^\$0\.00$' }
    }
    Add-Scenario 'T22F' 'Tax' 'G1' 'Tax follows the billing address: billed to New York 10001, shipped to Texas' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $null = Invoke-NopCheckout -Session $s -Billing $script:NewYork10001 -ShipTo (Get-NopAddress @{ State = 'Texas'; City = 'Austin'; Zip = '73301' })
        $cart = Show-NopCart -Session $s -Probe 'T22F'
        Assert-NopTotal -Session $s -Html $cart.Body -Expect @{ 'tax-value' = '^\$45\.00$' }
    }

    # --- Shipping ----------------------------------------------------------------------------
    Add-Scenario 'T24' 'Shipping' 'G1' 'Shipping methods and fixed rates; the cart estimate matches checkout' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $estimate = Invoke-NopEstimateShipping -Session $s -Country 'United States' -State 'New York' -Zip '10001' -Probe 'T24'
        foreach ($expected in @('Ground ($10.00)', '2nd Day Air ($25.00)', 'Next Day Air ($40.00)')) { if ($estimate -notcontains $expected) { throw ('T24: the estimate does not offer {0}: {1}' -f $expected, ($estimate -join '; ')) } }
        $checkout = Invoke-NopCheckout -Session $s -Billing $script:NewYork10001 -BillingProbe 'T24'
        foreach ($expected in @('Ground ($10.00)', '2nd Day Air ($25.00)', 'Next Day Air ($40.00)')) { if ($checkout.ShippingMethods -notcontains $expected) { throw ('T24: checkout does not offer {0}: {1}' -f $expected, ($checkout.ShippingMethods -join '; ')) } }
    }
    Add-Scenario 'T25' 'Shipping' 'G1' 'Free shipping when every item ships free: MacBook x2 (in-store pickup keeps its fee)' {
        param($s)
        $null = Add-NopProductFromPage -Session $s -Slug $script:MacBook -Quantity 2
        $estimate = Invoke-NopEstimateShipping -Session $s -Country 'United States' -State 'New York' -Zip '10001' -Probe 'T25'
        # The estimate also lists in-store pickup (the sample pickup point's $1.99 fee), which
        # free shipping does not waive; the three shipping methods must cost nothing.
        $methods = @($estimate | Where-Object { $_ -notmatch '^Pickup\b' })
        if ($methods.Count -ne 3) { throw ('T25: the estimate lists {0} shipping methods: {1}' -f $methods.Count, ($estimate -join '; ')) }
        foreach ($option in $methods) { if ($option -notmatch '\(\$0\.00\)$') { throw ('T25: a free-shipping cart is charged: {0}' -f $option) } }
    }
    Add-Scenario 'T26' 'Shipping' 'G1' 'Free shipping over $1,000.00 means strictly over' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3 -Quantity 2
        $at = Invoke-NopEstimateShipping -Session $s -Country 'United States' -State 'New York' -Zip '10001' -Probe 'T26-1000'
        if ($at -notcontains 'Ground ($10.00)') { throw ('T26: a $1,000.00 cart does not pay for Ground: {0}' -f ($at -join '; ')) }
        $null = Add-NopProductFromCatalog -Session $s -ProductId 39
        $over = Invoke-NopEstimateShipping -Session $s -Country 'United States' -State 'New York' -Zip '10001' -Probe 'T26-1024'
        if ($over -notcontains 'Ground ($0.00)') { throw ('T26: a $1,024.00 cart pays for Ground: {0}' -f ($over -join '; ')) }
    }

    # --- Checkout and orders --------------------------------------------------------------
    Add-Scenario 'T27' 'Checkout' 'G1' 'Guest one-page checkout end to end' {
        param($s)
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3
        $order = Invoke-NopCheckout -Session $s -Billing $script:NewYork10001 -PlaceOrder -CompletedProbe 'T27'
        Assert-NopTotal -Session $s -Html $order.ConfirmHtml -Expect @{ 'order-subtotal' = '^\$500\.00$'; 'shipping-cost' = '^\$10\.00$'; 'tax-value' = '^\$45\.00$'; 'order-total' = '^\$555\.00$' }
        $details = Invoke-BenchStep -Session $s -Path (Add-NopProbe -Path ('/orderdetails/{0}' -f $order.OrderId) -Probe 'T27') -MustContain @('Lenovo IdeaCentre 600 All-in-One PC', '$555.00')
        Write-NopCart -Session $s -Html $details.Body -Label ('order {0}' -f $order.OrderId)
    }
    Add-Scenario 'T28' 'Checkout' 'R1' 'Registered checkout: card check digit, stock decreases, cart emptied' {
        param($s)
        Invoke-NopRegister -Session $s -Customer ([ordered]@{ FirstName = 'Rita'; LastName = 'Registered'; Email = 'r1@nopbench.invalid'; Password = 'bench-R1-pass'; ConfirmPassword = 'bench-R1-pass' })
        $null = Add-NopProductFromCatalog -Session $s -ProductId 3 -Quantity 2
        $null = Invoke-NopCoupon -Session $s -Code 'SAVE10' -ExpectMessage @('The coupon code was applied')
        $card = [ordered]@{ CreditCardType = 'Visa'; CardholderName = 'Rita Registered'; CardNumber = '4111 1111 1111 1111'; ExpireMonth = '12'; ExpireYear = [string] ((Get-Date).Year + 3); CardCode = '123' }
        $bad = [ordered]@{}
        foreach ($key in $card.Keys) { $bad[$key] = $card[$key] }
        $bad['CardNumber'] = '4111 1111 1111 1112'
        $order = Invoke-NopCheckout -Session $s -Billing (Get-NopAddress @{ FirstName = 'Rita'; LastName = 'Registered'; Email = 'r1@nopbench.invalid' }) -ShippingMethod 'Next Day Air' -PaymentMethod 'Payments.Manual' -Card $card -BadCard $bad -BadCardProbe 'T28' -PlaceOrder -CompletedProbe 'T28'
        # Subtotal 1,000.00 - SAVE10 100.00; Next Day Air 40.00 (900.00 is not over 1,000.00); tax 9% of 900.00.
        Assert-NopTotal -Session $s -Html $order.ConfirmHtml -Expect @{ 'order-subtotal-discount' = (Get-NopNegative '$100.00'); 'shipping-cost' = '^\$40\.00$'; 'tax-value' = '^\$81\.00$'; 'order-total' = '^\$1,021\.00$' }
        $details = Invoke-BenchStep -Session $s -Path (Add-NopProbe -Path ('/orderdetails/{0}' -f $order.OrderId) -Probe 'T28') -MustContain @('Lenovo IdeaCentre 600 All-in-One PC', '$1,021.00')
        Write-NopCart -Session $s -Html $details.Body -Label ('order {0}' -f $order.OrderId)
        $null = Show-NopCart -Session $s -Probe 'T28-after' -MustContain @('Your Shopping Cart is empty!')
        $null = Add-NopProductFromPage -Session $s -Slug $script:Lenovo -Quantity 2 -Probe 'T28' -ExpectRefusal -ExpectMessage @('The maximum quantity that can be added is 1.')
    }
    Add-Scenario 'T29' 'Orders' 'S1' 'Order history, details and PDF invoice of one''s own order' {
        param($s)
        Invoke-NopLogin -Session $s -Email $script:Steve.Email -Password $script:Steve.Password
        $history = Invoke-BenchStep -Session $s -Path (Add-NopProbe -Path '/order/history' -Probe 'T29') -MustContain @('Order Number:')
        Write-BenchLog ('  {0,-5} order history: {1}' -f $s.Scenario, (@([regex]::Matches($history.Body, '(?is)<div class="title">\s*<strong>(.*?)</strong>') | ForEach-Object { Get-NopText $_.Groups[1].Value }) -join '; '))
        $null = Invoke-BenchStep -Session $s -Path '/orderdetails/1' -MustContain @('Order #1')
        $null = Invoke-BenchStep -Session $s -Path '/orderdetails/pdf/1' -ExpectContentType 'application/pdf'
    }
    Add-Scenario 'T30A' 'Orders' 'G2' 'A guest sees, prints, downloads and reorders no one else''s order, and has no order history' {
        param($s)
        foreach ($path in @('/orderdetails/2', '/orderdetails/print/2', '/orderdetails/pdf/2', '/reorder/2', '/order/history')) {
            $null = Invoke-BenchStep -Session $s -Path (Add-NopProbe -Path $path -Probe 'T30A') -ExpectStatus @(302) -ExpectLocation '^/login\?ReturnUrl='
        }
    }
    Add-Scenario 'T30B' 'Orders' 'S1' 'A registered customer does not see someone else''s order' {
        param($s)
        Invoke-NopLogin -Session $s -Email $script:Steve.Email -Password $script:Steve.Password
        $null = Invoke-BenchStep -Session $s -Path (Add-NopProbe -Path '/orderdetails/2' -Probe 'T30B') -ExpectStatus @(302) -ExpectLocation '^/login\?ReturnUrl='
    }

    return , $list
}
