# P10 — onboarding-hours log

How long it takes to put a real legacy system under Second Key is one of the numbers the
phase 01 report publishes (P9). This log is where those hours are written down, as they
are spent, by whoever spends them.

- **Done when (docs/WORKPLAN.md):** the hours are in the published report.
- **Scope:** P4–P7 are what the report counts as onboarding. P1 and P2 are logged too,
  separately, because they are the one-off cost of making the legacy side run at all.

## Rules

1. **One row per session per worker.** A session is a stretch of work on one ticket.
2. **Hours are wall-clock hours actually spent**, in decimal hours (0.25 = 15 minutes).
   Time spent waiting for CI or for an agent counts only when nothing else was done
   meanwhile — then log it as its own row with the activity "waiting".
3. **Who is a person or an agent, never both.** Write a person's name, or
   `agent: <model> (<tool>)`. Agent time and human time are reported separately and
   never added together: an agent hour is not an engineer hour.
4. **Evidence for every row:** the pull request, workflow run or record the time produced.
5. **Estimates are marked as estimates.** Anything reconstructed after the fact says
   so in the activity.

## Log

| Date (UTC) | Ticket | Activity | Hours | Who | Evidence |
|---|---|---|---|---|---|
| 2026-09-26 | P1 | Read the work plan and the standards; study how nopCommerce 3.90 builds (solution, 31 projects on .NET Framework 4.5.1, committed packages, web publish targets); check the hosted Windows images; choose and pin the release and the toolchain | 0.40 | agent: Claude Opus 5.5 (Claude Code) | #1 |
| 2026-09-26 | P1 | Write `pins.json`, scripts 1–2 and their shared library, the workflow and ADRs 0001–0002; run script 1 and the library under PowerShell 7 on Linux; three CI runs (one fixed a summary helper) | 0.35 | agent: Claude Opus 5.5 (Claude Code) | #1, [run 36228862719](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36228862719) |
| 2026-09-26 | P2 | Read nopCommerce's installer (`InstallController`, `InstallModel`, `FilePermissionHelper`) and sample data; write scripts 3–5 and the diagnostics collector; run the smoke test against a local stand-in for the shop (pass and fail paths) | 0.30 | agent: Claude Opus 5.5 (Claude Code) | #2 |
| 2026-09-26 | P2 | First host run failed in SQL Server setup; add diagnostics, a guarded data-directory fallback and one retry; write TOPOLOGY.md, ADR 0003 and the READMEs; three CI runs | 0.45 | agent: Claude Opus 5.5 (Claude Code) | #2, [run 36230860176](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/36230860176) |
| 2026-09-26 | P4 (preparation) | Read nopCommerce 3.90's discount, price, order-total, tax, shipping, cart and order services; write the traffic plan with source citations | 0.40 | agent: Claude Opus 5.5 (Claude Code) | #3 |
| 2026-09-26 | P6 (preparation) | Write the P6 runbook | 0.15 | agent: Claude Opus 5.5 (Claude Code) | #3 |
| 2026-09-26 | P10 | Start this log | 0.05 | agent: Claude Opus 5.5 (Claude Code) | #3 |

The agent rows cover one session of about two hours of wall-clock time, from reading
the work plan to opening the third pull request. The split between rows is an estimate
reconstructed from commit and workflow timestamps; much of the writing overlapped with
CI runs, which is why no "waiting" row appears.

Human time so far: none. The owner's review and merge of #1–#3 is the first human
entry to add.

## CI time (not onboarding hours)

Runner minutes are a cost, not effort, and are kept apart from the hours above. Public
repositories run on GitHub-hosted runners at no charge.

| Pull request | Workflow runs | Windows minutes | Linux minutes |
|---|---|---|---|
| #1 (P1) | 3 (one failed) | 4.5 | 1.2 |
| #2 (P2) | 3 (one failed) | 28.3 | 1.5 |
| #3 (plans) | see the pull request | ~7 per run | ~0.5 per run |

A green run of the whole legacy workflow takes about 7 minutes: build 1.5, IIS + SQL
Server + installer + smoke test 5 to 5.5, lint 0.5 in parallel. The failed P2 run took
13.4 minutes, 11 of them inside SQL Server setup.

## Totals

| | Human hours | Agent hours |
|---|---|---|
| P1–P2 (legacy side) | 0 | 1.50 |
| P4 and P6 preparation (plans written before those tickets start) | 0 | 0.55 |
| P10 (this log) | 0 | 0.05 |
| P4–P7 onboarding proper | 0 | 0 |
