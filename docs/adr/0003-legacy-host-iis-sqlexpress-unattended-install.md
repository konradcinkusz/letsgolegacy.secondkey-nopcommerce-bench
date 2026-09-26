# ADR 0003 — Legacy host: IIS through DISM, SQL Server 2022 Express with Windows authentication, installer driven over HTTP

- **Status:** accepted (P2)
- **Date:** 2026-09-26
- **Deciders:** implementation agent for P2; to be confirmed by the owner in review

## Context

P2 is done when the shop answers at a URL: the site built in P1 must run under IIS with
SQL Server and nopCommerce's sample data, unattended, on a GitHub-hosted Windows runner
and — with the same scripts — on a workstation (docs/TOPOLOGY.md, D7). The recording and
replays that follow (P4, P7) need that host to be reproducible, to start from a known
state, and to carry no secret that could leak into a public repository or log.

## Decisions

### 1. SQL Server 2022 **Express**, installed from Microsoft's media by the script

| Option | Verdict |
|---|---|
| **SQL Server 2022 Express, named instance `SQLEXPRESS`, from `SQLEXPR_x64_ENU.exe`** | **Chosen.** A real Windows service, as in production; reachable by the IIS application pool identity; supports database snapshots (core S11); small core media (one file) that the script pins by SHA-256 and checks for a valid Microsoft Authenticode signature. CI caches the verified file. |
| LocalDB (already on the image) | Per-user instances started on demand. An IIS application pool can only use one with profile loading and instance-sharing workarounds, and the replay tools running as another user would not see the same instance. Not what a legacy shop runs on. |
| Developer edition | Full feature set we do not need, a 1 GB+ download. |
| A container | Microsoft no longer publishes SQL Server Windows container images, and Linux containers do not run on the Windows runner. |
| Chocolatey `sql-server-express` | Wraps the same media and switches; adds a third-party repository to the trust chain for nothing. The package's published checksum was used to seed the pin, and our own script does the verification. |
| A GitHub Action (`mssqlsuite`, ...) | Would work in CI only; the workstation path needs the same steps as a script anyway. |

Setup runs with `/SQLSYSADMINACCOUNTS=BUILTIN\Administrators` (the elevated operator is
the administrator), `/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS` (ordering and equality in
the database must not depend on the host's locale) and
`/SKIPRULES=RebootRequiredCheck` (enabling IIS a minute earlier may leave an unrelated
restart pending).

### 2. Windows authentication for the site, no password in any connection string

The application pool identity `IIS APPPOOL\nopcommerce-legacy` gets a Windows login on
SQL Server with **`dbcreator` only**; nopCommerce's installer creates the database and
therefore owns it. The connection string nopCommerce stores in `App_Data\Settings.txt`
is `Integrated Security=True`: there is no SQL password to generate, store, rotate or
leak. Other identities that need the database later (the replay's state reset, a
candidate running as its own pool) get their own login the same way.

### 3. IIS through DISM optional features, configured with `appcmd`

`dism.exe /Online /Enable-Feature /All` with the IIS and ASP.NET 4.x feature names works
identically on Windows Server and Windows 10/11, so CI and a workstation share one code
path. `appcmd.exe` ships with IIS and behaves the same under Windows PowerShell 5.1 and
PowerShell 7, unlike the `WebAdministration` module. Response compression is not
installed, so recorded bodies stay plain.

The application pool has no idle time-out and no periodic recycle: a recording or a
replay must not straddle a restart of the application it is observing.

### 4. Seed through the application's own installer, over HTTP

Step 4 posts nopCommerce 3.90's install form — the fields of `InstallModel` and
`Views/Install/Index.cshtml` — exactly as a person submits it at `/install`, with
"create database" and "create sample data" on and a pinned collation. The alternatives
were rejected:

- running the installer's SQL (`App_Data\Install\Fast\*.sql`) directly would seed around
  the system instead of through it, and skips the plugin installation the form performs;
- restoring a prepared `.bak` would put a binary database of unknown provenance in the
  chain.

Success is not taken on trust: the install form must have been served first (so the
site was not already installed), the answer must be the installer's redirect to the home
page, `App_Data\Settings.txt` must exist, the home page must answer with nopCommerce
content, and the database must contain the sample products.

### 5. A clean install on every run

Step 4 deletes the site, the application pool and the database before deploying. A
re-run therefore converges on the same state rather than accumulating one — the property
the recording (P4) and the replays (P7) depend on. The site is checked against the
SHA-256 manifest written by the build, so what IIS serves is provably what was built.

### 6. Throwaway administrator credentials

The installer requires a store administrator. Its password is generated per run (32
characters from a CSPRNG) unless `NOPBENCH_ADMIN_PASSWORD` is set, registered with the
Actions log masker, never printed, and written only to
`<work>\secrets\legacy-admin.json` with an ACL limited to the current user,
Administrators and SYSTEM — outside the repository, and never collected into
diagnostics. The e-mail is `admin@nopbench.invalid`, a reserved domain.

### 7. Port 8080

Port 80 stays with the Default Web Site. 8080 is free on the hosted image; the proposed
ports for the recording proxy (8000) and the candidate (8090) are in docs/TOPOLOGY.md.
Step 4 refuses to start if the port is taken.

## Consequences

- The host job pays for SQL Server Express setup on every run (the media download is
  cached); the job summary reports each phase's duration.
- If Microsoft replaces the file behind the pinned URL, step 3 fails on the SHA-256
  check with both hashes in the message. Updating the pin is then a reviewed change,
  not an automatic one.
- The sample data is nopCommerce's own and dated 2017. Time-dependent behaviour (for
  example a sample discount that expired on 2020-01-01) is recorded as it is.
