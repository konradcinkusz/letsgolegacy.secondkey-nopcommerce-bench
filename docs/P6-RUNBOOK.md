# P6 runbook — run modernize-dotnet on nopCommerce 3.90

P6 is human work: a person with a GitHub Copilot subscription runs Microsoft's
modernization agent (GitHub Copilot app modernization for .NET, "modernize-dotnet") on
the pinned nopCommerce and hands its result to the bench. This runbook makes that
mechanical: where the code goes, which standards the agent gets, what to type, what to
write down, and what P7 and P8 need back.

- **Done when (docs/WORKPLAN.md):** the candidate builds and the existing tests pass.
- **Input:** nopCommerce `release-3.90` at `12d1f0139149a9d6e84964d325d62bae6ac748f6`
  (as pinned in [`pins.json`](../pins.json)), and the standards skill produced by R4 in
  `konradcinkusz/letsgolegacy.secondkey-standards`.
- **Output:** a pull request in a fork of nopCommerce whose head commit is the
  candidate, a run record, and hours in [`P10-ONBOARDING-HOURS.md`](P10-ONBOARDING-HOURS.md).

**Contents**

1. [Before you start](#1-before-you-start)
2. [Prepare the fork and the branches](#2-prepare-the-fork-and-the-branches)
3. [Give the agent the standards](#3-give-the-agent-the-standards)
4. [Take the legacy test baseline](#4-take-the-legacy-test-baseline)
5. [Run the agent](#5-run-the-agent)
6. [Build and test the candidate](#6-build-and-test-the-candidate)
7. [Open the candidate pull request](#7-open-the-candidate-pull-request)
8. [Record the run](#8-record-the-run)
9. [How the candidate feeds P7 and P8](#9-how-the-candidate-feeds-p7-and-p8)
10. [Failure modes](#10-failure-modes)
11. [Checklist](#11-checklist)

---

## 1. Before you start

| Need | Why |
|---|---|
| GitHub Copilot (Pro, Business or Enterprise) with agent mode | The agent runs inside Copilot |
| One client with the modernization agent: **Visual Studio 2026** (or 2022 17.14+) with *GitHub Copilot app modernization*, **VS Code** with the *GitHub Copilot app modernization* extension, or **GitHub Copilot CLI** | The three entry points the tool ships in; any one is enough. This runbook's commands are the same for all three; only step 5.2 differs |
| Windows with Visual Studio's MSBuild for .NET Framework, the .NET 10 SDK, git and the GitHub CLI (`gh`) | The legacy baseline builds with MSBuild (step 4); the candidate with `dotnet` |
| Write access to `konradcinkusz/letsgolegacy.secondkey-nopcommerce-bench` | To commit the run record |
| **R4 done**: a tagged release of the standards repository with `generated/skills/` | The skill the agent must use; P6 does not start without it |

Start a stopwatch now and note the time in the record (§8). Everything from here to
the opened pull request counts as P6 hours; the bench's own CI time does not.

## 2. Prepare the fork and the branches

The candidate is a modified nopCommerce, so it lives where nopCommerce's licence already
applies — a fork of the upstream repository — and never in this bench repository.

```sh
# 2.1 Fork upstream once, into the account that owns the bench (public, as upstream is).
gh repo fork nopSolutions/nopCommerce --clone=false

# 2.2 Take the pinned commit from upstream, shallow, with upstream's exact bytes.
git init nop-p6 && cd nop-p6
git config core.autocrlf false
git remote add upstream https://github.com/nopSolutions/nopCommerce.git
git remote add fork https://github.com/<your-account>/nopCommerce.git
git fetch --depth 1 upstream tag release-3.90
git rev-parse "release-3.90^{commit}"          # must print 12d1f0139149a9d6e84964d325d62bae6ac748f6
git checkout -b secondkey/p6-base 12d1f0139149a9d6e84964d325d62bae6ac748f6
```

If `rev-parse` prints anything else, stop: the tag moved upstream (the bench's
[`1-fetch-nopcommerce.ps1`](../scripts/1-fetch-nopcommerce.ps1) would refuse it too).

Branches in the fork:

| Branch | Contents | Changes after P6 starts? |
|---|---|---|
| `secondkey/p6-base` | the pinned commit plus one commit adding the standards skill (§3) | never |
| `secondkey/p6-candidate` | created from `secondkey/p6-base`; everything the agent (and you) change | yes, during P6 only |

The pull request goes from `secondkey/p6-candidate` into `secondkey/p6-base`, so its diff
is exactly the migration: the agent's changes and any human edits, nothing else.

## 3. Give the agent the standards

```sh
# 3.1 Get the standards at the R4 release tag (write the tag into the record).
git clone --depth 1 --branch <standards-tag> https://github.com/konradcinkusz/letsgolegacy.secondkey-standards.git ../standards

# 3.2 Copy every generated skill into the target's .github/skills/.
mkdir -p .github/skills
cp -R ../standards/generated/skills/. .github/skills/
git -C ../standards rev-parse HEAD             # the standards commit, for the record

# 3.3 Commit it alone, on the base branch.
git add .github/skills
git commit -m "Add Second Key standards skills (<standards-tag>, <standards-commit>)"
git push -u fork secondkey/p6-base
git checkout -b secondkey/p6-candidate
git push -u fork secondkey/p6-candidate
```

Each skill is a folder with a `SKILL.md`; Copilot discovers skills under `.github/skills/`
in the open repository. Do not edit them here — a change to a standard is an R4 change.

## 4. Take the legacy test baseline

"The existing tests pass" needs a baseline: which of nopCommerce's own tests pass on the
unmodified code. nopCommerce 3.90 has five NUnit 3 test projects under `src/Tests`
(`Nop.Core.Tests`, `Nop.Data.Tests`, `Nop.Services.Tests`, `Nop.Web.MVC.Tests`,
`Nop.Tests`).

The legacy tree is the one the bench already builds, so use the bench's own steps, from
a clone of the bench repository:

```powershell
.\scripts\1-fetch-nopcommerce.ps1     # C:\nopbench\legacy-src, verified at 12d1f01
.\scripts\2-build-legacy.ps1          # builds every project, the test projects included
nuget install NUnit.ConsoleRunner -Version 3.22.0 -OutputDirectory C:\nopbench\tools
$runner = 'C:\nopbench\tools\NUnit.ConsoleRunner.3.22.0\tools\nunit3-console.exe'
& $runner (Get-ChildItem C:\nopbench\legacy-src\src\Tests\*\bin\Release\*.Tests.dll).FullName --result=C:\nopbench\p6-legacy-tests.xml
```

Record total, passed, failed and skipped per assembly. A test that fails on legacy is
not a regression when it fails on the candidate; a test that passes on legacy and fails
on the candidate is.

## 5. Run the agent

### 5.1 Open the candidate branch

Open `nop-p6` on branch `secondkey/p6-candidate` in the client you chose, signed in to
GitHub Copilot. Confirm the agent sees the standards: ask it, before anything else,

> List the skills you have loaded from this repository.

and paste its answer into the record. If the Second Key skills are missing, stop and fix
§3 (R4's acceptance is exactly this: the agent picks the skill up).

### 5.2 Start the modernization

| Client | Entry point |
|---|---|
| Visual Studio | Open `src\NopCommerce.sln`; start **GitHub Copilot app modernization** (Solution Explorer context menu on the solution, or Copilot Chat in agent mode with the modernization agent selected) |
| VS Code | Open the folder; Copilot Chat in **Agent** mode, select the app modernization agent |
| Copilot CLI | `copilot` in the repository root, with the app modernization agent enabled |

Menu names move between releases; use the tool's current documentation for *where* to
click, and this runbook for *what* to give it. Then send, verbatim:

> Modernize the solution in src/NopCommerce.sln from .NET Framework 4.5.1 to .NET 10.
> Migrate the ASP.NET MVC 5 web application (Nop.Web, the Administration area and the
> plugins) to ASP.NET Core on .NET 10. Keep the SQL Server database schema, the public
> URLs and the observable behaviour of the storefront unchanged. Keep the existing unit
> test projects and make them build and run on .NET 10. Follow the standards in
> .github/skills. Commit your work on the current branch in logical steps.

Every follow-up prompt, every answer that asked you to choose, and every choice you made
goes into the record verbatim, in order. Let the agent commit its own work; do not
squash.

### 5.3 When you have to intervene

If you must change code yourself (the agent is stuck, or asks you to), make it a
separate commit whose message starts with `human:` and says why. The evidence pack
distinguishes the agent's changes from a person's by that prefix.

## 6. Build and test the candidate

```powershell
dotnet --version                                   # record it
dotnet build src\NopCommerce.sln -c Release        # must succeed
dotnet test  src\NopCommerce.sln -c Release --logger "trx;LogFileName=p6-candidate-tests.trx"
```

P6 is done when the build succeeds and every test that passed in the legacy baseline (§4)
passes. Record the counts next to the baseline's. If the agent removed, skipped or
emptied a test that passed on legacy, it does not count as passing: say so in the record.

## 7. Open the candidate pull request

```sh
git push fork secondkey/p6-candidate
gh pr create --repo <your-account>/nopCommerce --base secondkey/p6-base --head secondkey/p6-candidate \
  --title "P6: modernize-dotnet candidate - nopCommerce 3.90 to .NET 10" \
  --body-file p6-record.md
git rev-parse HEAD                                  # the candidate commit
```

Do not merge it. Its head commit is the candidate; later commits make a new candidate.

## 8. Record the run

Write `p6-record.md` (the pull request body), then add the same file to this bench
repository as `results/p6/run-record.md` in a pull request, and add your hours to
[`P10-ONBOARDING-HOURS.md`](P10-ONBOARDING-HOURS.md).

```markdown
# P6 run record

| | |
|---|---|
| Operator | <name> |
| Started / finished (UTC) | <yyyy-mm-dd hh:mm> / <yyyy-mm-dd hh:mm> |
| Hours (hands-on / waiting on the agent) | <h> / <h> |
| Client and version | <Visual Studio 2026 18.x / VS Code x.y + extension a.b / Copilot CLI x.y> |
| Modernization agent version | <as shown by the client> |
| Model | <model selected in Copilot> |
| .NET SDK | <dotnet --version> |
| Legacy commit | 12d1f0139149a9d6e84964d325d62bae6ac748f6 |
| Standards | <standards-tag> at <standards-commit> |
| Skills the agent listed | <paste> |
| Candidate PR / head commit | <url> / <sha> |
| Legacy tests (total / passed / failed / skipped) | <n / n / n / n> |
| Candidate tests (total / passed / failed / skipped) | <n / n / n / n> |
| Tests passing on legacy but not on the candidate | <none, or list> |
| Human commits | <none, or list with reasons> |

## Prompts and answers

1. <prompt, verbatim>
   - Agent: <summary of the answer, or the question it asked>
   - Choice: <what you answered>

## Notes

<anything surprising: files the agent deleted, packages it replaced, warnings it ignored>
```

## 9. How the candidate feeds P7 and P8

| Ticket | Takes | Does |
|---|---|---|
| P7 | the candidate PR's head commit | Pins it in the bench, builds it, deploys it on the Windows host next to the legacy site (`http://localhost:8090/`, its own database restored from the same snapshot, [`TOPOLOGY.md`](TOPOLOGY.md)), replays the P4 recording against both and compares: `verdict.json` |
| P8 | the candidate pull request | Runs the Portcullis migration rules on the lines the PR changes: SARIF, attached to the evidence pack |
| P9 | both | Publishes the pack, which cites the PR, its head commit, the standards version and this record |

A new push to `secondkey/p6-candidate` after P7 has started is a new candidate: P7 and
P8 run again on the new head commit, and the record says so.

## 10. Failure modes

| Symptom | Cause |
|---|---|
| The agent never mentions the Second Key standards | `.github/skills/` is not in the opened folder, or the client version does not load repository skills: §5.1 catches it before any code changes |
| The PR diff contains thousands of unrelated lines | The branches were not created from the pinned commit, or line endings were converted (`core.autocrlf`) |
| "Tests pass" but fewer tests ran | The agent excluded, skipped or deleted test projects; compare counts with the §4 baseline |
| P7 cannot reproduce the build | The candidate depends on something only on the operator's machine (a local NuGet source, an SDK preview); record the SDK and every source |
| The candidate moved while P7 was running | Someone pushed to the candidate branch: P7 pins a commit, never a branch |
| `git push` refuses with "shallow update not allowed" | The fork was created with "copy the default branch only", so it lacks the pinned commit's history: fetch the tag without `--depth`, or re-create the fork with `gh repo fork` defaults |

## 11. Checklist

- [ ] Fork created; `secondkey/p6-base` is the pinned commit plus the skills commit, nothing else
- [ ] Skills copied from a tagged standards release; the tag and commit are in the record
- [ ] Legacy test baseline taken (counts per assembly)
- [ ] The agent listed the Second Key skills before changing anything
- [ ] Every prompt, question and choice recorded verbatim; human edits are separate `human:` commits
- [ ] `dotnet build` succeeds; every test that passed on legacy passes on the candidate
- [ ] Pull request opened into `secondkey/p6-base`, not merged; its head commit recorded
- [ ] Record committed to the bench as `results/p6/run-record.md`; hours added to the P10 log

Worked examples: none yet — this runbook is written before the first P6 run. The first
run's record becomes the example.
