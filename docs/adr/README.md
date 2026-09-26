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
