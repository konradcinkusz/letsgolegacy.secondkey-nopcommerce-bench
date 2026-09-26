# Second Key — nopCommerce bench

The public specimen for [Second Key](https://github.com/konradcinkusz/letsgolegacy.secondkey):
nopCommerce 3.x migrated from .NET Framework by Microsoft's modernization agent, and
checked — independently and deterministically — against a written contract of what the
shop must do and must never do.

> **Status:** under construction; see [`docs/WORKPLAN.md`](docs/WORKPLAN.md). No
> evidence pack has been published yet.

nopCommerce is downloaded from the upstream project at build time and is not part of
this repository. The legacy side is pinned to nopCommerce **`release-3.90`** (commit
`12d1f01`), recorded with every other download in [`pins.json`](pins.json) and argued in
[`docs/adr/`](docs/adr/).

## Build the legacy shop

On Windows with Visual Studio 2022 (or Build Tools 2022, web development workload) and git:

```powershell
.\scripts\1-fetch-nopcommerce.ps1   # fetch the pinned release, verify tag and commit
.\scripts\2-build-legacy.ps1        # restore, build (Release) and publish Nop.Web
```

## Run the legacy shop

On the same Windows host, from an elevated PowerShell:

```powershell
.\scripts\3-install-iis-sql.ps1      # IIS with ASP.NET 4.x, SQL Server 2022 Express (.\SQLEXPRESS)
.\scripts\4-deploy-and-install.ps1   # IIS site on port 8080, nopCommerce installer with sample data
.\scripts\5-smoke.ps1                # home, category, product and cart answer with nopCommerce content
```

The shop then answers at `http://localhost:8080/`. Where everything runs, and how the
rest of the chain will reach it: [`docs/TOPOLOGY.md`](docs/TOPOLOGY.md).

CI runs all five scripts on `windows-2022` runners
([`legacy-build.yml`](.github/workflows/legacy-build.yml)): the build job publishes the
site as the `legacy-site` artifact, and the next job deploys that artifact and runs the
smoke test. Parameters, hand-off files and recipes: [`scripts/README.md`](scripts/README.md).

## Record the traffic set (P4)

With the chain's tools built ([`scripts/README.md`](scripts/README.md#the-chains-tools)), on the shop's host:

```powershell
.\scripts\6-configure-store.ps1    # taxes, shipping, discounts, catalog - through the admin UI
.\scripts\7-record-traffic.ps1     # every scenario from one database snapshot, through sk capture
```

The scenarios are [`docs/P4-TRAFFIC-PLAN.md`](docs/P4-TRAFFIC-PLAN.md)'s, scripted in
[`scripts/traffic/`](scripts/traffic/NopCommerce.Scenarios.ps1). CI runs both steps after
the smoke test and uploads the recording as the `nopcommerce-traffic` artifact; what a
run recorded is in [`results/p4`](results/p4/README.md).

## The contract (P5)

[`contract/contract.yaml`](contract/contract.yaml) states what the shop must do and must
never do on that traffic — 76 clauses, 15 of them `never` — and CI proves it on the
legacy shop itself: an A/A replay (the database restored before every scenario on each
side) whose `sk compare` verdict must be `pass` with every clause held.

```powershell
.\scripts\8-replay.ps1                  # on the shop's host: sk replay, A/A
pwsh scripts/9-verdict.ps1              # anywhere: sk compare and the evidence pack
```

How the contract is written and what it covers: [`contract/`](contract/README.md); what
a run showed: [`results/p5`](results/p5/README.md).

## Warm-up: the chain on eShopLegacyMVC (P3)

Before the chain meets nopCommerce it runs once, end to end, on Microsoft's sample legacy
application eShopLegacyMVC (on its own mock data): capture, A/A replay, compare, gate and
evidence pack, in [`warmup-eshop.yml`](.github/workflows/warmup-eshop.yml). The chain's
tools, `sk` and Portcullis, are built from commits pinned in [`pins.json`](pins.json).
What it does and how to run it: [`warmup/eshop/`](warmup/eshop/README.md).

## Contributing

Every clone enables the pre-commit secret scan once, before its first commit:

```sh
git config core.hooksPath .githooks
```

It needs [gitleaks](https://github.com/gitleaks/gitleaks/releases) and refuses to commit
without it; the same scan runs over the whole history on every push and pull request
([`secret-scan.yml`](.github/workflows/secret-scan.yml)). Secrets reach the scripts only
through environment variables, and a recording (`*.skcap`, `*.skrun`) of anything but the
bench's own sample-data shop is never committed.

## Licence

The bench (scripts, traffic, contract, results) is all rights reserved; see
[`LICENSE`](LICENSE). nopCommerce is licensed by its authors under its own terms.
