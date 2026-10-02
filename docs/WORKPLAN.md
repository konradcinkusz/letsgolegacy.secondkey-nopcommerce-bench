# Work plan — `letsgolegacy.secondkey-nopcommerce-bench` (public specimen)

The public proof that the Second Key chain works on real legacy code: an older
nopCommerce (3.x, classic ASP.NET MVC on .NET Framework) — a real shop with discounts,
taxes and shipping, where "never" rules mean something. Microsoft's modernize-dotnet
agent performs the migration; Second Key only checks it.

nopCommerce itself is **not vendored** into this repository: CI downloads the pinned
release from the upstream project at build time, so this repository carries only the
bench (scripts, traffic, contract, results) under its own terms and nopCommerce stays
under its own licence.

Ticket IDs match the cross-repository backlog. One ticket is one pull request unless it
is marked as human work.

## Phase 01 — demo (this repository's P9 is the phase gate)

| ID | Deliverable | Done when | Status |
|---|---|---|---|
| P1 | Repository, pinned nopCommerce 3.x version, build on a Windows runner | CI builds it | done (#1) |
| P2 | Legacy under IIS (demo topology: one Windows host for the legacy side, Linux for the rest) with SQL Server and seed data | The shop answers at a URL | done (#2) |
| P3 | Warm-up run of the chain on Microsoft's eShopModernizing | A pack is produced; after core S15 | done (#4) |
| P4 | nopCommerce traffic set (catalog, cart, discounts, taxes, shipping, checkout) recorded to `*.skcap` | The scenario count is recorded | done (#5) |
| P5 | nopCommerce contract: "must" and "never" rules, about 20% absence assertions | It validates and passes on the legacy system; after core S8 | done (#6) |
| P6 | modernize-dotnet run on nopCommerce with the standards skill from R4 | The candidate builds and the existing tests pass — **human work: requires GitHub Copilot** | planned |
| P7 | Replay and compare legacy vs candidate; diffs reviewed | `verdict.json` exists, and the NLS → ICU difference is found or its absence documented | planned |
| P8 | Portcullis migration rules run on the candidate PR (R2, R3) | SARIF is attached to the pack | planned |
| P9 | Publish the evidence pack, the contract and the numbers (scenarios, diffs, regressions, killed mutants) | Public and linked from both decks | in progress: killed mutants done (#8), **11 of 11**. Open: the candidate's evidence pack, diffs and regressions (after P6–P8, none done yet), the links from both decks |
| P10 | Onboarding-hours log for P4–P7 | The hours are in the published report | in progress: the log exists (#3); agent hours through P5 and for P9's mutants are in it, the later ones estimated after the fact; human hours none yet |

What the tickets produced, as CI recorded it: [`results/p3`](../results/p3/README.md) — the
warm-up's pack; [`results/p4`](../results/p4/README.md) — the nopCommerce traffic set,
**38 scenarios, 290 exchanges**; [`results/p5`](../results/p5/README.md) — the contract's
A/A verdict on the legacy shop, **pass: 76 of 76 clauses held**, 15 of them `never`;
[`results/p9`](../results/p9/README.md) — the killed mutants of the set registered in
[`P9-MUTANTS.md`](P9-MUTANTS.md), **11 of 11 killed**, M00 (the calibration) passing.

Prepared ahead of the tickets that use them (#3):
[`P4-TRAFFIC-PLAN.md`](P4-TRAFFIC-PLAN.md) — the scenario list and the must/never rules
P5 will assert; [`P6-RUNBOOK.md`](P6-RUNBOOK.md) — the human steps of P6;
[`P10-ONBOARDING-HOURS.md`](P10-ONBOARDING-HOURS.md) — the hours log.
[`TOPOLOGY.md`](TOPOLOGY.md) records the demo topology (proposed decision D7), and
[`adr/`](adr/) the decisions taken in P1–P5 and in P9's mutant part.

## The "aha" moment the demo is built around

The agent migrates, the build and the existing tests pass, and Second Key still finds a
real behavioural difference. The best candidate: moving from .NET Framework to modern
.NET switches globalization from NLS to ICU, so culture-sensitive string comparison
and sorting can change — a known, documented migration trap.
