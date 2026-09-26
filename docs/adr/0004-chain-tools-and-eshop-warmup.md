# ADR 0004 — The chain's tools from pinned commits; the warm-up on eShopLegacyMVC's mock data

- **Status:** accepted (P3)
- **Date:** 2026-09-26
- **Deciders:** implementation agent for P3; to be confirmed by the owner in review

## Context

P3 runs the whole Second Key chain — capture, replay, compare, gate, evidence — once on
Microsoft's own sample legacy application before it is pointed at nopCommerce, so that
problems with the chain surface on something small. It is done when an evidence pack is
produced. Three things had to be decided for it, and two of them outlive it: how the
bench gets the chain's tools, and how a recording is cut into scenarios.

## Decisions

### 1. The chain's tools are built from pinned commits, once per workflow run

`sk` (Second Key) and Portcullis (the gate's analyzers) are not published packages yet.
[`pins.json`](../../pins.json) pins each one to a commit (`chain.secondKey`,
`chain.portcullis`). The reusable workflow
[`chain-tools.yml`](../../.github/workflows/chain-tools.yml) checks both out with
`actions/checkout` at those commits, verifies the checked-out commit, builds the two
command-line projects with the .NET 10 SDK that sk's `global.json` names, and hands them
on as the `chain-tools` artifact.

The build is framework-dependent and portable, so the same files run on the Windows host
(capture, replay) and on Linux (compare, gate, evidence): `dotnet SecondKey.Cli.dll`. The
scripts find a tool through `NOPBENCH_SK` / `NOPBENCH_PORTCULLIS`, else under
`<work>\tools\chain\<tool>\`.

Moving a pin is a reviewed change to `pins.json`, like every other pin.

### 2. One scenario is one session, named by a request header

`sk replay` replays a capture scenario by scenario, resetting each side before each one
and giving each a fresh cookie jar; `sk capture` decides which session an exchange belongs
to from a configured cookie or header. The traffic scripts set `x-bench-scenario: <id>`
on every request of a scenario, and the capture is told to use that header as its session
key. Consequences:

- the scenario list of the traffic plan *is* the replay's scenario list, one to one, and
  a verdict can be read back to it: the session id is `s-` plus the first 12 hex digits of
  SHA-256(`x-bench-scenario` + newline + id), which the record step prints for every
  scenario;
- a scenario survives an application that changes its session cookie mid-way — nopCommerce
  issues a new customer cookie at login — which a cookie-based session key would split
  into two scenarios with a reset in between;
- one scenario has one cookie jar, so a story with two people in it is two scenarios.

The header is recorded and replayed like any other; the applications ignore it.

### 3. The recording proxy is stopped when it holds every exchange that was sent

The traffic scripts count every request they send through the proxy. `sk capture`
flushes each exchange to the file as it writes it, so after the last scenario the record
step waits until the file holds exactly that many exchanges and then stops the process. A
count that does not match fails the step: an exchange the application did not answer is
not recorded, and one the scripts did not send is not the scripted traffic.

(`--exit-after` needs the count before the traffic runs, and a clean Ctrl+C cannot be
delivered to a background process on Windows without a console-sharing helper.)

### 4. The warm-up application: eShopLegacyMVC on its own mock data

| | |
|---|---|
| Source | `dotnet-architecture/eShopModernizing` at `63bc9ec4414d7e281dc9f9d7bdcf70030950457d` (the head of `main`, 2023-10-25; the repository has no tags), fetched by commit id and checked like nopCommerce's pin |
| Application | `eShopLegacyMVCSolution/src/eShopLegacyMVC`: ASP.NET MVC 5.2.7 and Web API on .NET Framework 4.7.2, Autofac, a catalog manager (list, details, create, edit, delete) and a brands Web API |
| Data | the application's own `UseMockData` switch, set to `true` in the **published** `Web.config` (the source is not changed): an in-memory catalog of 12 items, no database |
| Build | MSBuild restore (the project uses PackageReference) and file-system web publish, Release. Its utility library targets .NET Framework 4.6.1, whose targeting pack the hosted image no longer has; as in [ADR 0002](0002-build-on-windows-2022-with-packaged-reference-assemblies.md), the 4.6.1 and 4.7.2 reference assemblies come from pinned NuGet packages, laid out under one `TargetFrameworkRootPath` |
| Host | IIS on the `windows-2022` runner, site `eshop-legacy` on port 8081, application pool with no idle time-out and no periodic recycle; recording proxy on 8001 ([`TOPOLOGY.md`](../TOPOLOGY.md)) |

The mock catalog lives in one in-memory list for the lifetime of the worker process,
so the only reset is a new process: [`Reset-EShop.ps1`](../../scripts/eshop/Reset-EShop.ps1)
stops and starts the application pool and waits for the full catalog. The record step
calls it before each scenario, and `sk replay` calls it before each scenario on each side
(the `command` reset in [`warmup/eshop/secondkey.yaml`](../../warmup/eshop/secondkey.yaml)).
Create, edit and delete validate an anti-forgery token issued with the form; the replay's
correlation rule carries the fresh token into the form it posts.

### 5. A/A, and the gate on the whole tree

There is no candidate in the warm-up. The replay's two sides are the same site, so the
verdict shows what the chain itself adds: it must be `pass`, with every accepted clause of
the small [warm-up contract](../../warmup/eshop/contract.yaml) held and none unexercised.

Portcullis scans the legacy source as a whole tree: there is no pull request whose changed
lines it could be scoped to. Its findings are the .NET Framework idioms a migration would
have to remove; `sk gate` reports that its errors would block a change, and the step
records that result rather than failing on it. P8 gates the candidate's pull request the
way the gate is meant to be used.

### 6. Where each step runs

As [`TOPOLOGY.md`](../TOPOLOGY.md) planned: build, IIS, capture, replay and the source
scan on the Windows runner, next to the application; compare, gate and evidence on Linux,
from the files the Windows job uploads. The warm-up is the first run of that split.

## Consequences

- Every workflow that drives the chain calls `chain-tools.yml`; a tool upgrade is one
  change to `pins.json`.
- The traffic scripts must set the scenario header on every request and must send every
  request through the proxy; the record step enforces the count.
- The warm-up's pack is a CI artifact, not a published result; its numbers are in
  [`results/p3/`](../../results/p3/).
