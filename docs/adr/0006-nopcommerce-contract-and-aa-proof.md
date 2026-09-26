# ADR 0006 — The nopCommerce contract: legacy behaviour pinned as it is, proven by an A/A replay on one database

- **Status:** accepted (P5)
- **Date:** 2026-09-26
- **Deciders:** implementation agent for P5; to be confirmed by the owner in review

## Context

P5 turns section 5 of the [traffic plan](../P4-TRAFFIC-PLAN.md) into a Second Key
contract. It is done when the contract validates and passes on the legacy system. There
is no candidate yet (P6), so "passes on the legacy system" has to be shown with the
legacy shop alone, and the contract has to be written so that P7 can hold the migrated
shop to it.

## Decisions

### 1. Proof by an A/A replay, both sides on one shop and one database

[`8-replay.ps1`](../../scripts/8-replay.ps1) replays the P4 recording with `sk replay`,
legacy and candidate both `http://localhost:8080/`, each side restored to the recording's
snapshot before each scenario (`sqlServerSnapshot` in
[`contract/secondkey.yaml`](../../contract/secondkey.yaml)). `sk replay` finishes a
scenario on one side before it resets the other, so one database serves both. The run
goes to Linux, where [`9-verdict.ps1`](../../scripts/9-verdict.ps1) requires `sk compare`
to answer `pass` with every accepted clause held and none unexercised — every clause is
checked twice, once per side, on answers the legacy shop really gave.

A contract that fails A/A is wrong about the legacy system, or the replay is not
repeatable; either would make a P7 verdict meaningless, which is why this is the gate.

### 2. Legacy behaviour is pinned as it is, not as it should be

Discounts are written `($100.00)` on .NET Framework 4.8; a guest gets an empty coupon
message for `MEMBERS15`; free shipping leaves the $1.99 pickup fee; `SAVE10`+U+180E is
refused. The contract asserts each of these exactly. A candidate that changes one fails a
clause, and a person decides whether that is a regression or a fix — the difference is
never absorbed by a normalization rule.

### 3. Three normalization rules, each for a value the request and the snapshot do not fix

A PDF invoice carries its creation time and a random document id, so two renderings never
match: `masks.patterns.pdf-bytes` masks base64 bodies that start with `%PDF-`. An
anti-forgery token is a fresh random value in every form MVC renders, and the one-page
checkout's confirm step sends one inside its JSON answer (the order summary in
`update_section.html`): `masks.patterns.anti-forgery-token` masks the token's value. A
cart line's picture is cached for three minutes by shopping-cart-item id, and a restore
hands every scenario's first cart line the same id, so a line can show the picture of
another scenario's product — the first A/A run showed a Lenovo line pictured as the $25
gift card on one side and not on the other: `masks.patterns.cart-line-picture` masks the
picture's URL, alt text and link title in the JSON answers that carry cart lines. That
cache is state the database restore does not reset. Clearing it before every scenario
would reset it too, but only through the admin UI or a restart of the application, for
every scenario on both sides — P7's candidate included — so the contract masks the three
values instead, and says so.

Everything else must be equal: from one snapshot and the same requests the legacy shop
answers the same twice, order numbers included. A difference nothing explains is a
regression, so the A/A pass also shows that these three masks are all the comparison
needs.

### 4. Titles say exactly what the assertions check

"Billed to US / New York / 10001, the $500.00 Lenovo with Ground shows tax 45.00 (9%)",
not "tax is correct". The verdict and the pack print titles; a reader must be able to
tell what held without opening the YAML.

## Consequences

- 76 clauses, 15 `never` (absence share 19.7%), 32 extractors
  ([`contract/README.md`](../../contract/README.md) maps them to the plan's rules).
- P7 replays the same recording against the candidate with `-Candidate`, the same reset
  and the same contract; a clause that held here and fails there is a regression by
  construction.
