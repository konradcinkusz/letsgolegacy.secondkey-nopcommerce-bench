# P4 results — the nopCommerce traffic set

**Done when (docs/WORKPLAN.md): the scenario count is recorded.** It is: **38 scenarios,
290 exchanges**, recorded through `sk capture` in front of the P2 shop by
[legacy-build run 36253613672](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36253613672)
(2026-09-26, commit `45fb761`). The recording is that run's
[`nopcommerce-traffic`](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36253613672/artifacts/10910360033)
artifact, kept by CI for 30 days. Every run of
[`legacy-build`](../../.github/workflows/legacy-build.yml) records the set anew and writes
the count, scenario by scenario, to its job summary. What the set is: the
[traffic plan](../../docs/P4-TRAFFIC-PLAN.md) (section 4a: as recorded); how it is
recorded: [ADR 0005](../../docs/adr/0005-nopcommerce-traffic-recording.md).

## The recording

| | |
|---|---|
| Application | nopCommerce 3.90 (`12d1f01`) with its sample data, IIS on `windows-2022`, SQL Server 2022 Express |
| Store | configured as plan section 2 through the admin UI (step 6), every change read back: tax rates by country/state/zip, fixed shipping rates and free shipping over $1,000.00, seven coupons, the catalog changes; the four schedule tasks the sample install enables disabled, then the application restarted — back after 14 s, with a new "Application started" entry in the shop's log |
| Tool | `sk capture` at `967c49c` ([`pins.json`](../../pins.json)) on `127.0.0.1:8000`; one session per scenario, named by the `x-bench-scenario` header; `sk validate` accepts the `.skcap` |
| Recorded | **38 scenarios, 290 exchanges** in 166 s — the 30 planned scenarios (T01–T30), some as several sessions |
| Starting state | every scenario from snapshot `nopcommerce_legacy_snapshot` of the configured store, restored before it: 38 restores of 3.3–3.4 s each; the first request after every one of them was answered 200 at once |

## Per area

| Area | Scenarios | Exchanges | |
|---|---|---|---|
| Catalog | 5 | 10 | T01–T05 |
| Search | 1 | 5 | T06 |
| Cart | 4 | 19 | T07–T10 |
| Discounts | 12 | 80 | T11, T12, T12B, T13–T17, T18A, T18B, T19, T20 |
| Taxes | 8 | 98 | T21, T22A–T22F, T23 — each a checkout to a billing address |
| Shipping | 3 | 27 | T24–T26 |
| Checkout | 2 | 36 | T27 (guest), T28 (registered: the refused card, then the order) |
| Orders | 3 | 15 | T29, T30A, T30B |
| **Total** | **38** | **290** | |

## What recording the set changed

The findings are in the plan's section 4a, each with the 3.90 source it comes from. Two of
them changed how the set is recorded, not only what P5 asserts:

- **A database restore under a running schedule task takes the shop down.** 3.90 runs
  its schedule tasks on timers inside the web application, and a task reads its row
  before its `try`; one earlier recording saw the first requests after a restore answered
  500 until the application had started again. Step 6 now disables the four tasks the
  sample install enables and restarts the application; step 7 checks the first answer
  after every restore, and in this run all 38 were 200.
- **Checkout starts at the cart's Checkout button.** The sample store's required checkout
  attribute, "Gift wrapping", is saved only when the cart form is posted; an order placed
  after going straight to `/onepagecheckout` is refused with "Please select Gift
  wrapping;". Every checkout in the set goes cart → Checkout → (guest: "Checkout as
  Guest") → `/checkout` → one-page checkout, as a browser does.
