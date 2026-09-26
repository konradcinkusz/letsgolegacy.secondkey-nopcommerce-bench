# ADR 0001 — Pin nopCommerce `release-3.90`, fetched at build time, never vendored

- **Status:** accepted (P1)
- **Date:** 2026-09-26
- **Deciders:** implementation agent for P1; to be confirmed by the owner in review

## Context

The bench needs a real legacy shop: classic ASP.NET on .NET Framework, SQL Server, and
business rules with teeth (discounts, taxes, shipping) so that "must" and "never" rules
in the P5 contract mean something. The work plan fixes the product (nopCommerce) and the
major version (3.x); the exact release was open.

Upstream tags every 3.x release (`git ls-remote --tags https://github.com/nopSolutions/nopCommerce`):
`release-3.00` … `release-3.80`, `release-3.90`, plus two betas. The next major,
4.00, moved to ASP.NET Core, which would defeat the purpose — the migration we want to
observe is System.Web to modern .NET.

## Decision

Pin **`release-3.90`**:

| | |
|---|---|
| Tag | `release-3.90` (annotated tag object `5846b2b59b102270e15d7eb8415298ae989a1abf`, tagged 2017-03-15) |
| Commit | `12d1f0139149a9d6e84964d325d62bae6ac748f6` |
| Stack | ASP.NET MVC 5.2.3, Entity Framework 6.1.3, Autofac 4, .NET Framework 4.5.1, SQL Server (or SQL CE) |
| Size | 5,397 tracked files; 94 MiB packed, 338 MB checked out (upstream commits its `packages/` folder) |

The pin lives in one place, [`pins.json`](../../pins.json). `scripts/1-fetch-nopcommerce.ps1`
enforces it twice on every run: the upstream tag must still resolve to the pinned commit
(a moved tag fails the run instead of silently building something else), and the
checked-out tree must be exactly that commit with no tracked file modified. Step 2
repeats the second check before and after building, so the published site is provably a
build of unmodified upstream source.

### Why 3.90 and not an earlier 3.x

- It is the **last** release on classic ASP.NET MVC, so it carries every 3.x fix and the
  most complete business surface: discount requirement rules, tax providers by
  country/state/zip, several shipping rate providers, multi-store, vendors, gift cards,
  reward points, checkout attributes. More rules to contract, more ways to regress.
- Its toolchain (Visual Studio 2015 projects, `packages.config`) is the youngest of the
  3.x line, which is the shortest distance to building on current runner images.
- Nothing in an earlier 3.x would make the demo stronger; they only add age.

### Why fetched, not vendored

- **Licence.** nopCommerce 3.90 is under the nopCommerce Public License 3.0 (GPLv3 plus
  a "powered by nopCommerce" attribution requirement). This repository is all rights
  reserved. Keeping upstream code out of the tree keeps the two sets of terms apart.
- **Size and noise.** 338 MB and 5,000 files of someone else's code would swamp the bench's
  own history and every review diff.

## Consequences

- CI needs network access to github.com at build time; the fetch retries transient
  failures and takes seconds on a hosted runner.
- The `legacy-site` workflow artifact is a build of unmodified upstream source. Its
  manifest (`state/build.json`) names the upstream repository and commit, which is where
  its source is published. The "powered by nopCommerce" footer is untouched. The
  artifact is kept for 7 days, long enough for the jobs that consume it.
- Changing the pin is a decision, not a chore: a new ADR, and the smoke test and the
  traffic set (P4) re-run against the new release.
- The sample data shipped with 3.90 is dated: the "20% order total" discount expired on
  2020-01-01. That is behaviour to record and contract (P4, P5), not a defect to patch.
