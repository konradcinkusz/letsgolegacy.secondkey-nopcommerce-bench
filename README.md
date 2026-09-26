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

## Warm-up: the chain on eShopLegacyMVC (P3)

Before the chain meets nopCommerce it runs once, end to end, on Microsoft's sample legacy
application eShopLegacyMVC (on its own mock data): capture, A/A replay, compare, gate and
evidence pack, in [`warmup-eshop.yml`](.github/workflows/warmup-eshop.yml). The chain's
tools, `sk` and Portcullis, are built from commits pinned in [`pins.json`](pins.json).
What it does and how to run it: [`warmup/eshop/`](warmup/eshop/README.md).

## Licence

The bench (scripts, traffic, contract, results) is all rights reserved; see
[`LICENSE`](LICENSE). nopCommerce is licensed by its authors under its own terms.
