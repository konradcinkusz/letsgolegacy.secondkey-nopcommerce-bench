# P4 traffic plan — the nopCommerce 3.90 scenario set

What P4 records through the proxy, what each scenario exercises, and the rules the P5
contract will assert about it. Every rule is taken from nopCommerce 3.90's own code and
cites it: this is how *this* shop behaves, not how a shop should behave in general.

- **Source read:** `release-3.90`, commit `12d1f01` (pinned in [`pins.json`](../pins.json)).
  Paths are relative to `src/` in that tree; line numbers refer to that commit.
- **Counts:** 30 scenarios, 46 rules, 9 of them absence ("never") rules — 19.6% (§8).
  Recorded as 38 scenario sessions (§4a).
- **Status:** §1–§4 are recorded (P4): [`scripts/6-configure-store.ps1`](../scripts/6-configure-store.ps1)
  applies §2, [`scripts/traffic/NopCommerce.Scenarios.ps1`](../scripts/traffic/NopCommerce.Scenarios.ps1)
  holds §4 and [`scripts/7-record-traffic.ps1`](../scripts/7-record-traffic.ps1) records it;
  what a run recorded is in [`results/p4`](../results/p4/README.md). P5 turned §5 into
  [`contract/contract.yaml`](../contract/README.md). Scenario (`T`) and rule (`R`) ids are
  stable so both can cite them.

**Contents**

1. [How the traffic is recorded](#1-how-the-traffic-is-recorded)
2. [Store configuration before recording](#2-store-configuration-before-recording)
3. [Personas](#3-personas)
4. [Scenarios](#4-scenarios) — [4a. As recorded](#4a-as-recorded)
5. [Contract rules](#5-contract-rules)
6. [NLS → ICU probes (for P7)](#6-nls--icu-probes-for-p7)
7. [What the comparator must normalise](#7-what-the-comparator-must-normalise)
8. [Counts](#8-counts)
9. [Failure modes](#9-failure-modes)
10. [Checklist](#10-checklist)

---

## 1. How the traffic is recorded

- **Start state.** `scripts/4-deploy-and-install.ps1` (fresh site, fresh database, the
  installer's sample data), then the configuration of §2, then a SQL Server database
  snapshot (`nopcommerce_legacy_snapshot`, taken by step 7). Every scenario starts from
  that snapshot — when recording, and on legacy and on the candidate in every replay — so
  scenarios are independent of each other and of their order.
- **Through the recording proxy only** (`http://127.0.0.1:8000/` → `:8080`,
  [`TOPOLOGY.md`](TOPOLOGY.md)). A request that bypasses the proxy is not evidence.
- **One scenario, one session.** Each scenario is one browser session with its own cookie
  jar, and every request carries the header `x-bench-scenario: <id>` — the capture's
  session key, so a scenario is one session in the `*.skcap` and one scenario in the
  replay. A story with two people in it is two scenarios (§4a).
- **As a browser would.** The shop's own links and forms; each form posted with every
  field the page gives it; `__RequestVerificationToken` read from the page where it is
  validated. The sample store turns anti-forgery on for the public store
  (`EnableXsrfProtectionForPublicStore = true`,
  `Libraries/Nop.Services/Installation/CodeFirstInstallationService.cs`) and it applies to
  actions marked `[PublicAntiForgery]` — in this set: estimate shipping
  (`ShoppingCartController.GetEstimateShipping`) and registration
  (`CustomerController.Register`). Add-to-cart, cart updates, coupons, login and the
  one-page checkout do not validate it.
- **Probes.** The contract language scopes a clause by method, path and query only, so a
  request whose answer P5 asserts a scenario-specific fact on carries `probe=<name>` in
  its query (`/cart?probe=T11`, `/cart/estimateshipping?probe=T26-1024`). nopCommerce
  ignores unknown query parameters on these routes; the parameter only names the request.
- **Deterministic inputs.** Fixed products, quantities, addresses, coupon codes and
  customers — R1 registers as `r1@nopbench.invalid` every time: every scenario starts
  from the snapshot, so the address is always free.
- **No outbound calls.** Only the offline payment methods (Check / Money Order, Manual)
  and the offline rate providers are used; PayPal and the carrier plugins stay idle, so
  core S16 (outbound stubs) is not needed for this set.

## 2. Store configuration before recording

The sample data leaves the rules this set is about switched off:

- **Tax is zero everywhere.** `Tax.FixedOrByCountryStateZip` installs in fixed-rate mode
  (`CountryStateZipEnabled = false`) and no rate is stored, so every tax category reads
  0 (`Plugins/Nop.Plugin.Tax.FixedOrByCountryStateZip/FixedOrByCountryStateZipTaxProvider.cs`,
  `GetTaxRate` and `Install`).
- **Shipping costs nothing.** `Shipping.FixedOrByWeight` installs in fixed-rate mode with
  no rate stored, and a missing rate reads 0
  (`Plugins/Nop.Plugin.Shipping.FixedOrByWeight/FixedOrByWeightComputationMethod.cs`,
  `GetRate` line 63 and `Install`).
- **Neither sample coupon changes a price.** `123` is a $10 discount "assigned to SKUs"
  that no product is mapped to; `456` (20% of the order total) ended on 2020-01-01
  (`CodeFirstInstallationService.InstallDiscounts`).

So P4 first configures the store through the admin UI — seeding through the running
system, never through SQL — with the administrator credentials step 4 generated:

| Area | Configuration | Used by |
|---|---|---|
| Tax provider | Switch to "by country / state / zip". Tax category *Electronics & Software*: US / New York / zip `10001` → 9.000%; US / New York / any zip → 8.875%; US / California → 7.250%; US / any state → 5.000%; Canada / Ontario / zip `K1A 0B1` → 13.000%. Nothing for Germany. Mark "Apple MacBook Pro 13-inch" tax exempt. | T21–T23 |
| Shipping | Fixed rate per method: Ground $10.00, 2nd Day Air $25.00, Next Day Air $40.00. Free shipping over $1,000.00, excluding tax. | T24–T26 |
| Discounts (each needs its coupon, so none leaks into other scenarios) | `SAVE10` 10% of order subtotal · `TAKE50` $50.00 off order total · `PCT20MAX100` 20% of order subtotal, maximum $100.00 · `SHIPFREE` 100% of shipping · `ONCE5` $5.00 off order total, 1 time per customer · `FUTURE10` 10% of order subtotal from 2099-01-01 · `MEMBERS15` 15% of order subtotal, requirement "customer role is Registered" (`DiscountRules.CustomerRoles`) | T11–T20 |
| Background tasks | Disable the schedule tasks the sample install enables — "Send emails" (every 60 s), "Keep alive" (300 s), "Delete guests" (600 s), "Update currency exchange rates" (3600 s, an outbound call) — and restart the application. 3.90 runs them on timers inside the web application, and `Task.Execute` reads its task row before its `try` (`Libraries/Nop.Services/Tasks/Task.cs`): under a database restore that read throws on a timer thread and takes the worker process down, and the shop answers 500 until it has restarted. Every scenario starts with a restore. | every scenario |
| Catalog | Unpublish "HP Envy 6-1180ca 15.6-Inch Sleekbook", and switch off the catalog setting "Allow viewing of unpublished product details page" — the sample install turns it on (`AllowViewUnpublishedProductPage = true`), which serves an unpublished product's page to anyone, marked "discontinued" (`ProductController.ProductDetails`, line 119). Stock of "Lenovo IdeaCentre 600 All-in-One PC" to 3 (it already manages stock without backorders). | T02, T05–T07, T28 |

Currency (USD, display locale `en-US`), tax display (excluding tax), price rounding
during calculation, anonymous checkout and one-page checkout stay as installed. Every
change is read back from the admin UI, and a settings or product form posted back is
re-read and compared field by field, so nothing else changes unnoticed.

## 3. Personas

| Persona | Who | Notes |
|---|---|---|
| G1 | A guest shopper | Own cookie jar |
| G2 | A second guest | Tries to reach someone else's order |
| R1 | A customer who registers in T28 | `r1@nopbench.invalid`, with the password it registers with |
| S1 | Sample customer `steve_gates@nopCommerce.com` | Registered; owns sample order 1. Password: the one the installer gives its sample customers (`CodeFirstInstallationService.InstallCustomersAndUsers`) — public sample data, not a secret |

Sample order 2 belongs to `arthur_holmes@nopCommerce.com` (`InstallOrders`), who never
acts; his order is the "someone else's order" in T30. The administrator configures §2 and
appears in no scenario.

## 4. Scenarios

| ID | Area | Persona | Steps | Business rule exercised | Source |
|---|---|---|---|---|---|
| T01 | Catalog | G1 | `GET /` | Home page lists the products flagged "show on home page"; footer attribution | `ProductController.HomepageProducts` (line 410), `Views/Common/Footer.cshtml` |
| T02 | Catalog | G1 | `GET /notebooks`, then `?orderby=10`, `?orderby=5`, `?pagesize=3&pagenumber=2` | Category listing: published products only, sorted by price or name, paged | `ProductService.SearchProducts` → `App_Data/Install/SqlServer.StoredProcedures.sql` (`ProductLoadAllPaged`, line 80, `@OrderBy`) |
| T03 | Catalog | G1 | `GET /computers` | A parent category lists its subcategories | `CatalogController.Category`, `CatalogModelFactory` |
| T04 | Catalog | G1 | `GET /lenovo-ideacentre-600-all-in-one-pc`, `/apple-macbook-pro-13-inch`, `/build-your-own-computer` | Product page: name, SKU, price, attributes with price adjustments | `ProductController.ProductDetails`, `ProductModelFactory` |
| T05 | Catalog | G1 | `GET /hp-envy-6-1180ca-156-inch-sleekbook` (unpublished in §2) | An unpublished product is not shown | `ProductController.ProductDetails` |
| T06 | Search | G1 | `GET /search?q=apple`, `?q=APPLE`, `?q=AP_MBP_13`, `?q=ap`, `?q=%20apple%20` | Keyword search on names (database collation), exact SKU match, trimmed input, minimum length 3 | `CatalogModelFactory.PrepareSearchModel` (line 1362), `ProductLoadAllPaged` (`PATINDEX`, `Sku = @OriginalKeywords`, `rtrim(ltrim(@Keywords))`) |
| T07 | Cart | G1 | Add the Lenovo from `/desktops` (quantity 1), then from its product page with quantity 5 | Add to cart; stock limit without backorders | `ShoppingCartController.AddProductToCart_Catalog` (line 496), `AddProductToCart_Details`, `ShoppingCartService.GetStandardWarnings` (line 286) |
| T08 | Cart | G1 | Add the MacBook with quantity 1, then 2 | Minimum order quantity (2 in the sample) | `GetStandardWarnings` (`OrderMinimumQuantity`) |
| T09 | Cart | G1 | Add "Build your own computer" without its required attributes, then with Processor, RAM and HDD chosen | Required attributes; attribute price adjustments in the unit price | `ShoppingCartService.GetShoppingCartItemAttributeWarnings`, `PriceCalculationService.GetUnitPrice` |
| T10 | Cart | G1 | Two lines in the cart; `POST /cart` `updatecart` with `itemquantity{id}=3`; then tick `removefromcart` on one line; then `itemquantity{id}=0` on the other | Quantity update; removal by checkbox; quantity 0 removes | `ShoppingCartController.UpdateCart` (line 1279), `ShoppingCartService.UpdateShoppingCartItem` (line 1208) |
| T11 | Discounts | G1 | Lenovo × 2 ($1,000.00); `POST /cart` `applydiscountcouponcode` with `SAVE10` | Percentage discount on the order subtotal | `ShoppingCartController.ApplyDiscountCoupon` (line 1402), `OrderTotalCalculationService.GetOrderSubtotalDiscount`, `DiscountExtensions.GetDiscountAmount` (line 16) |
| T12 | Discounts | G1 | Apply ` save10 ` (spaces, lower case); on a fresh cart apply `SAVE10` followed by U+180E | Coupon input is trimmed and matched without regard to case | `ApplyDiscountCoupon` (`Trim()`), `DiscountService.GetAllDiscounts` (SQL `=` under the database collation), `DiscountService.ValidateDiscount` (line 517, `InvariantCultureIgnoreCase`) |
| T13 | Discounts | G1 | Apply `456` (sample, expired), `FUTURE10`, `NOSUCH` | Expired, not-yet-started and unknown coupons are refused, each with its own message | `ValidateDiscount` (date range), `ApplyDiscountCoupon` (not found) |
| T14 | Discounts | G1 | "Pride and Prejudice" ($24.00, ships, no tax rate for Books); check out to confirm with Ground; apply `TAKE50` | A fixed order-total discount larger than the whole order | `OrderTotalCalculationService.GetShoppingCartTotal` (cap at line 1250, then floor at zero) |
| T15 | Discounts | G1 | MacBook × 2 ($3,600.00); apply `PCT20MAX100` | Maximum amount of a percentage discount | `DiscountExtensions.GetDiscountAmount` (`MaximumDiscountAmount`) |
| T16 | Discounts | G1 | Lenovo × 1; check out to the confirm step with Ground; apply `SHIPFREE` | Discount on shipping | `OrderTotalCalculationService.GetShippingDiscount` |
| T17 | Discounts | G1 | "$25 Virtual Gift Card" and "Pride and Prejudice" in the cart; apply `SAVE10` | Subtotal and total discounts are refused while the cart holds a gift card | `ValidateDiscount` (gift-card rule) |
| T18 | Discounts | G1, S1 | Apply `MEMBERS15` as G1; log in as S1 and apply it | Discount requirement on a customer role | `ValidateDiscount` (requirements), `Plugins/Nop.Plugin.DiscountRules.CustomerRoles` |
| T19 | Discounts | S1 | Place an order with `ONCE5`; fill a new cart and apply `ONCE5` again | "N times per customer" limitation, tracked for registered customers | `ValidateDiscount` (`NTimesPerCustomer`), `OrderProcessingService.PlaceOrder` (discount usage history) |
| T20 | Discounts | G1 | Apply the sample coupon `123` | A SKU discount mapped to no product is accepted and changes nothing | `ApplyDiscountCoupon`, `InstallDiscounts` |
| T21 | Tax | G1 | Lenovo × 1; check out with billing address US / New York / `10001`; stop at confirm | Rate by country, state and exact zip | `FixedOrByCountryStateZipTaxProvider.GetTaxRate` (line 48) |
| T22 | Tax | G1 | As T21 with billing US / New York / `10002`, then US / California, US / Texas, Germany; then MacBook × 2 with US / New York / `10001` | Fallbacks (any zip, any state, no rate) and a tax-exempt product | `GetTaxRate`; `TaxService.GetTaxRate` / `IsTaxExempt` |
| T23 | Tax | G1 | As T21 with billing Canada / Ontario / `k1a 0b1` (lower case) | The zip match ignores case | `GetTaxRate` (`InvariantCultureIgnoreCase`) |
| T24 | Shipping | G1 | Lenovo × 1: check out to the shipping-method step; separately estimate shipping on `/cart` for US / New York / `10001` | Methods and fixed rates; the estimate matches checkout | `FixedOrByWeightComputationMethod.GetShippingOptions` (line 125), `ShoppingCartController.GetEstimateShipping` |
| T25 | Shipping | G1 | MacBook × 2 only (a free-shipping product); estimate shipping | Free shipping when every item ships free | `OrderTotalCalculationService.IsFreeShipping` (line 798) |
| T26 | Shipping | G1 | Lenovo × 2 ($1,000.00 exactly), estimate; add "Pride and Prejudice", estimate again | "Free shipping over X" means strictly over | `IsFreeShipping` (`subTotal > FreeShippingOverXValue`) |
| T27 | Checkout | G1 | Guest one-page checkout: Lenovo × 1, billing US / New York / `10001`, ship to the same address, Ground, Check / Money Order, confirm; `GET /checkout/completed/{id}`, `GET /orderdetails/{id}` | Guest checkout end to end; totals recomputed on the server | `CheckoutController.Opc*`, `OrderProcessingService.PlaceOrder` (line 1203) |
| T28 | Checkout | R1 | Register at `/register`; Lenovo × 2 with `SAVE10`; Next Day Air; payment Manual, first with card `4111 1111 1111 1112`, then `4111 1111 1111 1111`; confirm; open the Lenovo page | Registered checkout; card check digit; stock decreases (3 → 1); cart emptied | `Plugins/Nop.Plugin.Payments.Manual/Validators/PaymentInfoValidator.cs`, `Presentation/Nop.Web.Framework/Validators/CreditCardPropertyValidator.cs`, `PlaceOrder` (lines 1352–1357) |
| T29 | Orders | S1 | Log in; `GET /order/history`, `/orderdetails/1`, `/orderdetails/pdf/1` | Order history and details of one's own order | `OrderController.CustomerOrders` (line 64), `Details` (line 156), `GetPdfInvoice` (line 181) |
| T30 | Orders | G1, G2, S1 | G1 places a guest order (as T27); G2 requests its `/orderdetails/{id}`, `/orderdetails/print/{id}`, `/orderdetails/pdf/{id}`, `/reorder/{id}` and `/order/history`; S1 requests `/orderdetails/2` | Nobody sees or reorders someone else's order; guests have no order history | `OrderController` (`order.CustomerId != CurrentCustomer.Id` → 401; Forms authentication turns a 401 into a redirect to `/login`) |

## 4a. As recorded

The table above is the plan; the recording follows it with these refinements, each
forced by one scenario being one session that starts from the snapshot, or by what the
shop turned out to do. Recorded: **38 scenario sessions** covering the 30 planned, 290
exchanges ([`results/p4`](../results/p4/README.md)).

| Planned | Recorded as | Why |
|---|---|---|
| T12 | T12 (` save10 `), T12B (`SAVE10`+U+180E) | "On a fresh cart" is a fresh session |
| T18 | T18A (G1), T18B (S1) | Two people, two sessions |
| T22 | T22A (US/NY/`10002`), T22B (US/CA), T22C (US/TX), T22D (Germany), T22E (MacBook × 2, US/NY/`10001`) | One address per checkout, each from the snapshot |
| — | T22F: billed to US/NY/`10001`, shipped to US/TX; tax is New York's | R30 ("tax follows the billing address") needs a billing address that differs from the shipping one; in T21–T23 they are the same |
| T27 | `GET /checkout/completed/` without the id | What the checkout script requests (`ConfirmOrder.init(…, '…checkout/completed/')`); the page shows the customer's last order |
| T28 "open the Lenovo page" | Adding 2 more Lenovos is refused: "The maximum quantity that can be added is 1." | Shows the stock went 3 → 1 in an answer, not just on a page |
| T30 | T30A (G2: details, print, PDF and reorder of order 2, and `/order/history`), T30B (S1: `/orderdetails/2`) | G1's order would not exist in G2's session — every scenario starts from the snapshot — so "someone else's order" is sample order 2, Arthur Holmes's |

What scripting and recording the set showed, for P5 to assert and P7 to compare:

- **T05 needs the catalog setting of §2.** Unpublishing alone leaves the product page
  open to everyone (`AllowViewUnpublishedProductPage = true` in the sample settings).
- **A restore under a running schedule task crashes the shop** — hence the background
  tasks row of §2. Seen once in the first full recording: the first requests after a
  restore were answered 500, then the application started again.
- **Checkout starts at the cart's Checkout button.** The sample store has a required
  checkout attribute, "Gift wrapping", saved when the cart form is posted
  (`ShoppingCartController.StartCheckout`); an order from a customer who went straight to
  `/onepagecheckout` is refused with "Please select Gift wrapping;". Every checkout in the
  set goes cart → Checkout → (guest: "Checkout as Guest") → `/checkout` → one-page
  checkout, as a browser does.
- **The shipping estimate also offers in-store pickup, "Pickup ($1.99)"** — the sample
  pickup point — and free shipping does not waive that fee: a cart of MacBooks is
  estimated $0.00 for every shipping method and $1.99 for pickup (T25). R33 and R34 hold
  for the shipping methods; the pickup option is recorded as it is.
- **T18A: the customer-role requirement refuses with an empty message.** The rule sets no
  `UserError`, `ValidateDiscount` passes that `null` on, and `ApplyDiscountCoupon` shows
  it as the only message — the coupon box holds one empty failure message, not "The
  coupon code you entered couldn't be applied"
  (`Plugins/Nop.Plugin.DiscountRules.CustomerRoles/CustomerRoleDiscountRequirementRule.cs`,
  `DiscountService.GetValidationResult`, `ShoppingCartController.ApplyDiscountCoupon`).
  R24 holds; the message is legacy behaviour a migration may "fix".
- **T12B: `SAVE10` followed by U+180E is refused** ("The coupon code you entered couldn't
  be applied to your order") on .NET Framework 4.8.
- **Negative amounts are written in parentheses**: `($100.00)`, `($34.00)`, `($75.00)` —
  the en-US currency format of .NET Framework 4.8 on Windows Server 2022 (§6's first
  probe).
- **A zero order total skips the payment steps** (`CheckoutController.OpcLoadStepAfterShippingMethod`).
  T14 therefore checks out first and applies `TAKE50` last, as planned.

Requests that carry a probe: T07, T08, T09 (the refused add and the cart);
T10-quantity, T10-remove, T10-zero; T11, T12, T12B, T13-expired, T13-future,
T13-unknown, T14, T15, T16, T17, T18A, T18B, T19, T20 (the coupon answer or the cart);
T21, T22A–T22F, T23 (the cart after checkout); T24 (the estimate and the billing step's
answer, which lists the shipping methods); T25, T26-1000, T26-1024 (estimates); T27 (the
completed page and the order details); T28 (the refused card, the completed page, the
order details, the empty cart `T28-after`, the refused add); T29 (the order history);
T30A and T30B (every request: the guest's order history is refused on a URL Steve also
uses, so each needs its name).

## 5. Contract rules

A `must` rule states what a response or the resulting state contains; a `never` rule
states what must be absent. "Shown" means in the HTML of the page named in the
scenario; order facts can also be asserted on the database delta (core S4).

| Rule | Kind | Statement | Scenarios | Source |
|---|---|---|---|---|
| R01 | must | Every storefront page answers 200 and carries the "Powered by nopCommerce" footer | T01–T04, T06, T27 | `Views/Common/Footer.cshtml` |
| R02 | must | The home page lists the published, visible products flagged "show on home page", and no others | T01 | `ProductService.GetAllProductsDisplayedOnHomePage`, `ProductController.HomepageProducts` |
| R03 | must | A listing sorted by price (`orderby=10`) is non-decreasing in price; sorted by name (`orderby=5`) it follows the database collation | T02 | `ProductLoadAllPaged` (`@OrderBy`) |
| R04 | must | Paging returns `pagesize` products per page and the same total count on every page | T02 | `ProductLoadAllPaged` (`@PageIndex`, `@PageSize`) |
| R05 | never | An unpublished product never appears in a listing, in search results or on its own product page | T02, T05, T06 | `ProductLoadAllPaged` (published filter), `ProductController.ProductDetails` |
| R06 | must | A product page shows the product's name, SKU and price (`$500.00` for the Lenovo) | T04 | `ProductModelFactory`, `CatalogSettings.ShowSkuOnProductDetailsPage = true` |
| R07 | must | `apple` and `APPLE` return the same products; `AP_MBP_13` finds the MacBook by SKU | T06 | `ProductLoadAllPaged` (`PATINDEX` under `SQL_Latin1_General_CP1_CI_AS`; `Sku = @OriginalKeywords`) |
| R08 | must | A term shorter than 3 characters answers "Search term minimum length is 3 characters" and lists no product | T06 | `CatalogModelFactory.PrepareSearchModel` (line 1362) |
| R09 | must | Adding a product answers `"success":true` and the cart then shows it with the added quantity | T07 | `AddProductToCart_Catalog`, `ShoppingCartService.AddToCart` |
| R10 | must | A quantity above stock is refused with "Your quantity exceeds stock on hand. The maximum quantity that can be added is 3." | T07 | `GetStandardWarnings` (`BackorderMode.NoBackorders`) |
| R11 | must | A quantity below the minimum is refused with "The minimum quantity allowed for purchase is 2." | T08 | `GetStandardWarnings` (`OrderMinimumQuantity`) |
| R12 | must | Adding a product without a required attribute is refused with the attribute's warning | T09 | `GetShoppingCartItemAttributeWarnings` |
| R13 | must | A line total is unit price (with attribute adjustments) × quantity; the subtotal is the sum of line totals | T09, T10 | `PriceCalculationService.GetSubTotal`, `OrderTotalCalculationService.GetShoppingCartSubTotal` (line 244) |
| R14 | must | Setting a quantity to 0, or ticking "remove", deletes the line | T10 | `UpdateCart`, `UpdateShoppingCartItem` (`quantity > 0`, else delete) |
| R15 | must | `SAVE10` on a $1,000.00 subtotal shows a $100.00 discount and a $900.00 discounted subtotal | T11 | `GetOrderSubtotalDiscount`, `GetDiscountAmount` |
| R16 | must | A percentage discount is `amount × percent / 100` computed in single-precision floating point, then rounded to cents half to even | T11, T15 | `DiscountExtensions.GetDiscountAmount` (`float`), `RoundingHelper.Round` (`Math.Round(value, 2)`) |
| R17 | must | A coupon is accepted regardless of letter case and surrounding white space ("The coupon code was applied") | T12 | `ApplyDiscountCoupon` (`Trim()`), `ValidateDiscount` (`InvariantCultureIgnoreCase`) |
| R18 | must | An expired coupon answers "Sorry, this offer is expired", a future one "Sorry, this offer is not started yet", an unknown one "The coupon code you entered couldn't be applied to your order" | T13 | `ValidateDiscount` (date range), `ApplyDiscountCoupon` |
| R19 | never | A discount is never applied before its start date or after its end date | T13 | `ValidateDiscount` (date range) |
| R20 | never | A discount never makes an order total negative: the order-total discount is capped at the pre-discount total | T14 | `GetShoppingCartTotal` (line 1250, then `resultTemp < decimal.Zero`) |
| R21 | must | A percentage discount never exceeds its maximum (`PCT20MAX100` on $3,600.00 gives $100.00) | T15 | `GetDiscountAmount` (`MaximumDiscountAmount`, percentage discounts only) |
| R22 | must | `SHIPFREE` brings the shipping total to $0.00 | T16 | `GetShippingDiscount` |
| R23 | never | A subtotal or total discount is never applied while the cart holds a gift card ("Sorry, this discount cannot be used with gift cards in the cart") | T17 | `ValidateDiscount` (`CannotBeUsedWithGiftCards`) |
| R24 | never | A discount that requires the Registered role is never applied to a guest | T18 | `ValidateDiscount` (requirements), `DiscountRules.CustomerRoles` |
| R25 | must | A customer who used `ONCE5` once is refused the second time: "Sorry, you've used this discount already" | T19 | `ValidateDiscount` (`NTimesPerCustomer`), `PlaceOrder` (usage history) |
| R26 | must | Coupon `123` is reported as applied, and every price and total stays as it was | T20 | `ApplyDiscountCoupon`, `InstallDiscounts` |
| R27 | must | The totals block shows a discount as a negative currency amount | T11, T14, T15 | `Factories/ShoppingCartModelFactory.cs` lines 1074 and 1166 (`FormatPrice(-amount)`), `PriceFormatter.GetCurrencyString` (line 64) |
| R28 | must | Tax on *Electronics & Software* items: 9% for US/NY/10001, 8.875% for US/NY/10002, 7.25% for US/CA, 5% for US/TX, 0 for Germany | T21, T22 | `FixedOrByCountryStateZipTaxProvider.GetTaxRate` (store, then state, then zip precedence) |
| R29 | must | `k1a 0b1` matches the rate stored for `K1A 0B1` (13%) | T23 | `GetTaxRate` (`InvariantCultureIgnoreCase`) |
| R30 | must | Tax follows the billing address (`TaxBasedOn = BillingAddress`) | T21–T23 | `TaxService.CreateCalculateTaxRequest` |
| R31 | must | A subtotal discount reduces the tax proportionally: tax is charged on the discounted subtotal | T28 | `GetShoppingCartSubTotal` (`discountTax = tax × discount / subtotal`) |
| R32 | never | A tax-exempt product is never taxed, whatever the address | T22 | `TaxService.IsTaxExempt`, `TaxService.GetTaxRate` |
| R33 | must | The shipping step offers Ground $10.00, 2nd Day Air $25.00 and Next Day Air $40.00, and the estimate on the cart shows the same | T24 | `FixedOrByWeightComputationMethod.GetShippingOptions` |
| R34 | must | A cart whose every item ships free costs $0.00 to ship, whatever the method | T25 | `IsFreeShipping` (all items free) |
| R35 | must | A subtotal of exactly $1,000.00 pays for shipping; above $1,000.00 shipping is free | T26 | `IsFreeShipping` (`>` rather than `>=`) |
| R36 | must | Order total = discounted subtotal + (shipping − shipping discount) + tax − order-total discount, rounded to cents | T27, T28 | `GetShoppingCartTotal` |
| R37 | must | A placed order's totals on the completed and details pages equal the totals shown at confirm | T27, T28 | `PlaceOrder` (`GetShoppingCartTotal` again on the server) |
| R38 | must | A guest checks out without registering and is shown the order number | T27 | `OrderSettings.AnonymousCheckoutAllowed`, `CheckoutController.Completed` |
| R39 | never | No order is placed with a card number that fails the check digit ("Wrong card number") | T28 | `CreditCardPropertyValidator.IsValid` |
| R40 | must | Placing an order lowers stock by the ordered quantity and empties the cart | T28 | `PlaceOrder` (`AdjustInventory`, `DeleteShoppingCartItem`) |
| R41 | must | A new order is Pending; with Check / Money Order its payment is Pending too | T27 | `PlaceOrder` (`OrderStatus.Pending`), `CheckMoneyOrderPaymentProcessor.ProcessPayment` |
| R42 | must | Order history lists exactly the customer's own orders, newest first | T29 | `OrderController.CustomerOrders`, `OrderService.SearchOrders` (`OrderByDescending(o => o.CreatedOnUtc)`) |
| R43 | must | A customer opens the details and the PDF invoice of an own order | T29 | `OrderController.Details`, `GetPdfInvoice` |
| R44 | never | Nobody ever sees another customer's order: details, print view and PDF of someone else's order redirect to `/login` and carry none of the order's data | T30 | `OrderController.Details`, `PrintOrderDetails`, `GetPdfInvoice` (`CustomerId` check) |
| R45 | never | A guest never gets an order history, and nobody reorders someone else's order | T30 | `OrderController.CustomerOrders` (`IsRegistered`), `ReOrder` (`CustomerId` check) |
| R46 | must | Amounts in USD are shown as `$#,##0.00` | every priced page | `PriceFormatter.GetCurrencyString` (`ToString("C", new CultureInfo("en-US"))`) |

## 6. NLS → ICU probes (for P7)

The work plan's "aha" candidate: moving from .NET Framework to modern .NET switches
globalization from NLS to ICU. These are the places in nopCommerce 3.90 where culture
data reaches something a customer sees, and the scenario that already probes each one.
They are hypotheses for P7 to confirm or refute, not findings.

| Probe | Code path | Why it may differ | Where |
|---|---|---|---|
| **Negative currency amounts** in the cart totals | `ShoppingCartModelFactory` formats `-discount` through `PriceFormatter.GetCurrencyString`: `ToString("C", new CultureInfo("en-US"))` | NLS formats a negative en-US currency amount as `($100.00)`; ICU's en-US data as `-$100.00`. The strongest candidate. | T11, T14, T15 — R27 |
| Coupon case folding | `CustomerExtensions.ApplyDiscountCouponCode` (line 132) stores `couponCode.Trim().ToLower()` — **current** culture; `ValidateDiscount` compares with `InvariantCultureIgnoreCase` | Culture-sensitive casing and comparison of non-ASCII input can differ between NLS and ICU. For a stronger signal P4 can add coupon codes with non-ASCII letters (e.g. `ß`, `İ`) to §2. | T12 — R17 |
| Coupon trimming | `ApplyDiscountCoupon` calls `String.Trim()` | `Trim()` follows the runtime's Unicode data. U+180E was white space in older Unicode versions and is not in newer ones, so one runtime may trim `SAVE10`+U+180E into a valid coupon and the other not. | T12 |
| Zip comparison | `FixedOrByCountryStateZipTaxProvider.GetTaxRate` (`InvariantCultureIgnoreCase`) | Culture-sensitive comparison; only letters can differ, so Canadian codes are the probe | T23 — R29 |
| Name sorting | `ProductLoadAllPaged` sorts in SQL | Not culture data in .NET: the database collation decides. A difference here means the candidate moved sorting into .NET. | T02 — R03 |
| Dates and times | order dates on the details and history pages | Newer ICU data puts a narrow no-break space before AM/PM in en-US times | T29 |

## 7. What the comparator must normalise

Values that differ between two runs of the same system (core S12):

- the `Nop.customer` cookie and every customer GUID;
- anti-forgery tokens (`__RequestVerificationToken` fields and cookies) and the
  `ASP.NET_SessionId` and `NOPCOMMERCE.AUTH` cookies;
- order GUIDs and every timestamp (order dates, "created on", the `Date` header) —
  nopCommerce reads `DateTime.UtcNow` directly, and the legacy code is not touched to fake
  it;
- `Content-Length` and similar transport headers that follow from normalised bodies.

Order numbers are **not** normalised: from the same snapshot and the same requests, the
ids must match on both sides (`CustomOrderNumberMask = "{ID}"` in the sample settings).

**As built (P5, [`contract/contract.yaml`](../contract/contract.yaml)).** The contract
compares the status, two headers (`content-type`, `location`) and each page through what its
extractors read (`html: extracts`), so cookies, the `Date` header, `Content-Length` and the
other values above never reach the comparison. Three masks cover what still differs where
JSON or a whole body is compared: `anti-forgery-token`, `pdf-bytes` and
`cart-line-picture`.

## 8. Counts

| | Count |
|---|---|
| Scenarios | 30 (T01–T30), recorded as 38 sessions (§4a) |
| Rules | 46 (R01–R46) |
| `must` | 37 |
| `never` (absence) | 9 — R05, R19, R20, R23, R24, R32, R39, R44, R45 — 19.6% |

## 9. Failure modes

| Symptom | Cause |
|---|---|
| Every tax and shipping amount in the recording is $0.00 | §2 was skipped: the sample data ships without rates |
| A coupon passes on legacy and is "not found" on the candidate | The candidate's discount lookup moved from SQL (collation, case-insensitive) into memory (ordinal) |
| Replays diverge from the first scenario on | A replay did not start from the S11 snapshot, or the recording bypassed the proxy |
| A `never` rule passes without checking anything | The scenario never reached what the rule guards (for example T30 without a real order id): each `never` rule needs its positive twin in the same scenario — R44 with T30's own redirect to `/login` (the contract's `OTHERS-ORDER-SENDS-TO-LOGIN`; R43 is T29, another scenario), R24 with the registered half of T18, R39 with the valid card in T28 |
| Order ids drift between legacy and candidate | Scenarios ran from different snapshots, or an extra request created an order |

## 10. Checklist

- [ ] §2 applied through the admin UI, then the S11 snapshot taken
- [ ] Every request of every scenario went through the recording proxy
- [ ] Each persona used its own cookie jar; anti-forgery tokens read from the page where validated
- [ ] Every rule in §5 is exercised by a recorded scenario, and every `never` rule has its positive twin
- [ ] The scenario count and the legacy site manifest digest (step 2 records it in `state\build.json`; step 4 takes the same digest of `state\legacy-site.sha256` into `state\deploy.json`, where step 7 reads it) are recorded with the `*.skcap`
- [ ] The NLS → ICU probes of §6 are in the recording

Worked examples: nopCommerce 3.90 at `12d1f01` — `Libraries/Nop.Services/Discounts/`,
`Libraries/Nop.Services/Orders/OrderTotalCalculationService.cs`,
`Libraries/Nop.Services/Tax/TaxService.cs`,
`Plugins/Nop.Plugin.Tax.FixedOrByCountryStateZip/`,
`Plugins/Nop.Plugin.Shipping.FixedOrByWeight/`,
`Presentation/Nop.Web/Controllers/OrderController.cs`.
