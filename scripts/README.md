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

## Conventions

- Scripts run on Windows PowerShell 5.1 and PowerShell 7; CI runs them on 5.1.
- ASCII only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
- Shared helpers live in [`lib/NopBench.Common.ps1`](lib/NopBench.Common.ps1), dot-sourced
  by each script, so any script runs on its own.
- Lint: `Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`
  (the `lint` job in CI runs exactly that).
