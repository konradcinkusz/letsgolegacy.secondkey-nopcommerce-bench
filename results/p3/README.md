# P3 results — the chain's warm-up on eShopLegacyMVC

**Done when (docs/WORKPLAN.md): a pack is produced.** It was, by
[warmup-eshop run 36240136388](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36240136388)
(2026-09-26, commit `3510b98`): the
[`eshop-evidence-pack`](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36240136388/artifacts/10905308911)
artifact, kept by CI for 30 days. Every run of the
[`warmup-eshop`](../../.github/workflows/warmup-eshop.yml) workflow produces a new one.
What the warm-up is and how to run it: [`warmup/eshop/`](../../warmup/eshop/README.md).

## The first pack

| | |
|---|---|
| Application | eShopLegacyMVC at `dotnet-architecture/eShopModernizing@63bc9ec`, mock data, IIS on `windows-2022` |
| Tools | `sk` at `967c49c`, Portcullis at `84e1925` ([`pins.json`](../../pins.json)) |
| Recorded | **7 scenarios, 27 exchanges** through `sk capture` (E01–E07, [`EShop.Scenarios.ps1`](../../scripts/eshop/EShop.Scenarios.ps1)) |
| Replayed | A/A: 54 results, 14 resets (application pool restarted before each scenario on each side), 0 without an answer, 50.5 s |
| Verdict | **pass** — 27 equal, 0 equal under contract, 0 regressions, 0 fix candidates |
| Contract | [13 clauses](../../warmup/eshop/contract.yaml), all accepted: **13 held**, 0 unexercised; absence share 23% (3 `never`) |
| Gate | Portcullis on the legacy source, whole tree: 27 findings — `PORTCULLIS_MIG_SYSTEM_WEB` 20 warnings, `PORTCULLIS_MIG_HTTPCONTEXT_CURRENT` 4 errors, `PORTCULLIS_MIG_CONFIGURATION_MANAGER` 3 errors. `sk gate`: fail, 7 blocking — recorded, not enforced: these are the idioms a migration has to remove, and no change was gated ([ADR 0004](../../docs/adr/0004-chain-tools-and-eshop-warmup.md) §5) |
| Pack | `contract.yaml`, `index.html`, `report.pdf` (Google Chrome on the Linux runner), `run.skrun`, `sarif/portcullis.sarif`, `statement.intoto.json`, `verdict.json`, `manifest.json` — every SHA-256 re-checked against the manifest |

Timings in that run: build and publish 52 s; IIS 22 s; deploy 21 s (first answer after
14 s); recording 28 s (about 3 s per restart); replay 50 s; scan 3 s; verdict and pack
13 s. Whole workflow: 4.5 minutes.

## What the warm-up taught the nopCommerce runs

- **The chain works end to end on a Windows host plus a Linux job**, with nothing but files
  crossing between them — the split [`TOPOLOGY.md`](../../docs/TOPOLOGY.md) planned.
- **A scenario per session, named by a header**, and a proxy stopped once it holds every
  exchange sent: both carry over to P4 unchanged.
- **A value operator on an `all: true` extractor needs `[*]`.** `gt` on
  `extract.catalogPrices` compares the extracted array itself and can never hold; the
  clause selects `extract.catalogPrices[*]`. Caught before CI, on a local stand-in of the
  application; the P5 contract follows the same rule.
