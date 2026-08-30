# Bastion

**One MCP server, running once, for every client on the machine.**

A macOS menu bar app that supervises your MCP servers instead of letting each editor spawn its own:
one process per server, credentials in the Keychain, and every tool call recorded.

> **Early, and this file says so throughout.** Steps 1–3 of the build order are done and the gateway
> serves a real server end to end. There is no profile editor, no Activity window, no bridge, and no
> signed or notarized build — the app is code-signed for development only. [Status](#status) lists
> exactly what runs today. Everything described below is built unless it is under "Not built yet".

## The problem

Every MCP client spawns its own copy of every stdio server. Open three projects in Claude Code and
you have three `mcp-shopify` processes, three credential sets in three environments, no logs, and no
way to see what tool was called with what argument. Nothing is auditable and nothing is shared.

The credentials are the sharp end. Right now `mcp-shopify`, `mcp-keycloak`, `mcp-tastytrade` and
`mcp-appstore-connect` each keep a `.mcp.json` holding real secrets in plaintext — readable by
anything running as you, and one careless `git add` from being published. A brokerage refresh token
sits in a file beside the code.

Bastion runs each server once, holds its credentials in the Keychain, and fronts it over loopback
HTTP so several clients share one instance.

## How it works

Each client points at a URL instead of a command:

```
http://127.0.0.1:8720/s/<profile>/<server>
```

A **profile** is a named credential and configuration set — `prod/shopify`, `staging/shopify`,
`rgis/keycloak`. It is the answer to the obvious objection to a shared gateway: one global instance
is one identity, and one identity is unusable. Every repo in `mgcrea-ai` already carries different
credentials for the same server, so a true singleton would be unusable for its own author on day
one.

Bastion speaks HTTP to the clients and stdio to the child. The MCP handshake happens **once**, at
spawn — every client's `initialize` is answered from that one result, and each client's request ids
are rewritten into the supervisor's own numbering and back again, so two clients using id `1` at the
same time cannot receive each other's answers.

### One process, N clients

This inverts cupertino's design, which maps one connection to one process on purpose. Three reasons
are given there for that choice, and each one has to be answered rather than waved at:

| Cupertino's reason    | Bastion's answer                                                                                                                                                      |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **state**             | The handshake happens once, at spawn, and is replayed to every client. The 2026-07-28 spec went stateless-first, which is what makes this correct rather than a hack. |
| **crashes**           | Backoff, a circuit breaker, and the blast radius said out loud: when a child dies every client waiting on it is told, with a count.                                   |
| **write permissions** | Per **profile**, not per process. `tastytrade/cert` with trading on beside `tastytrade/prod` with trading off is expressible; a process boundary never made it so.    |

What is genuinely given up is isolation between two clients of the _same_ profile. That is the
trade, and it is the right one: they are the same identity with the same permissions, which is
exactly the case where a second process bought nothing but memory.

## Servers

Ten, listed in [`servers.json`](servers.json) and documented in [docs/servers.md](docs/servers.md).
Three are read-only; seven have a write gate that is off until a profile turns it on.

The list is **closed**, and that is a security property rather than a missing feature. The child
inherits the user's credentials and runs unsandboxed, so "run whatever the config names" is the same
shape of hole as CVE-2025-49596. The catalog problem is solved and free elsewhere — Docker MCP
Toolkit ships hundreds of curated servers, Anthropic ships MCPB double-click install and an official
registry. The part worth building is the runtime underneath.

Adding one is an entry in the manifest and `make servers`; every generated copy is checked in CI.

## What the audit log sees, and what it does not

Bastion sees the JSON-RPC frames crossing the gateway: which profile, which method, which tool, how
long, and what came back. It records method names and the name of whatever a request reached for —
never arguments, never results.

It does **not** see what a server then does over the network or on the filesystem. A server that
reads a file it was never asked about does so out of Bastion's sight. This is a record of requests,
not a sandbox, and the website has to say so in these words too.

## Security

A loopback daemon holding every credential you own is the exact shape of CVE-2025-49596 — Anthropic's
own MCP Inspector, where a listener plus no CSRF protection meant a page you visited could reach it
and execute code — plus the rust-sdk and FastMCP DNS-rebinding advisories, whose root cause was "no
rebinding protection by default, because it is only localhost".

Five rules, in the first commit that opened a socket rather than a hardening pass afterwards:

1. Bind `127.0.0.1` explicitly. Never `0.0.0.0`, and not configurable.
2. Validate `Origin` on every request.
3. Validate `Host` on every request — this is the anti-rebinding rule.
4. A per-client bearer token, minted at wiring time, kept in the Keychain.
5. Secrets never written to any config file. The **token** goes in the client config; the
   **credential** stays in the Keychain. What leaks if a `.mcp.json` leaks is a revocable loopback
   token instead of a Shopify secret.

The order of 2, 3 and 4 is load-bearing: a rebinding attempt must be refused with 403 whether or not
it also guessed a token, or the 401 tells an attacker their `Host` was accepted.

```bash
make audit
```

[`scripts/audit-listener.sh`](scripts/audit-listener.sh) launches the built bundle and asserts all of
it: loopback-only via `lsof`, a foreign `Origin` and a rebound `Host` both refused, the refusal
order, unauthenticated and wrong-token requests refused, and that `profiles.json` holds no value for
any variable the manifest marks secret. It replaces cupertino's `audit-network.sh`, whose claim — no
network at all — Bastion cannot make. The property worth keeping was "a claim CI can check", not the
particular claim.

The app ships with **no entitlements file at all**. Spawning children and binding loopback need
none, and with the sandbox off `com.apple.security.network.server` is unnecessary. An empty
permission set that is true by construction is checkable; one arrived at by deletion is not, so the
audit asserts the setting is absent rather than empty.

## Status

Built and verified:

|                      |                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------- |
| **Gateway**          | loopback HTTP, `Origin` / `Host` / bearer, hand-written so the checks are auditable |
| **Supervisor**       | one child per profile, id remapping, backoff, circuit breaker, idle stop            |
| **Dialect**          | dual-era: modern 2026-07-28 and legacy `initialize`, onto legacy children           |
| **Manifest**         | ten servers, a generator, and a CI drift check                                      |
| **Keychain**         | per-profile credentials, per-client tokens                                          |
| **Activity window**  | what is running, who is attached, and every tool call, live                         |
| **`bastion-bridge`** | stdio hosts reach the gateway over HTTP; starts Bastion if it is not up             |
| **Migration**        | four `.mcp.json` credential sets moved into the Keychain, configs repointed         |
| **`make smoke`**     | four concurrent clients, colliding ids, exactly one child, `kill -9` recovery       |
| **`make audit`**     | the five security rules, against the real bundle                                    |
| **`make dialect`**   | 24 conformance checks across both eras                                              |

Bastion is what the 2026-07-28 spec calls a **dual-era server**. A modern client declares its
protocol version, identity and capabilities in each request's `_meta` and needs no handshake at
all; a legacy client opens with `initialize` and is served that way. Both land on the one handshake
Bastion took with the child at spawn, and `server/discover` — mandatory in the modern revision, and
implemented by none of these servers — is synthesised from it.

None of the ten servers are modern. Every one runs an SDK whose newest protocol is `2025-11-25`,
which is what they negotiate. The manifest said `2025-06-18` until a live handshake was actually
run against one; that was Bastion's own pin masquerading as a fact about the servers.

Not built yet, in build order: client wiring and the signed release path.

Five limitations worth knowing now:

- **Bastion has no login item yet.** A stdio client's bridge starts it on demand, so a Claude
  Desktop entry works from cold. A client configured with a plain `type: http` URL has no such
  path and needs Bastion already up — which is the case for the four repos below.
- **The repointed repos need Bastion running.** `mgcrea-ai/mcp-{shopify,keycloak,tastytrade,appstore-connect}/.mcp.json`
  now call `http://127.0.0.1:8720/...` instead of spawning anything, so with Bastion stopped those
  four servers are simply unreachable. There is no login item yet; that lands with the release path.

- **Server-initiated requests are refused, not routed.** Sampling, elicitation and roots get a
  JSON-RPC error explaining why: a shared instance has no single client to ask, and picking one
  would hand one project's agent a prompt raised on behalf of another's. The 2026-07-28 spec
  replaces all three with Multi Round-Trip Requests and puts them on a ~12-month offramp. No server
  in the manifest uses any of the three, so the full MRTR resume path is unbuilt rather than
  broken: building it would mean untestable code for a case the closed manifest makes impossible.
- **Responses are a single JSON object, never an SSE stream.** That means no
  `notifications/progress` on a long call and no `subscriptions/listen`. Both are optional in the
  spec, and both are real gaps.
- **`Mcp-Param-*` headers are forwarded but not validated.** Doing it needs a cached per-profile
  tool list to read `x-mcp-header` annotations from. No server in the manifest annotates a
  parameter, so it cannot currently be reached.

## Working on it

Requires macOS 26.0 and Xcode 26. The Swift half is `xcodebuild`, named by the Makefile rather than
wrapped by it.

```bash
make app            # build Bastion.app (Debug)
make run            # build and launch the menu bar agent
make stop           # quit it
make audit          # assert the listener is loopback-only and refuses foreign Origin/Host
make dialect        # assert both protocol eras against a running build
make smoke          # prove one supervised server end to end
```

The manifest and the JavaScript half:

```bash
make servers        # regenerate every copy of the server list from servers.json
make servers-check  # fail if any generated copy has drifted
make lint
make format
```

A Debug build carries its own bundle identifier, `io.mgcrea.bastion.debug`. That is not cosmetic:
Keychain items are scoped by app identity, so a shared identifier means a debug build reads,
overwrites and deletes the credentials the real app is holding.

### Running a server before there is a profile editor

There is no UI for creating a profile yet. Until there is, a Debug build imports one from a file —
see [`DevSeed.swift`](apps/apple/Bastion/DevSeed.swift). Drop this at
`~/Library/Application Support/io.mgcrea.bastion.debug/import.json`:

```json
{
  "token": "dev",
  "profiles": [
    {
      "name": "prod",
      "server": "shopify",
      "allowWrites": false,
      "values": {
        "SHOPIFY_STORE_DOMAIN": "your-store.myshopify.com",
        "SHOPIFY_CLIENT_ID": "…",
        "SHOPIFY_CLIENT_SECRET": "…"
      }
    }
  ]
}
```

Launching the Debug app once moves every secret into the Keychain, writes the non-secret values to
`profiles.json`, leaves a bearer token in `dev-token`, and **consumes** `import.json` so it cannot
be re-imported. Debug-only by design: a release build that imported credentials from a file anyone
could drop in its Application Support directory would be a way to add a profile to somebody else's
gateway.

Seven of the ten servers are not published to npm, so a Debug build also needs
`~/Library/Application Support/io.mgcrea.bastion.debug/dev.json` pointing at your checkouts:

```json
{
  "node": "/opt/homebrew/opt/node@24/bin/node",
  "repo": "/Users/you/Projects/mgcrea/mgcrea-ai"
}
```

## Licence

Not settled. The intent mirrors cupertino — source-available for the app, so a program that holds
every credential you own can be read and compiled by the people trusting it, with the notarized
build sold. Nothing here is licensed yet, and that is a gap rather than a position.
