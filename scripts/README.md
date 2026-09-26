# Legacy runbook scripts

The numbered scripts are the legacy side of the bench, in the order you run them. CI runs
the same scripts, unmodified, so a failure in CI can be reproduced on any Windows machine
by running the same step.

| Step | Script | Needs | Produces |
|---|---|---|---|
| 1 | [`1-fetch-nopcommerce.ps1`](1-fetch-nopcommerce.ps1) | git (Windows or Linux) | `<work>\legacy-src`: a verified checkout of the pinned release |
| 2 | [`2-build-legacy.ps1`](2-build-legacy.ps1) | Windows, Visual Studio 2022 or Build Tools 2022 with the web development workload, git | `<work>\legacy-site`: the published site, plus `state\build.json` and `state\legacy-site.sha256` |

What is pinned, and where every download comes from, is in [`../pins.json`](../pins.json);
the reasons are in [`../docs/adr/`](../docs/adr/).

## Running it

From a PowerShell prompt (Windows PowerShell 5.1 or PowerShell 7) in the repository root:

```powershell
.\scripts\1-fetch-nopcommerce.ps1
.\scripts\2-build-legacy.ps1
```

If script execution is blocked by policy, run each script with
`powershell -ExecutionPolicy Bypass -File .\scripts\<script>.ps1`.

Each step checks its own preconditions and says what is missing. Nothing in this folder
reads a secret, and nothing it writes lands inside the repository.

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

## Hand-off files

Each step records what it produced in `<work>\state\<step>.json`, and the next step reads
it when you do not pass a parameter: explicit parameter first, then the hand-off file,
then the default. You never have to remember where the last step put things.

| File | Written by | Holds |
|---|---|---|
| `state\fetch.json` | step 1 | tag, commit, checkout path |
| `state\build.json` | step 2 | commit built, toolchain versions, site path, file count, manifest digest, timings |
| `state\legacy-site.sha256` | step 2 | SHA-256 of every published file, `sha256sum -c` compatible, ordinal-sorted |

## Recipes

- **Rebuild without re-fetching:** run step 2 alone; it verifies the existing checkout
  first and refuses to build a modified or different tree.
- **Start from scratch:** `.\scripts\1-fetch-nopcommerce.ps1 -Force`, then step 2.
- **Look inside a failed build:** open `<work>\logs\build.binlog` (or `publish.binlog`)
  with the [MSBuild Structured Log Viewer](https://msbuildlog.com/). CI uploads the same
  files as the `legacy-build-logs` artifact when the build fails.
- **Check a site against its manifest (Linux side):**
  `cd legacy-site && sha256sum -c ../state/legacy-site.sha256`.

## Conventions

- Scripts run on Windows PowerShell 5.1 and PowerShell 7; CI runs them on 5.1.
- ASCII only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
- Shared helpers live in [`lib/NopBench.Common.ps1`](lib/NopBench.Common.ps1), dot-sourced
  by each script, so any script runs on its own.
- Lint: `Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`
  (the `lint` job in CI runs exactly that).
