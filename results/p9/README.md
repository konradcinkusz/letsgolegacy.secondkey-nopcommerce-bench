# P9 results — killed mutants

**11 of 11 mutants killed.** Eleven small defects were written into nopCommerce 3.90's
source and registered, each with the clauses expected to catch it, before any of them ran
([`docs/P9-MUTANTS.md`](../../docs/P9-MUTANTS.md), commit `47e2e36`). Each was deployed
beside the legacy shop and replayed against it exactly as the P7 candidate will be. `sk
compare` failed every one of them, and every clause registered for a mutant regressed on
it. M00 — the unpatched source, built and deployed the same way — passed, and that is what
lets the count mean anything. The run is
[mutants run 36262958486](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486)
(2026-09-26, commit `5f90227`). [`mutants.json`](mutants.json) is that run's file byte for
byte (SHA-256 `682910c1fb9311f790c8d33a64915c3d70f3c39232369ee3ef248afe46460af4`, as the
summary job prints it with the file into its log); the run's
[`mutants`](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913480618)
artifact holds it too, and each mutant's evidence pack is its `mutant-<id>-evidence-pack`
artifact, all kept by CI for 30 days. Every run of
[`mutants`](../../.github/workflows/mutants.yml) builds, deploys, replays and judges the
whole set anew, and fails unless M00 passes.

## The run

| | |
|---|---|
| Set | M00 and M01–M11 of [`mutants/mutants.json`](../../mutants/mutants.json) (SHA-256 `809af3ef…`): one patch each against nopCommerce `release-3.90` (`12d1f01`), checked against the pinned tree by the plan job before any mutant job started |
| Per mutant | one `windows-2022` job: the mutant built by step 2 with `-Patch`; the legacy shop installed and configured (steps 3–6); the mutant deployed beside it on `http://localhost:8091/`, on the legacy database; the P4 traffic set recorded on the legacy shop — 38 scenarios, 290 exchanges; legacy replayed against the mutant, `8-replay.ps1 -Candidate`. 914–956 s each, the twelve in parallel |
| Verdict | `sk compare` against the P5 [contract](../../contract/contract.yaml), unchanged, then `sk evidence`, on Linux; killed means the outcome is `fail` |
| Tools | `sk` at `967c49c` ([`pins.json`](../../pins.json)) |
| Whole run | 18.5 minutes, 18:33–18:52 UTC |

## M00, the calibration

The legacy shop replayed against a second build of the same source, running as a second
site on the same database: 38 scenarios, 580 results (200 × 500, 302 × 78, 404 × 2), 0
without an answer; 76 snapshot restores, 0 failed, 3.4 s on average; 317 s. `sk compare`:
**pass** — 290 exchanges: 269 equal, 21 equal under contract, 0 regressions, 0 fix
candidates; 76 of 76 clauses exercised. The 21 are the P5 masks: `anti-forgery-token` 14,
`pdf-bytes` 1, and `cart-line-picture` 20, where the A/A replay of the same commit
([legacy-build run 36262958484](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958484))
has 17: 3.90 caches a cart line's picture in the application's memory
([`results/p5`](../p5/README.md)), and here each side is an application of its own.
Nothing else told the two sites apart — not the port, not the host in nopCommerce's
absolute URLs, not a second worker process or a second database login.

## The mutants

| Mutant | Clauses expected to catch it, registered in advance | Outcome | Verdict | Regressions | of them uncovered differences | Clauses that regressed |
|---|---|---|---|---|---|---|
| M00 Calibration: no source change | none — it must pass | **pass** | pass | 0 | 0 | — |
| M01 Free shipping from exactly the threshold | `NO-FREE-SHIPPING-AT-EXACTLY-1000` | **killed** | fail | 7 | 6 | `NO-FREE-SHIPPING-AT-EXACTLY-1000` |
| M02 Coupon code matched case-sensitively | `COUPON-TRIMMED-AND-CASE-INSENSITIVE` | **killed** | fail | 14 | 2 | `COUPON-TRIMMED-AND-CASE-INSENSITIVE` and 8 more (below) |
| M03 Maximum discount amount ignored | `PCT20MAX100-STOPS-AT-MAXIMUM` | **killed** | fail | 1 | 0 | `PCT20MAX100-STOPS-AT-MAXIMUM` |
| M04 Order total no longer bounded by the order | `TAKE50-CAPPED-AT-ORDER-TOTAL`, `CART-TOTAL-NEVER-NEGATIVE` | **killed** | fail | 1 | 0 | both |
| M05 Tax from the shipping address instead of the billing address | `TAX-FOLLOWS-BILLING-ADDRESS` | **killed** | fail | 2 | 1 | `TAX-FOLLOWS-BILLING-ADDRESS` |
| M06 Tax zip match made case-sensitive | `TAX-ZIP-MATCH-IGNORES-CASE` | **killed** | fail | 2 | 1 | `TAX-ZIP-MATCH-IGNORES-CASE` |
| M07 Order details served without the owner check | `OTHERS-ORDER-NEVER-SHOWN`, `OTHERS-ORDER-NEVER-NAMES-ITS-OWNER`, `OTHERS-ORDER-SENDS-TO-LOGIN` | **killed** | fail | 2 | 0 | all three |
| M08 Unpublished product page served | `UNPUBLISHED-PAGE-NEVER-SERVED`, `UNPUBLISHED-PAGE-NOT-FOUND` | **killed** | fail | 1 | 0 | both |
| M09 Stock quantity warning dropped | `QUANTITY-ABOVE-STOCK-REFUSED`, `T07-CART-HOLDS-ONE-LENOVO`, `ORDER-LOWERS-STOCK` | **killed** | fail | 3 | 0 | all three |
| M10 Prices formatted in the invariant culture | `CART-UNIT-PRICES-WRITTEN-IN-USD` | **killed** | fail | 133 | 98 | `CART-UNIT-PRICES-WRITTEN-IN-USD` and 27 more (below) |
| M11 Gift-card exclusion dropped from discount validation | `GIFT-CARD-IN-CART-COUPON-MESSAGE`, `GIFT-CARD-CART-NEVER-DISCOUNTED` | **killed** | fail | 1 | 0 | both |

Regressions count exchanges, each either a clause's — a clause that held on the legacy
side did not hold on the mutant — or an uncovered difference, which nothing in the
contract explains. In all twelve replays no answer was missing on either side, and no
mutant produced a fix candidate. Evidence packs:
[M00](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913243203) ·
[M01](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913440967) ·
[M02](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913064172) ·
[M03](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913009389) ·
[M04](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913371242) ·
[M05](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10912809889) ·
[M06](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10912854888) ·
[M07](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10912904603) ·
[M08](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913381193) ·
[M09](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10912889835) ·
[M10](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10913356275) ·
[M11](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36262958486/artifacts/10912264607).

## What caught each one

Values are legacy → mutant, as `sk compare` reported them; scenarios are the
[traffic plan](../../docs/P4-TRAFFIC-PLAN.md)'s.

- **M01.** T26's $1,000.00 cart was estimated Ground ($0.00), Next Day Air ($0.00) and 2nd
  Day Air ($0.00), not $10.00, $40.00 and $25.00 — `NO-FREE-SHIPPING-AT-EXACTLY-1000`. The
  six uncovered differences are the cart pages of the $1,000.00 carts in T11, T12, T12B
  (two answers), T26 and T28: shipping $0.00 and a total of $1,000.00 where the legacy
  shop writes "Calculated during checkout" for both.
- **M02.** T12's `" save10 "`: "The coupon code was applied" and a discount of ($100.00) →
  "The coupon code you entered couldn't be applied to your order" and none —
  `COUPON-TRIMMED-AND-CASE-INSENSITIVE`, as registered. The other eight clauses are the
  finding below: `SAVE10-TAKES-10-PERCENT-OF-SUBTOTAL`, `TAKE50-CAPPED-AT-ORDER-TOTAL`,
  `PCT20MAX100-STOPS-AT-MAXIMUM`, `SHIPFREE-ZEROES-SHIPPING`,
  `MEMBERS15-FOR-A-REGISTERED-CUSTOMER`, `ONCE5-REFUSED-THE-SECOND-TIME`,
  `REGISTERED-ORDER-TOTALS` and `NEVER-A-SERVER-ERROR`.
- **M03.** T15's $3,600.00 cart with PCT20MAX100: discount ($100.00) → ($720.00), total
  3,500.00 → 2,880.00 — `PCT20MAX100-STOPS-AT-MAXIMUM`.
- **M04.** T14's $34.00 order with TAKE50: order discount ($34.00) → ($50.00) —
  `TAKE50-CAPPED-AT-ORDER-TOTAL`. The total, 0.00 on the legacy side, is written
  `($16.00)` on the mutant, which the `cartTotal` extractor cannot read as a decimal in
  `en-US`: `CART-TOTAL-NEVER-NEGATIVE` regressed as an error, exactly as registered in
  advance.
- **M05.** T22F, billed to New York 10001 and shipped to Texas: tax 45.00 → 25.00 (Texas's
  5%, not New York's 9%), total 555.00 → 535.00 — `TAX-FOLLOWS-BILLING-ADDRESS`; the
  uncovered difference is the same tax and total in the checkout's order summary.
- **M06.** T23, billed to `k1a 0b1`: tax 65.00 → 0.00, total 575.00 → 510.00 —
  `TAX-ZIP-MATCH-IGNORES-CASE`; and again in the checkout's order summary.
- **M07.** T30A (a guest) and T30B (another customer), `GET /orderdetails/2`: a 302 to the
  login page → 200 with "Order #2", its status and its totals — all three registered
  clauses. The print view, the PDF and reorder check the owner themselves, and still
  refused.
- **M08.** T05, the unpublished HP Envy 6-1180ca's page: 404 → 200 — both registered
  clauses.
- **M09.** T07's 5 more Lenovos with 3 in stock: refused ("Your quantity exceeds stock on
  hand. The maximum quantity that can be added is 3.") → added, and the cart holds 6,
  $3,000.00, instead of 1; T28's 2 more after R1's order left 1: refused → added — all
  three registered clauses.
- **M10.** Every price written with the generic currency sign, `¤500.00`, instead of
  `$500.00`: 133 regressions in 31 of the 38 scenarios. 28 clauses regressed —
  `CART-UNIT-PRICES-WRITTEN-IN-USD` and every other clause that reads an amount as the
  page writes it and expects one there; the five that expect no discount had none to read
  on either side, and the product pages' price clauses read the machine-readable `content`
  attribute, which M10 does not touch. The 98 uncovered differences are mini carts,
  checkout steps, and cart and order pages that no clause asserts on.
- **M11.** T17, SAVE10 on a cart holding a $25 gift card: "Sorry, this discount cannot be
  used with gift cards in the cart" → "The coupon code was applied", and a discount of
  ($4.90) — both registered clauses.

## What the run showed

- **No survivor, and no expectation missed.** Every registered clause regressed on its
  mutant, so the set found no gap in the contract. That is a statement about these eleven
  defects on this traffic, not a mutation score: they were written against named clauses,
  and the result is that those clauses catch the defects they were written for.
  Generated mutants — `sk mutate`, phase 02 — are what will measure the contract's reach.
- **Where no clause looks, the comparison still does.** For M01, M05 and M06 the
  registered clause caught the exchange it was written for, and the same defect showed
  elsewhere as differences no clause explains; those alone would have failed the
  comparison. For M03, M04, M07, M08, M09 and M11 every regression was a clause's. The
  reach has a limit the contract chose: an HTML page is compared only through what its
  extractors read (`compare.html: extracts`), so M10's prices on the home, category and
  search pages, where the contract reads names and titles, and on the product pages,
  where it reads the machine-readable price, went unseen — its kill came from the carts,
  checkout steps and orders.
- **M02 was a bigger defect than its intent said.** Registered as "a differently cased
  code is refused", it also broke every coupon typed exactly as configured. 3.90 keeps an
  applied code lower-cased (`Nop.Services/Customers/CustomerExtensions.cs`,
  `ApplyDiscountCouponCode`: `couponCode.Trim().ToLower()`) and validates it again each
  time it renders the cart (`Nop.Web/Factories/ShoppingCartModelFactory.cs`,
  `PrepareShoppingCartModel`), where it takes the first discount that validates and uses
  its `Id` without a null check. With the comparison ordinal, `SAVE10` is accepted, stored
  as `save10`, and then fails its own re-validation: 10 answers in T11, T14, T15, T16,
  T18B, T19 and T28 were server errors, the one-page checkout's payment step answered an
  error in T19 and T28, and R1's order in T28 was placed with other totals. The kill does
  not depend on that: T12 regressed the registered clause on its own, with a 200 and the
  refusal. The patch and its expectation stay as registered (rule 4).
- **M04 went as registered.** The negative total was caught through the extractor's error
  on `($16.00)`, as [`P9-MUTANTS.md`](../../docs/P9-MUTANTS.md#what-caught-by-means)
  stated before the run, not through the clause's `lt 0`.
- **Repeatable.** The workflow's first run,
  [36261713828](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36261713828)
  on commit `733f8cf` — the same patches and scripts, before the summary job also printed
  its file — came out the same: M00 pass, 11 of 11 killed.

## Running it again

On demand from the Actions tab (`mutants`, "Run workflow"), and on every pull request that
touches `mutants/`, `scripts/mutants/` or the workflow. One mutant by hand, on a Windows
host: [`docs/P9-MUTANTS.md`](../../docs/P9-MUTANTS.md#one-mutant-by-hand).
