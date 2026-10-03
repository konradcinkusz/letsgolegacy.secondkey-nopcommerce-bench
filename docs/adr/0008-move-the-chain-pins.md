# ADR 0008 — The chain's pins move for the first time: `sk` to `c3ae5c2`, Portcullis to `d045f07`

- **Status:** accepted (ahead of P7 and P8)
- **Date:** 2026-10-03
- **Deciders:** implementation agent; to be confirmed by the owner in review

## Context

[`pins.json`](../../pins.json) pins the tools the bench drives, `sk` and Portcullis, to
commits, and [`chain-tools.yml`](../../.github/workflows/chain-tools.yml) builds exactly those
([ADR 0004](0004-chain-tools-and-eshop-warmup.md) §1: moving a pin is a reviewed change). P3
set both on 2026-09-26; every result in [`results/`](../../results/) was made on them. Two
reasons to move them now:

- **P8 needs a Portcullis that parses C# 14.** P8 scans the P6 candidate's pull request
  ([`P6-RUNBOOK.md`](../P6-RUNBOOK.md) §9), a .NET 10 solution, and a .NET 10 project compiles
  C# 14 by default. The pinned Portcullis (`84e1925`) predates `52d9f1e`, "The scanner parses
  C# 14; the analyzer package keeps its Roslyn floor": it parses with Roslyn 4.11, whose newest
  language is C# 13, so a C# 14 construct is a syntax error.
- **The pinned `sk` predates behaviour its documentation now describes.** The bench cites the
  core's `docs/cli.md` as sk's interface
  ([`NopBench.Chain.ps1`](../../scripts/lib/NopBench.Chain.ps1)). At `967c49c` it has no
  chapter on `sk capture` or `sk replay`; it gained both from this bench's findings
  (`51e1754`), and the code was made to agree with its exit codes (`7939e80`).

## Decision

Both pins move to the head of the tool's `main`:

| Pin | From | To |
|---|---|---|
| `chain.secondKey.commit` | `967c49c0005c4412180914f43437d75b43f148dc` | `c3ae5c28efece2a665a693dbcfa15767197d4ab3` |
| `chain.portcullis.commit` | `84e1925fe0d85cf23415f0d33c98590f86128722` | `d045f07daf948ac07c3ac62481cc2a97c5d10846` |

Each new commit descends from the old pin, is the head of `origin/main` and has every check of
its repository green. Nothing else changes: paths, assemblies, build, SDK (sk's `global.json`
is the same at both commits). The places that quote the pins as the current setup move with
them: [`scripts/README.md`](../../scripts/README.md) and the `$schema` line of
[`warmup/eshop/contract.yaml`](../../warmup/eshop/contract.yaml) (the schema file is the same
blob at both commits). Portcullis alone would be all P8 needs, but the A/A and mutant numbers
(P5, P9) would then stay with an older `sk`, and moving it later would change the tool between
them and the candidate's verdict (P7).

## What changed that matters to the bench

Method: `git log --no-merges <old>..<new>` in each repository, every commit that touches code
read as a diff; then the scripts, both `secondkey.yaml`, both contracts and the workflows read
for what they depend on: option names, exit codes, the text and file lines the scripts parse.

**Second Key**: 29 commits besides merges. 9 change `src/`, 6 tests, CI or the sample contract,
10 documentation, 1 a secret-scan rule, 3 GitHub Actions bumps. Capture, compare, the
exit-code table, the file formats and the contract schema are untouched, so the verdict logic
is the same. Reaching the bench:

- `7939e80`, `9574718`: the values of `secondkey.yaml` are checked when the file is read, by
  every command and by `sk validate`, and a wrong one exits 3: absolute http(s) URLs,
  `scenarioMode`, `evidence.pdf`, one reset kind, correlation patterns that compile and
  capture a group. Both bench files comply.
- `05ba3b3`: a single-value operator (`lt`, `lte`, `gt`, `gte`, `between`, `approx`, `matches`,
  `notMatches`) on the whole list of an `all: true` extractor is refused. Both contracts use
  whole lists only with `equals`, `contains` and the `count*` operators.
- `d39e264`: `sk evidence --pdf required` prints before it touches the output directory, and a
  failure leaves it as it was (it left four files and deleted a previous pack). The three
  verdict jobs use `-Pdf required`; the success path is the same.

Read, without effect here: `51e1754` (a stopped command gets a minute; the record steps end
the proxy with `Stop-Process -Force` once the file holds every exchange sent), `b2e1bb7` (JSON
ends its lines with `\n` on Windows too; compare and evidence run on Linux), the
`workingDirectory` and http-reset fixes in `7939e80` (unused), `8609426`, `bbea70d`, and
`56dbb8d` (the replay engine refactored with tests; read as behaviour-preserving).

**Portcullis**: 24 commits besides merges. 10 dependency bumps, 5 documentation, 2 repository
baseline and secret scan, 7 touching `src/`, `fixtures/` or `action.yml`. The CLI, the SARIF
writer, provenance and the rules are untouched. Reaching the bench:

- `52d9f1e`: the scanner parses with Roslyn 5.9 (it was 4.11), so C# 14 parses; the analyzer
  package keeps its 4.8.0 floor. The reason for the move.
- `e62d5e2`: `scanStartedUtc` in the scan report is when the scan started (it was read after
  it). `5-scan-eshop.ps1` reads only the SARIF.

Read, without effect here: `8adce5d` (the Action's `gate-scope` output), `a933149`, `f333d8c`
and `5c7fec8` (a CI job, a probe and its revert), `05c7ebf` (rule ids in documents and mock
scans, a comment in `RuleRegistry.cs`; no rule changes), `7dee554` (a documented, tested
behaviour of the pull-request comment).

## How it was verified

Locally (Linux, .NET SDK 10.0.112), the four commits built as `chain-tools.yml` builds them:

- `sk validate` accepts both contracts and both `secondkey.yaml` with either build. As a
  control, the new build refuses (exit 3) copies with a correlation pattern without a group,
  with an unclosed group, a misspelt `scenarioMode`, two reset kinds, or `gt` on a whole list;
  the old build accepts all five.
- Portcullis on eShopLegacyMVC at the pinned commit, called as `5-scan-eshop.ps1` calls it:
  both builds exit 1 with the same 27 findings (those of `results/p3`) and a byte-identical
  SARIF; the report differs only in `scanStartedUtc` and `scanDurationMs`. On the sample of
  `ScannerLanguageVersionTests` the new build reports `PORTCULLIS_MIG_SYNC_OVER_ASYNC` inside
  the `extension` block; the old build reports nothing.
- A capture and an A/A replay of a small stand-in application, then `sk compare` and
  `sk evidence --pdf required`, with both builds: the same counts and verdict, every pack digest
  matching its manifest, the lines the scripts parse unchanged. Without a browser,
  `--pdf required` exits 4 in both; the old build leaves four files, the new one none.

IIS, the snapshot reset and the Windows host only CI exercises. A change of `pins.json` runs
[`legacy-build`](../../.github/workflows/legacy-build.yml) and
[`warmup-eshop`](../../.github/workflows/warmup-eshop.yml) on the pull request;
[`mutants`](../../.github/workflows/mutants.yml) runs only on its own paths and is dispatched
on the branch. They must show:

| Workflow | Must show | Before the move |
|---|---|---|
| `legacy-build` | A/A verdict `pass`, 290 exchanges, 0 regressions, 76 of 76 clauses held, 0 unexercised; a pack with `report.pdf` | [run 37057742250](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/37057742250) |
| `warmup-eshop` | verdict `pass`, 27 exchanges, 0 regressions, 13 of 13 held; gate `fail (7 blocking)` | [run 37057742264](https://github.com/konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench/actions/runs/37057742264) |
| `mutants` | M00 `pass`, 11 of 11 killed, `summary` job green | [`results/p9`](../../results/p9/README.md) |

The runs on the new pins are linked from the pull request that adds this record.

## Consequences

- A result recorded at the old pins stays as recorded: `results/p3`, `p4`, `p5` and `p9` name
  the commits they ran on and are not edited; runs on the new pins are new records. Both builds
  call themselves `secondkey 0.1.0` (`"commit": null` in a pack's statement), so a verdict or a
  pack does not say which build made it; the pins at the bench commit and the `COMMITS` file of
  the run's `chain-tools` artifact do, and a result quotes them.
- The comparison logic, formats and schema are the same, so the A/A and mutant numbers are
  expected to repeat. If they do not, that is a finding about the move, explained here.
- The download caches are keyed on `hashFiles('pins.json')`: the first run after the move is
  cold and fetches the SQL Server Express media and the NuGet packages again.
- A failing `-Pdf required` now leaves no partial pack, so the upload step after it finds
  nothing: `warmup-eshop.yml` (`if-no-files-found: error`) reports a second error, the other
  two workflows ignore it.

## The rule for the next move

1. A pin moves because a ticket needs something in the new commit, and the record says what.
   One pull request: `pins.json`, every place that quotes a pin as the current setup (found
   with `git grep` on the old ids) and the next record. `results/` keeps the pins it ran on.
2. Name the new commit in full; check after a fetch that it is an ancestor of the tool's
   `origin/main`.
3. Read `git log --no-merges <old>..<new>` in each repository: read the diff of every commit
   that touches code and say what the bench can notice of it; count the documentation and
   dependency commits. Check the bench against it: `sk validate` on every contract and
   configuration, the scripts' option names, exit codes, and the text and lines they parse.
4. Before merging: `legacy-build` A/A `pass`, every clause held, no regression; the warm-up as
   before; `mutants` dispatched on the branch, M00 `pass`, every mutant killed. A number that
   differs from the one before is explained in the record.
