# P5 results — the nopCommerce contract, A/A on the legacy shop

**Done when (docs/WORKPLAN.md): it validates and passes on the legacy system.** It does.
`sk validate` accepts [`contract.yaml`](../../contract/contract.yaml) and
[`secondkey.yaml`](../../contract/secondkey.yaml), and the A/A replay of
[legacy-build run 36255313866](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36255313866)
(2026-09-26, commit `c6732ab`) — the legacy shop against itself, the database restored to
the recording's snapshot before every scenario on each side — gives `sk compare` the
outcome **pass: 76 of 76 accepted clauses held, 0 unexercised**. The pack is that run's
[`nopcommerce-evidence-pack`](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36255313866/artifacts/10910697442)
artifact, kept by CI for 30 days. Every run of
[`legacy-build`](../../.github/workflows/legacy-build.yml) records, replays, compares and
packs anew, and fails unless the A/A verdict is the same
([`9-verdict.ps1`](../../scripts/9-verdict.ps1)).

## The run

| | |
|---|---|
| Recording | the P4 set, recorded in the same run: 38 scenarios, 290 exchanges ([`results/p4`](../p4/README.md)) |
| Tools | `sk` at `967c49c` ([`pins.json`](../../pins.json)); replay on the Windows host next to IIS, compare and pack on Linux |
| Replayed | A/A, legacy and candidate both `http://localhost:8080`: 580 results (200 × 500, 302 × 78, 404 × 2), 0 without an answer; 76 `sqlServerSnapshot` resets, 0 failed, 3.3 s on average; 300 s in all |
| Verdict | **pass** — 290 exchanges in 38 scenarios: 272 equal, 18 equal under contract, 0 regressions, 0 fix candidates |
| Contract | 76 clauses, all accepted: **76 held**, 0 not held, 0 unexercised; 15 `never` — absence share 19.7%; 32 extractors |
| Normalization | the 18 equal under contract, as sk labels them by the masks that made their differences disappear (an exchange can carry two): `anti-forgery-token` 14 (the confirm step's order summary), `cart-line-picture` 17 (the same 14, and 3 mini carts), `pdf-bytes` 1 (the invoice) |
| Pack | `contract.yaml`, `index.html`, `report.pdf` (Google Chrome on the Linux runner), `run.skrun`, `statement.intoto.json`, `verdict.json`, `manifest.json` — every SHA-256 re-checked against the manifest |

## What the first A/A run found

The first run of this gate failed, and both reasons were the contract's, not the shop's:

- **The home page lists four products, not six.** The sample data flags four products
  "show on home page"; the two more the contract expected are commented out in the 3.90
  installer (`CodeFirstInstallationService`). The clause broke on both sides
  (`violated-both`) — a contract that is wrong about the legacy system, which is what
  the gate is for. `HOME-LISTS-THE-FOUR-HOME-PAGE-PRODUCTS` now names the four.
- **17 JSON answers differed between two replays of the same request.** 14 were the
  confirm step's order summary, which carries a fresh anti-forgery token; 3 were the mini
  cart of an add-to-cart answer, where a Lenovo line was pictured as the $25 gift card on
  one side. 3.90 caches a cart line's picture for three minutes by shopping-cart-item id,
  and every scenario's first cart line gets the same id after the restore. Both are masked
  now, the values only ([`contract/README.md`](../../contract/README.md#normalization),
  [ADR 0006](../../docs/adr/0006-nopcommerce-contract-and-aa-proof.md) §3); the second
  run above passed with them.

A clause that held here and fails against P6's candidate, replayed from the same recording
with the same reset (P7), is a regression by construction.
