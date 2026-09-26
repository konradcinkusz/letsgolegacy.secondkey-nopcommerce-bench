# ADR 0007 — P9's killed mutants: pre-registered patches, each run as a second site on the legacy database, calibrated by M00

- **Status:** accepted (P9, mutant part)
- **Date:** 2026-09-26
- **Deciders:** implementation agent for P9; to be confirmed by the owner in review

## Context

P9 publishes the bench's numbers — scenarios, diffs, regressions and **killed mutants**.
Mutation testing proper, `sk mutate` (C9), is phase-02 work, so phase 01 needs the number
another way, and without anything new in `sk`. Whatever produces it must give the contract
the same test the migrated candidate will get in P7: the P4 recording replayed with
`sk replay`, both sides reset to the same starting state before every scenario, and
`sk compare` judging the difference against the P5 contract.

## Decisions

### 1. Hand-written mutants, pre-registered

Eleven small, plausible, behavioural defects, each one unified diff against the pinned
nopCommerce (`mutants/*.patch`), with a catalog naming the clauses expected to catch each
([`mutants/mutants.json`](../../mutants/mutants.json),
[`docs/P9-MUTANTS.md`](../P9-MUTANTS.md)). All of it was committed in one commit before
the first mutant ran, and the expectations are never edited after a result is seen:
otherwise the number measures how well the set was tuned to the contract, not how well the
contract catches defects. Killed means `sk compare`'s outcome is `fail`; a survivor is
reported as one, and the contract is not changed to kill it here.

The patches keep nopCommerce's CRLF line endings byte for byte (`.gitattributes`), are
applied with whitespace tolerance, and fail loudly when they do not apply: step 1 of the
workflow checks every patch against the pinned tree before any Windows runner starts.

### 2. Step 2 builds a mutant with `-Patch`

The mutant is built by the same step as the legacy site. With `-Patch` step 2 applies the
patch to the clean pinned checkout, checks that the tree holds exactly the patch before
and after the build, and restores the patched files afterwards; `state\build.json` records
the patch and its SHA-256. The mutant is built in a work root of its own, so its state
files and manifest never replace the legacy site's. Without `-Patch` step 2 is unchanged,
and the published legacy site is still provably a build of unmodified upstream source.

### 3. The mutant runs as a second IIS site on the legacy shop's database

| Option | Verdict |
|---|---|
| **A second site beside the legacy one, on its database** | **Chosen.** The mutant's files in their own folder, the legacy install's `App_Data\Settings.txt` and `InstalledPlugins.txt` copied in, its own site, pool and port (8091); its pool identity gets `db_owner` in `nopcommerce_legacy`. Both sides are restored from the one snapshot before every scenario, so `contract/secondkey.yaml` and `8-replay.ps1 -Candidate` serve unchanged, and the store configuration is the one step 6 made and read back. |
| A second install on a database of its own | Needs a second installer run and a second store configuration, and a second snapshot and reset configuration; the two sides would start from data made twice - order numbers, identities and the admin's generated state could differ - and a "kill" could be that. |
| Replace the legacy site's files with the mutant's | Leaves nothing to compare against: the replay needs both systems answering at once. |
| The mutant in the legacy site's application pool | The same identity, so no database user; but one worker process for both sides, and a mutant that brings its process down takes the legacy side with it. |

Port 8091: 8081 is the P3 warm-up's and 8090 the P7 candidate's
([`TOPOLOGY.md`](../TOPOLOGY.md)).

Two consequences are enforced by the deploy script, not remembered:

- **The database user must be in the snapshot.** Step 7 takes the snapshot, and every
  restore returns the database to it; a user created afterwards would vanish at the first
  restore. The mutant is therefore deployed after step 6 and before step 7, and a snapshot
  that exists without the user is refused. A later mutant on the same host reuses it.
- **The mutant must really be on that database.** Its first answer is awaited, and the
  deploy fails unless a new "Application started" entry appeared in the legacy database's
  nopCommerce log.

The two sites answer on different ports, and nopCommerce writes absolute URLs from the
request's host. `sk replay` sends each side its own host, and `sk compare` replaces each
side's own base URL with `<base-url>` before comparing, so that is not a difference.

### 4. M00 calibrates the method

M00 is the pinned source without a patch, built and deployed exactly like the mutants. Its
replay must come out `pass`: two application instances of the same code, on one database,
replayed against each other. A run whose M00 is not `pass` counts no mutant result - the
workflow's summary job fails and `mutants.json` says so - because a difference between the
sites that is not code would otherwise be counted as kills.

### 5. One Windows job per mutant; verdicts on Linux

`mutants.yml` builds the legacy site once and gives every mutant its own `windows-2022`
job - a runner is a clean host, so no mutant sees another's site, database or cache - that
runs the legacy steps 3-8 unchanged around the mutant's deployment. The verdict, the
evidence pack and the outcome are file in, file out on Linux, one job per mutant, and a
summary job writes `mutants.json`. It runs on pull requests that touch the mutants, their
scripts or the workflow, and on demand; the A/A workflow is not changed.

## Consequences

- Each mutant's evidence pack is a CI artifact (`mutant-<id>-evidence-pack`), like the A/A
  pack; the numbers are in [`results/p9`](../../results/p9/README.md).
- A mutant job pays for a full legacy host (SQL Server Express, installer, configuration,
  recording): about 20 minutes, in parallel.
- The traffic set is recorded anew in every mutant job, from that job's snapshot, so each
  replay compares data that both sides really started from.
- `sk mutate` (C9, phase 02) replaces the hand-written set with generated mutants; the
  deployment beside the legacy site and the M00 calibration carry over.
