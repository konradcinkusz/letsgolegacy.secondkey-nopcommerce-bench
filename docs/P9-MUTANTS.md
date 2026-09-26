# P9 — killed mutants

P9 publishes the bench's numbers, and one of them is **killed mutants**: defects put into
the legacy shop on purpose, to show that the contract notices when behaviour changes.
Mutation testing proper — `sk mutate`, component C9 — is phase-02 work. The phase-01
substitute is small and honest: a hand-written set of defects injected into nopCommerce
3.90's source, each aimed at named clauses of the [P5 contract](../contract/contract.yaml),
replayed against the legacy shop and compared exactly as the P7 candidate will be. Nothing
new in `sk`: a mutant goes through the same `sk replay` and `sk compare` as a migration.

**This page is the pre-registration.** It, the catalog
[`mutants/mutants.json`](../mutants/mutants.json) and every `mutants/*.patch` were
committed together, in one commit, before the first mutant run. What each mutant is
expected to break was written down before any of them ran. What they did is in
[`results/p9`](../results/p9/README.md).

## Rules

1. **One mutant is one patch.** A unified diff in [`mutants/`](../mutants/) against
   nopCommerce `release-3.90` (commit `12d1f01`) exactly as
   [`scripts/1-fetch-nopcommerce.ps1`](../scripts/1-fetch-nopcommerce.ps1) delivers it —
   most of its sources end their lines with CRLF, and so do the patch lines that quote them
   ([`.gitattributes`](../.gitattributes) keeps the patches byte for byte). Its catalog
   entry names the file and member it changes, what it changes, why that is a defect a
   migration could plausibly introduce, and the clauses expected to catch it.
2. **Small, plausible, behavioural.** A boundary, a dropped check, a comparison that loses
   its case rule, the wrong address for tax, a missing cap or clamp, a lost field — the
   kind of defect a migration introduces. Never a change that takes the site down: a
   mutant must answer the traffic, or it tests nothing but the build.
3. **Killed** means `sk compare`'s outcome is `fail`: at least one exchange is a
   `regression`, whether a clause that held on the legacy side did not hold on the mutant
   (`clause-regression`), a difference nothing in the contract explains
   (`uncovered-difference`), or an answer missing. Any other outcome — `pass`, or `review`
   (fix candidates only) — means the mutant **survived**.
4. **Written down first, never edited after.** The clauses expected to catch each mutant
   are never changed once a result has been seen. A patch that does not apply or does not
   build is fixed in its own later commit whose message says why; history is kept, never
   rewritten.
5. **Results are reported as they are.** A survivor is reported as survived, with what the
   contract missed and why. The contract is not changed in this ticket to kill a survivor:
   that is a finding for the contract's next revision, made on its own merits.
6. **M00 calibrates the method.** M00 changes nothing: the pinned source, built a second
   time and deployed exactly like every mutant. Its replay must come out `pass` — an A/A
   replay across two application instances. A run whose M00 is not `pass` counts no
   mutant result: the second site would then differ from the first for a reason that is
   not code, and a "kill" could be that reason.
7. **The headline counts M01–M11**, "N of 11 mutants killed". M00 is not a mutant to kill.

## Method

### A mutant is a second site on the legacy shop's database

The replay has to reset both sides to the same state before every scenario, and the
contract's [`secondkey.yaml`](../contract/secondkey.yaml) does that by restoring one
database snapshot. So the mutant runs **beside the legacy shop, on its database**
([`scripts/mutants/2-deploy-mutant.ps1`](../scripts/mutants/2-deploy-mutant.ps1)):

- its published files in their own folder, `C:\inetpub\nopcommerce-mutant`, checked
  against the manifest its build wrote;
- the legacy install's `App_Data\Settings.txt` (the connection string) and
  `App_Data\InstalledPlugins.txt` copied in, so it opens the database the legacy installer
  created and step 6 configured — no second install, no second configuration;
- its own IIS site and application pool, `nopcommerce-mutant`, on
  `http://localhost:8091/` (8081 is the P3 warm-up's, 8090 the P7 candidate's), configured
  as step 4 configures the legacy one;
- its own Windows login, with `db_owner` in `nopcommerce_legacy` — the rights the legacy
  site has as the database's owner. The database user is created **before step 7 takes
  the snapshot**, so every restore keeps it; a snapshot taken before it existed is refused.

Both sides are then restored from the same `nopcommerce_legacy_snapshot` before every
scenario and start it from identical data, and `contract/secondkey.yaml` works unchanged:
`scripts/8-replay.ps1 -Candidate http://localhost:8091/` replays legacy against the mutant.

The two sites answer on different ports, and nopCommerce builds absolute URLs from the
request's host. That is not a difference: `sk replay` sends each side its own host, and
`sk compare` replaces each side's own base URL with `<base-url>` before comparing.

### One CI job per mutant

[`mutants.yml`](../.github/workflows/mutants.yml) runs on every pull request that touches
`mutants/`, `scripts/mutants/` or the workflow, and on demand:

| Job | Runner | What it does |
|---|---|---|
| plan | Linux | checks the catalog and every patch against the pinned tree ([`1-check-mutants.ps1`](../scripts/mutants/1-check-mutants.ps1)); the matrix |
| build | Windows | the legacy site, built once for every mutant (steps 1–2) |
| mutant × 12 | Windows (`windows-2022`, as the legacy job) | the mutant built — steps 1–2 with `-Patch`, in a work root of its own; the legacy shop installed, smoke-tested and configured (steps 3–6); the mutant deployed beside it; the traffic set recorded on the legacy shop (step 7); legacy replayed against the mutant (step 8) |
| verdict × 12 | Linux | `sk compare` and the evidence pack (step 9); killed or survived ([`3-mutant-outcome.ps1`](../scripts/mutants/3-mutant-outcome.ps1)) |
| summary | Linux | every outcome in `mutants.json` ([`4-collect-mutants.ps1`](../scripts/mutants/4-collect-mutants.ps1)); fails unless M00 passed |

Step 2 builds a mutant with `-Patch`: the checkout must be the clean pinned tree, the
patch is applied, the tree is checked to hold exactly the patch before and after the
build, and the patched files are restored afterwards. Without `-Patch` — how the legacy
site is always built — step 2 is unchanged.

### What "caught by" means

For each mutant the verdict gives the clauses whose status is `regressed` — held on the
legacy side, failed or unreadable on the mutant — and the exchanges classified as
`regression`, each by the first reason that applies (sk's order: a missing answer, then a
clause, then an uncovered difference). The results put them beside the clauses expected
to catch the mutant.

One expectation depends on that rule and is stated here in advance. **M04** takes the
order total below zero, and .NET Framework writes a negative amount in parentheses,
`($16.00)`. The contract's `cartTotal` extractor reads a decimal in `en-US` without
parentheses, so it cannot read that value, and sk counts an unreadable value against the
side it happened on. `CART-TOTAL-NEVER-NEGATIVE` is therefore expected to regress as an
error, not through its `lt 0`.

## The mutants

Each patch is against nopCommerce `release-3.90` (`12d1f01`); traffic scenarios are the
[traffic plan](P4-TRAFFIC-PLAN.md)'s.

| Id | Patch | File, member | Change | Intent | Clauses expected to catch it |
|---|---|---|---|---|---|
| M00 | — | — | none | Calibration: two builds of the same code, as two sites on one database, replayed against each other. | none — it must pass |
| M01 | [`M01-free-shipping-at-the-threshold.patch`](../mutants/M01-free-shipping-at-the-threshold.patch) | `Nop.Services/Orders/OrderTotalCalculationService.cs`, `IsFreeShipping` | `subTotal > FreeShippingOverXValue` becomes `>=` | A boundary slip: T26's cart of exactly $1,000.00 is estimated Ground ($0.00). | `NO-FREE-SHIPPING-AT-EXACTLY-1000` |
| M02 | [`M02-coupon-code-case-sensitive.patch`](../mutants/M02-coupon-code-case-sensitive.patch) | `Nop.Services/Discounts/DiscountService.cs`, `ValidateDiscount` | the coupon comparison `InvariantCultureIgnoreCase` becomes `Ordinal` | The "compare ordinally" fix that drops IgnoreCase: the database still finds SAVE10 for `" save10 "`, validation refuses it. | `COUPON-TRIMMED-AND-CASE-INSENSITIVE` |
| M03 | [`M03-maximum-discount-amount-dropped.patch`](../mutants/M03-maximum-discount-amount-dropped.patch) | `Nop.Services/Discounts/DiscountExtensions.cs`, `MapDiscount` | `MaximumDiscountAmount` no longer copied into the cached discount model | A field lost in a mapping: PCT20MAX100 on T15's $3,600.00 cart takes 20% ($720.00), not the $100.00 cap. | `PCT20MAX100-STOPS-AT-MAXIMUM` |
| M04 | [`M04-order-total-not-bounded.patch`](../mutants/M04-order-total-not-bounded.patch) | `Nop.Services/Orders/OrderTotalCalculationService.cs`, `GetShoppingCartTotal` | the cap of the order total discount at the total, and both clamps of the total at zero, removed | Guards lost in a rewrite: TAKE50 on T14's $34.00 order is taken in full, the total goes to -16.00. | `TAKE50-CAPPED-AT-ORDER-TOTAL`, `CART-TOTAL-NEVER-NEGATIVE` |
| M05 | [`M05-tax-from-the-shipping-address.patch`](../mutants/M05-tax-from-the-shipping-address.patch) | `Nop.Services/Tax/TaxService.cs`, `CreateCalculateTaxRequest` | for `TaxBasedOn.BillingAddress` the request takes `customer.ShippingAddress` | A copy-paste slip: T22F, billed to New York 10001 and shipped to Texas, is taxed 5% ($25.00), not 9% ($45.00). | `TAX-FOLLOWS-BILLING-ADDRESS` |
| M06 | [`M06-tax-zip-match-case-sensitive.patch`](../mutants/M06-tax-zip-match-case-sensitive.patch) | `Nop.Plugin.Tax.FixedOrByCountryStateZip/FixedOrByCountryStateZipTaxProvider.cs`, `GetTaxRate` | the zip comparison `InvariantCultureIgnoreCase` becomes `Ordinal` | The same slip in the tax plugin: `k1a 0b1` no longer matches K1A 0B1, so T23 is taxed 0.00, not $65.00. | `TAX-ZIP-MATCH-IGNORES-CASE` |
| M07 | [`M07-order-details-without-owner-check.patch`](../mutants/M07-order-details-without-owner-check.patch) | `Nop.Web/Controllers/OrderController.cs`, `Details` | `CurrentCustomer.Id != order.CustomerId` dropped from the refusal | An authorization check lost in a port: a guest (T30A) and another customer (T30B) get order 2's details page, owner's name included. | `OTHERS-ORDER-NEVER-SHOWN`, `OTHERS-ORDER-NEVER-NAMES-ITS-OWNER`, `OTHERS-ORDER-SENDS-TO-LOGIN` |
| M08 | [`M08-unpublished-product-page-served.patch`](../mutants/M08-unpublished-product-page-served.patch) | `Nop.Web/Controllers/ProductController.cs`, `ProductDetails` | the "published?" condition dropped from the availability check | A dropped condition: the unpublished HP Envy's page (T05) answers 200, not 404. | `UNPUBLISHED-PAGE-NEVER-SERVED`, `UNPUBLISHED-PAGE-NOT-FOUND` |
| M09 | [`M09-stock-quantity-warning-dropped.patch`](../mutants/M09-stock-quantity-warning-dropped.patch) | `Nop.Services/Orders/ShoppingCartService.cs`, `GetStandardWarnings` | the "quantity exceeds stock on hand" warning removed; the out-of-stock warning stays | A lost `else`: T07's 5 more Lenovos with 3 in stock are accepted, and so are T28's 2 with 1 left. | `QUANTITY-ABOVE-STOCK-REFUSED`, `T07-CART-HOLDS-ONE-LENOVO`, `ORDER-LOWERS-STOCK` |
| M10 | [`M10-price-in-invariant-culture.patch`](../mutants/M10-price-in-invariant-culture.patch) | `Nop.Services/Catalog/PriceFormatter.cs`, `GetCurrencyString` | prices formatted with `CultureInfo.InvariantCulture` instead of the currency's display locale | The "pass a culture" fix that passes the invariant one: every price is written with the generic currency sign instead of `$`. Aimed at the cart's unit prices; every clause that reads an amount is expected to fail with them. | `CART-UNIT-PRICES-WRITTEN-IN-USD` |
| M11 | [`M11-gift-card-exclusion-dropped.patch`](../mutants/M11-gift-card-exclusion-dropped.patch) | `Nop.Services/Discounts/DiscountService.cs`, `ValidateDiscount` | the gift-card exclusion for order subtotal and order total discounts removed | A dropped business rule: SAVE10 on T17's cart with a $25 gift card is applied, ($4.90), instead of refused. | `GIFT-CARD-IN-CART-COUPON-MESSAGE`, `GIFT-CARD-CART-NEVER-DISCOUNTED` |

### How the 3.90 code shaped the set

The set was proposed before the 3.90 code was read, then checked against it. Three
mutants differ from the proposal; one needed a closer look:

- **M04, adjusted.** "The total no longer clamped at zero" alone is an equivalent mutant on
  this traffic: 3.90 first caps the order total discount at the order total, so the total
  never goes below zero to be clamped. The mutant removes the cap as well as both clamps.
- **M09, narrowed.** 3.90 has two stock warnings: out of stock (nothing left), and
  "exceeds stock on hand" (less left than asked for). The traffic exercises the second, so
  the mutant drops that one and keeps the first.
- **M03, by its mapping.** 3.90 applies the cap in `DiscountExtensions.GetDiscountAmount`,
  from the cached discount model. The mutant loses the field where that model is built,
  `MapDiscount` — one line, and the way a port of a mapping loses a field — so the cap is
  ignored wherever discounts are computed.
- **M02, checked.** The coupon is first looked up in the database, whose collation ignores
  case, and only then validated in code. Making the code's comparison ordinal therefore
  still finds SAVE10 for `" save10 "` and refuses it in validation, which is where the
  clause sees it.

## One mutant by hand

On a Windows host with steps 1–6 of [`scripts/README.md`](../scripts/README.md) done, from
the repository root, elevated:

```powershell
.\scripts\1-fetch-nopcommerce.ps1 -WorkRoot C:\nopmut
.\scripts\2-build-legacy.ps1 -WorkRoot C:\nopmut -SiteDir C:\nopmut\mutant-site -Patch mutants\M01-free-shipping-at-the-threshold.patch
.\scripts\mutants\2-deploy-mutant.ps1 -Id M01      # before step 7: the snapshot must hold its database user
.\scripts\7-record-traffic.ps1
.\scripts\8-replay.ps1 -Candidate http://localhost:8091/
pwsh scripts/9-verdict.ps1
pwsh scripts/mutants/3-mutant-outcome.ps1 -Id M01
```

For M00, build without `-Patch`. The next mutant on the same host reuses the snapshot,
which already holds the mutant site's database user: build it, deploy it, replay, verdict.
