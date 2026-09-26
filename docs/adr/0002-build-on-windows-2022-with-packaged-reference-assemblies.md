# ADR 0002 — Build on `windows-2022` with the .NET Framework 4.5.1 reference assemblies from NuGet

- **Status:** accepted (P1)
- **Date:** 2026-09-26
- **Deciders:** implementation agent for P1; to be confirmed by the owner in review

## Context

All 31 projects of nopCommerce 3.90 target .NET Framework **4.5.1**. MSBuild compiles
against *reference assemblies* for the target framework, not against the runtime, and
the 4.5.1 targeting pack is no longer installed anywhere a CI job can reach:

| Hosted image (September 2026) | Visual Studio | .NET Framework targeting packs |
|---|---|---|
| `windows-2022` | Enterprise 2022, 17.14 | 4.5.2, 4.6, 4.6.2, 4.7, 4.7.1, 4.7.2, 4.8, 4.8.1 |
| `windows-2025` = `windows-latest` | Enterprise 2026, 18.x | 4.6.2, 4.7, 4.7.1, 4.7.2, 4.8, 4.8.1 |

(From the `actions/runner-images` readmes.) Without it the build stops at
`MSB3644: The reference assemblies for .NETFramework,Version=v4.5.1 were not found`.

The constraint from the ticket: solve it without modifying nopCommerce's source.

## Decision

1. **Reference assemblies from NuGet, passed as a property.** Step 2 downloads
   `Microsoft.NETFramework.ReferenceAssemblies.net451` 1.0.3 from nuget.org (the
   Microsoft-published package the SDK uses for the same purpose), verifies its pinned
   SHA-256, extracts it under the work root, and gives MSBuild
   `/p:TargetFrameworkRootPath=<package>\build`. MSBuild then resolves
   `.NETFramework\v4.5.1` (reference assemblies, facades, `RedistList\FrameworkList.xml`)
   from the package instead of from `Program Files`. Nothing is installed on the machine
   and no upstream file changes; step 2 verifies the checkout is still clean after the
   build.
2. **Runner: `windows-2022`**, pinned rather than `windows-latest`:
   - its MSBuild 17.14 and web application targets are the most direct descendant of the
     Visual Studio 2015 toolchain the projects were written for;
   - `windows-latest` already moved once (to Windows Server 2025 with Visual Studio 2026);
     a pinned label keeps the legacy build from changing underneath the bench;
   - the scripts depend on nothing image-specific (MSBuild is found on `PATH` or with
     `vswhere`, the reference assemblies come from `pins.json`), so moving to
     `windows-2025` is a one-line change. The workflow's manual trigger takes a `runner`
     input so that portability can be checked on demand without paying for a matrix on
     every push.
3. **Same scripts locally and in CI, on Windows PowerShell 5.1.** CI calls
   `scripts/1-fetch-nopcommerce.ps1` and `scripts/2-build-legacy.ps1` with no extra
   arguments. `microsoft/setup-msbuild` and `NuGet/setup-nuget` (nuget.exe 7.9.0, the
   same version the scripts fall back to) only put the tools on `PATH`.
4. **Upstream's own publish.** nopCommerce's `Deploying.Readme.txt` says: rebuild the
   solution, then publish `Nop.Web` in Release. Step 2 does exactly that from the command
   line (file-system web publish with `DeployDefaultTarget=WebPublish`). `Nop.Web.csproj`
   sets `FilesToIncludeForPublish=AllFilesInProjectFolder` and its own exclusion list, so
   the published folder already contains the built plugins (`Plugins\*`) and the
   Administration area, with source files, `*.csproj` and the install-state files left out.
5. **Hermetic builds.** `ImportDirectoryBuildProps=false` and
   `ImportDirectoryBuildTargets=false` stop any `Directory.Build.*` file above the
   checkout from leaking into the upstream projects.

## Alternatives considered

| Option | Why not |
|---|---|
| Retarget the projects to 4.5.2 or 4.8 | Modifies upstream source, and changes what is being migrated. |
| Install the 4.5.1 Developer Pack / Targeting Pack | .NET Framework 4.5.1 left support in January 2016 and its developer pack is on no current image; installing it in every run is slow and it changes a developer's machine. |
| Copy the package's assemblies into `Program Files (x86)\Reference Assemblies\...\v4.5.1` | Works, but writes to a machine-wide location that outlives the build and needs administrator rights. The property does the same job for one build only. Kept as the documented fallback for tools that ignore `TargetFrameworkRootPath`. |
| Add a `PackageReference` to the reference assemblies package | The projects use `packages.config`; mixing restore styles means editing every project. |
| `windows-2019` | Retired from GitHub-hosted runners in 2025. |
| A Windows container (`mcr.microsoft.com/dotnet/framework/sdk`) | Adds a container layer to the build and to P2's IIS and SQL Server for no gain: the host already has MSBuild, and the reference-assemblies question does not go away. |

## Consequences

- Reference assemblies are part of the pinned inputs: `pins.json` records the package
  version, URL and SHA-256, and `state\build.json` records which were used.
- The runtime is unaffected: the site runs on the machine's .NET Framework 4.8, which is
  an in-place replacement for 4.5.1, as every production host of this application does.
- If GitHub retires `windows-2022`, switch the default runner to `windows-2025` after a
  manual run with `runner: windows-2025` is green.
