# Architecture decision records

One file per decision: the context, the decision, the alternatives that lost and why, and
the consequences. A decision is changed by a new record that supersedes the old one, not
by editing history.

| ADR | Decision | Ticket |
|---|---|---|
| [0001](0001-pin-nopcommerce-3.90.md) | Pin nopCommerce `release-3.90` by tag and commit; fetch at build time, never vendor | P1 |
| [0002](0002-build-on-windows-2022-with-packaged-reference-assemblies.md) | Build on `windows-2022` with the .NET Framework 4.5.1 reference assemblies from NuGet | P1 |
