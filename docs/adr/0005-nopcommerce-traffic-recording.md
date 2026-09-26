# ADR 0005 — Recording the nopCommerce traffic set: configured through the admin UI, every scenario from one snapshot, probes in the query

- **Status:** accepted (P4)
- **Date:** 2026-09-26
- **Deciders:** implementation agent for P4; to be confirmed by the owner in review

## Context

P4 records the traffic set of [`P4-TRAFFIC-PLAN.md`](../P4-TRAFFIC-PLAN.md) — 30 planned
scenarios over catalog, cart, discounts, taxes, shipping and checkout — through
`sk capture` in front of the P2 shop. It is done when the scenario count is recorded.
The recording is the input of everything after it: P5 writes the contract against it and
replays it A/A, P7 replays it against the candidate. Four things had to be decided, and
all four shape what P5 and P7 can do.

## Decisions

### 1. The store is configured through its own admin UI, before recording, and read back

The sample data switches off what the set is about (no tax rate, no shipping rate, inert
coupons; plan §2). [`6-configure-store.ps1`](../../scripts/6-configure-store.ps1) signs in
as the administrator step 4 created and uses the admin pages and AJAX endpoints a person
clicks through — never SQL — so every row nopCommerce writes is the row it would write,
caches and events included. Every change is read back, and a settings or product form
posted back is re-read and compared field by field.

The administrator's requests go straight to the site, never through the recording proxy:
configuration is not traffic, and the administrator's password must not reach a
recording.

### 2. Every scenario starts from one database snapshot — when recording too

After step 6, [`7-record-traffic.ps1`](../../scripts/7-record-traffic.ps1) takes a SQL
Server database snapshot and restores it before each scenario, exactly as `sk replay`'s
`sqlServerSnapshot` reset does before each scenario on each side. So:

- the recording and every replay start each scenario from the same rows, identities
  included — the order a scenario places gets the same number every time;
- scenarios are independent of each other and of their order, and any one can be
  recorded alone (`-Only`);
- a story with two people in it cannot rely on the first person's order existing in the
  second person's session. The plan's T30 therefore uses a sample order that belongs to
  someone else (plan §4a).

The restore closes every connection to the database, the shop's pooled ones included.
Step 7 sends one request straight to the site after each restore, before the scenario,
and records how it was answered: that is the evidence of whether a replay can restore
and go.

It also means nothing may use the database on its own schedule. nopCommerce 3.90 runs
its schedule tasks on timers inside the web application, and a task reads its row before
its `try` (`Task.Execute`); under a restore that read throws on a timer thread and takes
the worker process down. The first full recording hit it once — the shop answered 500
until it had restarted. Step 6 therefore disables every schedule task and restarts the
application through the admin's "Restart application", and waits for the "Application
started" entry in the shop's log. None of the four tasks the sample install enables —
sending queued e-mails, pinging the site, deleting guests, updating exchange rates — is
part of what the traffic set exercises.

### 3. A request the contract asserts a scenario-specific fact on carries `probe=<name>`

The contract language scopes a clause by method, path and query; it cannot see request
headers or form fields. Many of the plan's rules are facts about one scenario's answer
at a URL every scenario uses — the cart after `SAVE10` (`POST /cart`), the estimate for
a $1,000.00 cart (`POST /cart/estimateshipping`). Such requests carry an extra query
parameter, `probe=<scenario or step>`, which nopCommerce ignores on those routes and the
contract can select on.

The alternative — one clause per URL, asserting what all scenarios have in common —
would reduce most rules to "answers 200". Changing the request is acceptable because the
probe is part of the recording: legacy and candidate receive the same bytes.

### 4. A scenario that fails does not stop the recording

Each scenario checks what it needs along the way (`Invoke-BenchStep`, `Assert-NopTotal`):
a scenario that never reached what it exercises is not evidence. Step 7 runs every
scenario even after one fails, prints nopCommerce's own log for the failed one before the
next restore erases it, and fails at the end, listing every failed scenario. Step 6 does
the same per area (tax, catalog, shipping, discounts). One run shows every problem.

## Consequences

- The traffic set is 38 sessions for the 30 planned scenarios (plan §4a).
- P5's replay configuration names the same snapshot and database for its
  `sqlServerSnapshot` reset.
- The `*.skcap` holds sample-shop data only: the sample customer's published password,
  the password R1 registers with, test card numbers. Cookies are redacted by `sk capture`
  by default.
