# The nopCommerce contract (P5)

[`contract.yaml`](contract.yaml) is what the legacy shop must do, and must never do, on
the [P4 traffic set](../docs/P4-TRAFFIC-PLAN.md) — written as Second Key clauses over the
recorded requests, so any other version of the shop can be held to it (P7): **76
clauses, 15 of them `never` (19.7%), over 32 extractors**, all accepted.
[`secondkey.yaml`](secondkey.yaml) is how the traffic is replayed.

**Done when (docs/WORKPLAN.md):** it validates (`sk validate`) and passes on the legacy
system. It passes when an A/A replay — the legacy shop against itself, the database
restored to the snapshot before every scenario on each side — gives `sk compare` the
outcome `pass` with every accepted clause held and none unexercised. CI checks exactly
that on every change ([`legacy-build.yml`](../.github/workflows/legacy-build.yml), steps 8
and 9); what a run showed is in [`results/p5`](../results/p5/README.md).

## How it is written

- **From the plan's rules.** Section 5 of the traffic plan lists 46 rules (R01–R46),
  each citing the 3.90 source it comes from. Every clause names in its `why` the rules it
  states; the table below maps them.
- **Titles say exactly what the assertions check.** "Billed to US / New York / 10001,
  the $500.00 Lenovo with Ground shows tax 45.00 (9%)" — not "tax is correct".
- **Scoped by probe.** Most rules are facts about one scenario's answer at a URL every
  scenario uses (`POST /cart`). Such requests carry `probe=<name>` in their query, and a
  clause selects them with `when: { query: { probe: "^T11$" } }` (plan section 1).
- **HTML is read through extractors.** A page is compared, and asserted on, only through
  the values the extractors pull out of it (`compare.html: extracts`): the cart's totals
  rows, coupon messages, listing titles, order totals. Markup is not behaviour.
- **Every `never` has a positive twin** in the same scenario, so an absence cannot hold
  because nothing happened: the guest's refused `MEMBERS15` beside the registered
  customer's `($75.00)`, the refused card beside the placed order, the refused order
  pages beside the customer's own.
- **Legacy behaviour is pinned as it is**, including what a migration may be tempted to
  "fix": discounts written `($100.00)`, the empty message a guest gets for `MEMBERS15`,
  the $1.99 pickup fee free shipping does not waive, the refusal of `SAVE10`+U+180E.
  Changing any of them is a decision, and the contract makes it a visible one.

## Rules and clauses

| Plan rules | Clauses |
|---|---|
| R01 storefront pages | `STOREFRONT-ANSWERS-WITH-FOOTER`, `COMPUTERS-LISTS-ITS-SUBCATEGORIES` |
| R02 home page | `HOME-LISTS-THE-FOUR-HOME-PAGE-PRODUCTS` |
| R03, R04 sorting, paging | `NOTEBOOKS-BY-PRICE-ASCENDING`, `NOTEBOOKS-BY-NAME`, `NOTEBOOKS-PAGE-TWO-OF-THREE-PER-PAGE` |
| R05 unpublished (never) | `UNPUBLISHED-NEVER-LISTED`, `UNPUBLISHED-PAGE-NEVER-SERVED`; twin `UNPUBLISHED-PAGE-NOT-FOUND` |
| R06 product pages | `LENOVO-PAGE-NAME-SKU-PRICE`, `MACBOOK-PAGE-NAME-SKU-PRICE`, `COMPUTER-PAGE-ATTRIBUTE-ADJUSTMENTS` |
| R07, R08 search | `SEARCH-FINDS-MACBOOK-BY-NAME-CASE-AND-SKU`, `SEARCH-TERM-MINIMUM-LENGTH` |
| R09–R14 cart | `LISTING-ADD-TO-CART-SUCCEEDS`, `T07-CART-HOLDS-ONE-LENOVO`, `QUANTITY-ABOVE-STOCK-REFUSED`, `QUANTITY-BELOW-MINIMUM-REFUSED`, `REQUIRED-ATTRIBUTE-REFUSED`, `T09-ATTRIBUTES-PRICED-INTO-UNIT-PRICE`, `T10-*` |
| R15, R17, R18, R21, R22, R25–R27 discounts | `SAVE10-*`, `COUPON-TRIMMED-AND-CASE-INSENSITIVE`, `*-COUPON-MESSAGE`, `PCT20MAX100-*`, `SHIPFREE-*`, `ONCE5-*`, `COUPON-123-*`, `TAKE50-*`, `MEMBERS15-FOR-A-REGISTERED-CUSTOMER`, `MEMBERS15-GUEST-GETS-AN-EMPTY-MESSAGE` |
| R19, R20, R23, R24 discounts (never) | `REFUSED-COUPON-NEVER-*`, `CART-TOTAL-NEVER-NEGATIVE`, `GIFT-CARD-CART-NEVER-DISCOUNTED`, `MEMBERS15-NEVER-FOR-A-GUEST`, `MEMBERS15-GUEST-NEVER-TOLD-APPLIED` |
| R28–R30 taxes | `TAX-US-*`, `TAX-NO-RATE-GERMANY`, `TAX-ZIP-MATCH-IGNORES-CASE`, `TAX-FOLLOWS-BILLING-ADDRESS` |
| R32 tax exemption (never) | `TAX-EXEMPT-NEVER-TAXED`, `TAX-EXEMPT-CART-PRICED` |
| R33–R35 shipping | `ESTIMATE-OFFERS-FIXED-RATES-AND-PICKUP`, `CHECKOUT-OFFERS-THE-SAME-RATES`, `FREE-SHIPPING-*`, `NO-FREE-SHIPPING-AT-EXACTLY-1000` |
| R31, R36–R38, R40, R41 orders | `GUEST-ORDER-*`, `REGISTERED-ORDER-TOTALS`, `ORDER-EMPTIES-THE-CART`, `ORDER-LOWERS-STOCK` |
| R39 card check digit (never) | `BAD-CARD-NEVER-REACHES-CONFIRM`, `BAD-CARD-NUMBER-REFUSED` |
| R42, R43 own orders | `HISTORY-LISTS-OWN-ORDERS-ONLY`, `OWN-ORDER-DETAILS-SHOWN`, `OWN-ORDER-PDF-INVOICE` |
| R44, R45 someone else's order (never) | `OTHERS-ORDER-NEVER-SHOWN`, `OTHERS-ORDER-NEVER-NAMES-ITS-OWNER`, `OTHERS-ORDER-SENDS-TO-LOGIN`, `GUEST-NEVER-GETS-ORDER-HISTORY`, `NOBODY-REORDERS-OTHERS-ORDER` |
| R46 currency format | `CART-UNIT-PRICES-WRITTEN-IN-USD`; the discount amounts pinned as `($100.00)` in the discount clauses |
| §6 NLS → ICU probes | `COUPON-WITH-U180E-REFUSED`; the `($100.00)`-style amounts above |
| — | `SIGN-IN-RETURNS-HOME`, `REGISTRATION-COMPLETES`, `NEVER-A-SERVER-ERROR` |

Not a clause of their own: **R16** (a percentage discount computed in single precision,
rounded half to even) — the recorded amounts cannot tell that computation from exact
decimal arithmetic, so the discount clauses pin the amounts instead; **R37** (the placed
order's totals equal the confirm step's) — one clause sees one request, so the order
details clauses assert the totals the confirm step showed.

## Normalization

Three masks, each for a value the shop does not derive from the request and the snapshot
alone, so two answers to the same request can differ in it:

- `masks.patterns.pdf-bytes` — the bytes of a PDF invoice. A rendering carries its
  creation time and a random document id, so two renderings never match; the contract
  asserts the invoice's status and type instead.
- `masks.patterns.anti-forgery-token` — the value of an anti-forgery token, fresh on
  every rendering. The one-page checkout's confirm step answers JSON whose
  `update_section.html` holds the order summary, a form with such a token.
- `masks.patterns.cart-line-picture` — a cart line's picture URL, alt text and link
  title. 3.90 caches them for three minutes by shopping-cart-item id
  (`ShoppingCartModelFactory.PrepareCartItemPictureModel`); every scenario starts from the
  same snapshot, so its first cart line always gets the same id, and within those three
  minutes the line shows the picture of whichever product last had that id — the A/A run
  saw a Lenovo line pictured as the $25 gift card. It shows in the mini cart the
  add-to-cart answer carries and in the confirm step's order summary.

JSON is compared as it is, HTML inside it included, so only those values are masked: the
rest of the section — product names, prices, quantities, totals — still counts. Pages are
compared through their extracts, and no extractor reads a token or a picture. Nothing else
is normalized: from the same snapshot and the same requests, the legacy shop answers the
same on both sides of an A/A replay, order numbers included.

## Running it

After steps 1–7 of the runbook ([`scripts/README.md`](../scripts/README.md)):

```powershell
.\scripts\8-replay.ps1                    # on the shop's host: A/A replay into <work>\replay\run.skrun
pwsh scripts/9-verdict.ps1 -Pdf auto      # anywhere: sk compare and the evidence pack
```
