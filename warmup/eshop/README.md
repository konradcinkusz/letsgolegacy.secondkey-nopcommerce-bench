# P3 — warm-up on eShopLegacyMVC

The whole Second Key chain, once, on Microsoft's own sample legacy application — before it
is pointed at nopCommerce. Done when an evidence pack is produced: the
`eshop-evidence-pack` artifact of the [`warmup-eshop`](../../.github/workflows/warmup-eshop.yml)
workflow. Decisions and reasons: [ADR 0004](../../docs/adr/0004-chain-tools-and-eshop-warmup.md).
Numbers from the runs: [`results/p3/`](../../results/p3/).

| | |
|---|---|
| Application | `eShopLegacyMVC` from `dotnet-architecture/eShopModernizing` at `63bc9ec` (pinned in [`pins.json`](../../pins.json)), ASP.NET MVC 5 on .NET Framework 4.7.2, on its own mock data (`UseMockData=true`, no database) |
| Host | IIS on the `windows-2022` runner, `http://localhost:8081/`; recording proxy `http://127.0.0.1:8001/` |
| Traffic | 7 scenarios, [`scripts/eshop/EShop.Scenarios.ps1`](../../scripts/eshop/EShop.Scenarios.ps1): browse, missing items, create, invalid create, edit, delete, brands Web API |
| Reset | the application pool is restarted before every scenario, when recording and on each side of the replay ([`Reset-EShop.ps1`](../../scripts/eshop/Reset-EShop.ps1)) |
| Replay | A/A: the legacy site against itself ([`secondkey.yaml`](secondkey.yaml)) |
| Contract | [`contract.yaml`](contract.yaml): 13 clauses, 3 of them `never` |
| Gate | Portcullis (pinned in `pins.json`) on the legacy source, whole tree, SARIF 2.1.0 |

## The chain, step by step

| Where | Step | Script | Produces |
|---|---|---|---|
| Linux | build the tools | [`chain-tools.yml`](../../.github/workflows/chain-tools.yml) | `sk` and Portcullis at their pinned commits |
| Windows | 1 | [`1-build-eshop.ps1`](../../scripts/eshop/1-build-eshop.ps1) | `<work>\eshop-site`, published, `UseMockData=true` |
| Windows | — | [`3-install-iis-sql.ps1 -SkipSql`](../../scripts/3-install-iis-sql.ps1) | IIS with ASP.NET 4.x |
| Windows | 2 | [`2-deploy-eshop.ps1`](../../scripts/eshop/2-deploy-eshop.ps1) | IIS site `eshop-legacy` on 8081 |
| Windows | 3 | [`3-record-eshop.ps1`](../../scripts/eshop/3-record-eshop.ps1) | `<work>\eshop\traffic.skcap` via `sk capture` |
| Windows | 4 | [`4-replay-eshop.ps1`](../../scripts/eshop/4-replay-eshop.ps1) | `<work>\eshop\run.skrun` via `sk replay` |
| Windows | 5 | [`5-scan-eshop.ps1`](../../scripts/eshop/5-scan-eshop.ps1) | `<work>\eshop\portcullis.sarif` |
| Linux | 6 | [`6-verdict-eshop.ps1`](../../scripts/eshop/6-verdict-eshop.ps1) | `verdict.json` (`sk compare`), the gate summary (`sk gate`), the pack (`sk evidence`) |

Step 6 fails unless the A/A verdict is `pass` with every accepted clause held and none
unexercised — after writing the pack, so the pack explains a failure.

## On a workstation

On a Windows machine with IIS, Visual Studio 2022 (web workload) and the .NET 10 runtime,
from an elevated PowerShell in the repository root, with the chain's tools built (see
[`scripts/README.md`](../../scripts/README.md#the-chains-tools)):

```powershell
.\scripts\eshop\1-build-eshop.ps1
.\scripts\3-install-iis-sql.ps1 -SkipSql
.\scripts\eshop\2-deploy-eshop.ps1
.\scripts\eshop\3-record-eshop.ps1
.\scripts\eshop\4-replay-eshop.ps1
.\scripts\eshop\5-scan-eshop.ps1
.\scripts\eshop\6-verdict-eshop.ps1      # also runs on Linux: pwsh scripts/eshop/6-verdict-eshop.ps1
```

The pack is then in `C:\nopbench\eshop\evidence`; open `index.html`.
