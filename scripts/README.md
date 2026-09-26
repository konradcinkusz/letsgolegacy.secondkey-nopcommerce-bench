# Legacy runbook scripts

The numbered scripts are the legacy side of the bench, in the order you run them. CI runs
the same scripts, unmodified, so a failure in CI can be reproduced on any Windows machine
by running the same step.

| Step | Script | Needs | Produces |
|---|---|---|---|
| 1 | [`1-fetch-nopcommerce.ps1`](1-fetch-nopcommerce.ps1) | git (Windows or Linux) | `<work>\legacy-src`: a verified checkout of the pinned release |
| 2 | [`2-build-legacy.ps1`](2-build-legacy.ps1) | Windows, Visual Studio 2022 or Build Tools 2022 with the web development workload, git | `<work>\legacy-site`: the published site, plus `state\build.json` and `state\legacy-site.sha256` |
| 3 | [`3-install-iis-sql.ps1`](3-install-iis-sql.ps1) | Windows (Server or 10/11), elevated | IIS with ASP.NET 4.x; SQL Server 2022 Express as `.\SQLEXPRESS`; `state\platform.json` |
| 4 | [`4-deploy-and-install.ps1`](4-deploy-and-install.ps1) | Windows, elevated, after 2 and 3 | IIS site `nopcommerce-legacy` on `http://localhost:8080/`, database `nopcommerce_legacy` with sample data; `state\deploy.json`; the run's admin credentials in `secrets\legacy-admin.json` |
| 5 | [`5-smoke.ps1`](5-smoke.ps1) | Any machine that reaches the shop (PowerShell 5.1 or 7, Windows or Linux) | Pass/fail per check; `state\smoke.json` |

Not a step: [`collect-diagnostics.ps1`](collect-diagnostics.ps1) gathers IIS, event log,
SQL Server and nopCommerce logs into `<work>\diagnostics` after a failure (CI uploads it
as the `legacy-iis-diagnostics` artifact).

What is pinned, and where every download comes from, is in [`../pins.json`](../pins.json);
the reasons are in [`../docs/adr/`](../docs/adr/).

## Running it

From a PowerShell prompt (Windows PowerShell 5.1 or PowerShell 7) in the repository root:

```powershell
.\scripts\1-fetch-nopcommerce.ps1
.\scripts\2-build-legacy.ps1
# elevated from here on:
.\scripts\3-install-iis-sql.ps1
.\scripts\4-deploy-and-install.ps1
.\scripts\5-smoke.ps1
```

If script execution is blocked by policy, run each script with
`powershell -ExecutionPolicy Bypass -File .\scripts\<script>.ps1`.

Each step checks its own preconditions and says what is missing. Nothing any step
writes lands inside the repository, and every script's exit code is its own (each ends
with an explicit `exit 0`; a failure throws).

**The one secret.** Step 4 creates the store administrator with a password generated for
the run (or taken from `NOPBENCH_ADMIN_PASSWORD`). It is masked in CI logs, never printed,
and written only to `<work>\secrets\legacy-admin.json`, readable by the current user and
Administrators. Diagnostics never collect it. The database itself has no password: the
site connects with its application pool identity (Windows authentication).

## Parameters and environment variables

Every value has a default; nothing is required.

| Name | Scripts | Default | Meaning |
|---|---|---|---|
| `-WorkRoot` / `NOPBENCH_WORK` | all | `C:\nopbench` (`$HOME/nopbench` off Windows) | Working directory for every step: checkout, tools, downloads, logs, state. Keep it short: the web publish pipeline nests paths deeply and MSBuild's legacy tasks still hit the 260-character limit. |
| `-Destination` | 1 | `<work>\legacy-src` | Where to put the checkout. |
| `-Force` | 1 | off | Re-fetch even when a verified checkout exists. |
| `-SourceDir` | 2 | from `state\fetch.json`, else `<work>\legacy-src` | Checkout to build. It must be a clean checkout of the pinned commit. |
| `-SiteDir` | 2 | `<work>\legacy-site` | Publish target. Its content is replaced. |
| `-MSBuild` | 2 | `msbuild.exe` on `PATH`, else found with `vswhere` | MSBuild to use. |
| `-NuGet` | 2 | `nuget.exe` on `PATH`, else the pinned `NuGet.CommandLine` | nuget.exe to use for `restore`. |
| `-SkipIis`, `-SkipSql` | 3 | off | Leave that half alone (repairs). |
| `-SiteDir` | 4 | from `state\build.json`, else `<work>\legacy-site` | Published site to deploy; checked against `state\legacy-site.sha256`. |
| `-InstallDir` | 4 | `C:\inetpub\nopcommerce-legacy` | Folder IIS serves. Replaced on every run. |
| `-SiteName` | 4 | `nopcommerce-legacy` | IIS site and application pool name (also the SQL login `IIS APPPOOL\<name>`). |
| `-Port` | 4 | `8080` | HTTP port; step 4 refuses a port already in use. |
| `-SqlServer` | 4 | from `state\platform.json`, else `.\SQLEXPRESS` | SQL Server instance. |
| `-DatabaseName` | 4 | `nopcommerce_legacy` | Dropped and recreated on every run. |
| `-AdminEmail` | 4 | `admin@nopbench.invalid` | Store administrator e-mail (reserved domain). |
| `NOPBENCH_ADMIN_PASSWORD` | 4 | generated per run | Use a known administrator password instead of a generated one. Keep it out of files in the repository. |
| `-BaseUrl` | 5 | from `state\deploy.json`, else `http://localhost:8080/` | Shop to test. |
| `NOPBENCH_SK`, `NOPBENCH_PORTCULLIS` | steps that drive the chain | `<work>\tools\chain\secondkey\SecondKey.Cli.dll`, `<work>\tools\chain\portcullis\Portcullis.Cli.dll` | The chain's tools (below). |

## Hand-off files

Each step records what it produced in `<work>\state\<step>.json`, and the next step reads
it when you do not pass a parameter: explicit parameter first, then the hand-off file,
then the default. You never have to remember where the last step put things.

| File | Written by | Holds |
|---|---|---|
| `state\fetch.json` | step 1 | tag, commit, checkout path |
| `state\build.json` | step 2 | commit built, toolchain versions, site path, file count, manifest digest, timings |
| `state\legacy-site.sha256` | step 2 | SHA-256 of every published file, `sha256sum -c` compatible, ordinal-sorted |
| `state\platform.json` | step 3 | IIS state, SQL Server instance, version and collation |
| `state\deploy.json` | step 4 | URL, site, identity, database and its collation, table and product counts, timings |
| `state\smoke.json` | step 5 | every check with status, time and result |

## Recipes

- **Rebuild without re-fetching:** run step 2 alone; it verifies the existing checkout
  first and refuses to build a modified or different tree.
- **Start from scratch:** `.\scripts\1-fetch-nopcommerce.ps1 -Force`, then step 2.
- **Look inside a failed build:** open `<work>\logs\build.binlog` (or `publish.binlog`)
  with the [MSBuild Structured Log Viewer](https://msbuildlog.com/). CI uploads the same
  files as the `legacy-build-logs` artifact when the build fails.
- **Check a site against its manifest (Linux side):**
  `cd legacy-site && sha256sum -c ../state/legacy-site.sha256`.
- **Reinstall the shop from scratch** (new database, fresh sample data): run step 4 again.
- **Deploy a build made elsewhere:** put the `legacy-site` artifact's content in the work
  root (it carries `legacy-site\` and `state\`), then run steps 3 and 4.
- **Smoke-test from Linux:** `pwsh scripts/5-smoke.ps1 -BaseUrl http://<windows-host>:8080/`
  (open the port on the Windows host first; docs/TOPOLOGY.md has the command).
- **After a failure:** `.\scripts\collect-diagnostics.ps1`, then read `<work>\diagnostics`.

## The chain's tools

The steps that drive Second Key run `sk` (and the P3 gate scan runs Portcullis) as
`dotnet <assembly>`. CI builds both from the commits pinned in
[`../pins.json`](../pins.json) (`chain`) in
[`chain-tools.yml`](../.github/workflows/chain-tools.yml) and unpacks them into
`<work>\tools\chain\`. To do the same by hand (the .NET 10 SDK is the only prerequisite):

```sh
git clone https://github.com/konradcinkusz/letsgolegacy.secondkey.git secondkey
git -C secondkey checkout 967c49c0005c4412180914f43437d75b43f148dc   # chain.secondKey.commit
dotnet build secondkey/src/SecondKey.Cli/SecondKey.Cli.csproj -c Release -o <work>/tools/chain/secondkey
git clone https://github.com/konradcinkusz/letsgolegacy.portcullis.git portcullis
git -C portcullis checkout 84e1925fe0d85cf23415f0d33c98590f86128722  # chain.portcullis.commit
dotnet build portcullis/src/Portcullis.Cli/Portcullis.Cli.csproj -c Release -o <work>/tools/chain/portcullis
```

or point `NOPBENCH_SK` / `NOPBENCH_PORTCULLIS` at a `SecondKey.Cli.dll` / `Portcullis.Cli.dll`
built elsewhere.

## The P3 warm-up: `eshop\`

The whole chain on Microsoft's eShopLegacyMVC, on its mock data
([`../warmup/eshop/README.md`](../warmup/eshop/README.md),
[ADR 0004](../docs/adr/0004-chain-tools-and-eshop-warmup.md)). Same conventions as the
steps above; CI runs them in [`warmup-eshop.yml`](../.github/workflows/warmup-eshop.yml).

| Step | Script | Needs | Produces |
|---|---|---|---|
| 1 | [`eshop/1-build-eshop.ps1`](eshop/1-build-eshop.ps1) | Windows, Visual Studio 2022 or Build Tools 2022 (web workload), git | `<work>\eshop-site` (published, `UseMockData=true`); `<work>\eshop-src`; `state\eshop-build.json` |
| 2 | [`eshop/2-deploy-eshop.ps1`](eshop/2-deploy-eshop.ps1) | elevated, IIS (`3-install-iis-sql.ps1 -SkipSql`) | IIS site `eshop-legacy` on `http://localhost:8081/`; `state\eshop-deploy.json` |
| 3 | [`eshop/3-record-eshop.ps1`](eshop/3-record-eshop.ps1) | elevated, `sk` | `<work>\eshop\traffic.skcap` through `sk capture` on `:8001`; `state\eshop-traffic.json` (scenarios, session ids, counts) |
| 4 | [`eshop/4-replay-eshop.ps1`](eshop/4-replay-eshop.ps1) | elevated, `sk` | `<work>\eshop\run.skrun`: the A/A replay; `state\eshop-replay.json` |
| 5 | [`eshop/5-scan-eshop.ps1`](eshop/5-scan-eshop.ps1) | Portcullis | `<work>\eshop\portcullis.sarif`; `state\eshop-scan.json` |
| 6 | [`eshop/6-verdict-eshop.ps1`](eshop/6-verdict-eshop.ps1) | `sk`; Windows or Linux | `<work>\eshop\verdict.json`, `<work>\eshop\evidence\` (the pack); `state\eshop-verdict.json` |

Not steps: [`eshop/Reset-EShop.ps1`](eshop/Reset-EShop.ps1) restarts the application pool
and waits for the starting catalog (step 3 calls it before each scenario, `sk replay`
before each scenario on each side); [`eshop/EShop.Scenarios.ps1`](eshop/EShop.Scenarios.ps1)
holds the traffic.

## Conventions

- Scripts run on Windows PowerShell 5.1 and PowerShell 7; CI runs them on 5.1.
- ASCII only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
- Shared helpers live in [`lib/NopBench.Common.ps1`](lib/NopBench.Common.ps1), dot-sourced
  by each script, so any script runs on its own. The steps that drive Second Key also
  dot-source [`lib/NopBench.Chain.ps1`](lib/NopBench.Chain.ps1): the chain's tools, the
  recording proxy's start and stop, scripted sessions (one cookie jar, every request tagged
  with its scenario) and the fields of an HTML form as a browser would submit them.
- Traffic goes through the recording proxy only, and a step that does not get the answer
  its scenario needs fails the recording (`Invoke-BenchStep`).
- Lint: `Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`
  (the `lint` job in CI runs exactly that).
