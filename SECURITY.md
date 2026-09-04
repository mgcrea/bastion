# Security

Bastion runs other people's MCP servers with your credentials, so a hole in it is a hole in
everything wired to it. Reports are welcome and answered.

## Reporting

Email **security@mgcrea.io**. Do not open a public issue for something exploitable: the app
auto-updates through Sparkle, and a fix reaches every user faster than a thread does.

Include the version (`Bastion > About`, or `CFBundleShortVersionString` in the bundle), what you
did, and what you expected to be refused. A proof of concept against your own machine is ideal;
one against somebody else's is not needed and not wanted.

## What counts

The properties the app claims, and the checks that assert them, are in
[README.md](README.md#security) and [docs/keychain.md](docs/keychain.md). In short:

- The gateway binds `127.0.0.1` only, refuses a foreign `Host` or `Origin` before looking at any
  token, and never lets anything arriving over the wire name a package, a path or a command line.
- Credentials live in the Keychain and are handed to a child as environment, never written to a
  client config, never returned by a tool, and redacted from the log and the audit file.
- A profile's write gate is set unconditionally in both directions on every spawn. Where a server
  has no variable to set — a remote endpoint, or a child whose own read-only switch is a
  command-line flag — the gate is the tool filter instead, and the gated tools are absent from
  `tools/list` and refused on `tools/call`.

Anything that breaks one of those is in scope. So is the licence Worker at `api.bastion.mgcrea.io`
(`apps/api/`) and the website.

## Not in scope

- A supervised server misbehaving with the credential it was legitimately given. Bastion fronts
  the server; the credential's own scopes are the boundary, and the catalog says so per entry.
- What a catalog server's own code does. Eleven of the catalog's twenty-two child entries name a
  package somebody else publishes; Bastion installs those from npm on demand and runs them with the
  Node runtime in the app, with a profile's credentials in their environment. What Bastion adds is
  the supervision, the Keychain and the audit line — not a review of the code, and the app says so
  on each of those entries. A vulnerability in one of them belongs to its own maintainers.
- Anything that needs the attacker to already run code as your user with your Keychain unlocked.

## Supported versions

The current `1.x` release on the appcast. Fixes ship as point releases; there are no backports.
