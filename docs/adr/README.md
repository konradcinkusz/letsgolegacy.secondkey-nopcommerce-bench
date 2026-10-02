# Architecture decision records

One file per decision: the context, the decision, the alternatives that lost and why, and
the consequences. A decision is changed by a new record that supersedes the old one, not
by editing history.

| ADR | Decision | Ticket |
|---|---|---|
| [0001](0001-pin-nopcommerce-3.90.md) | Pin nopCommerce `release-3.90` by tag and commit; fetch at build time, never vendor | P1 |
| [0002](0002-build-on-windows-2022-with-packaged-reference-assemblies.md) | Build on `windows-2022` with the .NET Framework 4.5.1 reference assemblies from NuGet | P1 |
| [0003](0003-legacy-host-iis-sqlexpress-unattended-install.md) | Legacy host: IIS through DISM, SQL Server 2022 Express with Windows authentication, nopCommerce's installer driven over HTTP | P2 |
| [0004](0004-chain-tools-and-eshop-warmup.md) | The chain's tools (sk, Portcullis) built from pinned commits; one scenario is one session, named by a request header; the P3 warm-up on eShopLegacyMVC's mock data | P3 |
| [0005](0005-nopcommerce-traffic-recording.md) | The nopCommerce traffic set: store configured through the admin UI and read back; every scenario from one database snapshot, when recording too; `probe=<name>` on requests the contract asserts on; a failed scenario does not stop the recording | P4 |
| [0006](0006-nopcommerce-contract-and-aa-proof.md) | The nopCommerce contract pins legacy behaviour as it is; it is proven by an A/A replay on one shop and one database, restored before every scenario; the only normalization masks what the request and the snapshot do not fix: a PDF's bytes, an anti-forgery token, a cart line's cached picture | P5 |
| [0007](0007-p9-mutants-on-a-second-site.md) | Killed mutants without `sk mutate`: hand-written patches, pre-registered with the clauses expected to catch them; built by step 2 with `-Patch`; each run as a second IIS site on the legacy database, reset from the same snapshot; M00, the unpatched build, must pass or a run counts nothing | P9 |
