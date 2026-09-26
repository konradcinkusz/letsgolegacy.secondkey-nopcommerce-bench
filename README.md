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

CI runs the same scripts on a `windows-2022` runner
([`legacy-build.yml`](.github/workflows/legacy-build.yml)) and publishes the site as the
`legacy-site` artifact. Parameters, hand-off files and recipes:
[`scripts/README.md`](scripts/README.md).

## Licence

The bench (scripts, traffic, contract, results) is all rights reserved; see
[`LICENSE`](LICENSE). nopCommerce is licensed by its authors under its own terms.
