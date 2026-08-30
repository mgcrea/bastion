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
| **write permissions** | Per **profile**, not per process. `unifi-network/lab` with writes on beside `unifi-network/home` with writes off is expressible; a process boundary never made it so. |

What is genuinely given up is isolation between two clients of the _same_ profile. That is the
trade, and it is the right one: they are the same identity with the same permissions, which is
exactly the case where a second process bought nothing but memory.

## Servers

**Bastion ships with nothing installed.** It ships with a _catalog_ of nine, listed in
[`servers.json`](servers.json) and documented in [docs/servers.md](docs/servers.md); the list an
install actually runs lives in Application Support, starts empty, and the user edits it. Install
from the catalog, or add any other MCP server by npm package name. Code is fetched on demand into
Bastion's own directory and run with the Node runtime in the app — the bundle carries node and npm
and no servers at all.

What is still **closed** is how a request selects one, and that is the half that was ever a security
property. The child inherits the user's credentials and runs unsandboxed, so "run whatever the
config names" is the same shape of hole as CVE-2025-49596. A client names a profile and a server id;
the id resolves against the list the _user_ installed, or it 404s. Nothing arriving over the wire
can name a package, a path or an argv, and a custom entry supplies a package and a bin name rather
than a command line.

What Bastion does not do is curate. That is solved and free elsewhere — Docker MCP Toolkit ships
hundreds of curated servers, Anthropic ships MCPB double-click install and an official registry. The
part worth building is the runtime underneath.

Adding an entry to the _catalog_ is a manifest edit and `make servers`; every generated copy is
checked in CI.

## Bastion, as one of its own servers

Every other entry in the list is an npm package Bastion downloads and relays to. One is the app.
`bastion` answers MCP in-process — no package, no child, no credentials of its own — and its tools
are the window: list and describe servers, install one from the catalog or add any npm package,
create profiles, put credentials in the Keychain, wire clients, and read what is running.

It is the one server that cannot be removed. Removing a server takes its profiles, their Keychain
entries and its downloaded code with it, which was far too much to mean "not right now" — so every
server now has a **switch** instead. A disabled server stops its children and refuses requests with
its own sentence; its profiles, credentials and installed code are untouched, and client configs
are not rewritten behind your back.

Three rules hold whatever the profile's write gate says, and they are the reason this is safe to
ship:

1. **No tool returns a secret.** `set_credential` has no counterpart, and `list_profiles` says
   _which_ variables are set, never what to.
2. **It cannot switch itself off**, which would leave no way to switch it back on from there.
3. **It cannot delete itself.**

Everything that changes anything sits behind the same per-profile write gate as every other server:
with _Allow writes_ off, the mutating tools are absent from `tools/list` entirely rather than
offered and refused, so a model never plans around a tool it cannot use. And every call it serves
goes through the same audit line as a relayed one — the server that can change everything is not
the server that leaves no trace.

It ships **disabled**. It is a control plane for a daemon holding every credential you own, so it
takes three deliberate acts to reach: switch it on, give it a profile, wire a client.

The licence gate does not apply to it, and that is the gate's own rule rather than a hole in it:
what is sold is the _relay_. This server relays nothing, spawns nothing and holds no credential. It
also means an unlicensed user can have their agent set Bastion up, and meets the licence sentence
at the point they have something to lose by not having one.

```bash
make builtin        # the write gate, the two self-refusals, and the secrets wall
```

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
| **Catalog**          | nine seeded servers, a generator, and a CI drift check                              |
| **Server store**     | the user's own list, on-demand npm install, add, remove, and a per-server switch    |
| **Bastion's server** | Bastion as one of its own servers, so an agent can manage it — off by default       |
| **Keychain**         | per-profile credentials, per-client tokens                                          |
| **Activity window**  | what is running, who is attached, and every tool call, live                         |
| **`bastion-bridge`** | stdio hosts reach the gateway over HTTP; starts Bastion if it is not up             |
| **Migration**        | four `.mcp.json` credential sets moved into the Keychain, configs repointed         |
| **`make smoke`**     | four concurrent clients, colliding ids, exactly one child, `kill -9` recovery       |
| **`make audit`**     | the five security rules, against the real bundle                                    |
| **`make dialect`**   | 24 conformance checks across both eras                                              |
| **`make builtin`**   | the write gate hides the write tools, and no tool returns a secret                  |

Bastion is what the 2026-07-28 spec calls a **dual-era server**. A modern client declares its
protocol version, identity and capabilities in each request's `_meta` and needs no handshake at
all; a legacy client opens with `initialize` and is served that way. Both land on the one handshake
Bastion took with the child at spawn, and `server/discover` — mandatory in the modern revision, and
implemented by none of these servers — is synthesised from it.

None of the nine catalog servers are modern. Every one runs an SDK whose newest protocol is
`2025-11-25`, which is what they negotiate. The manifest said `2025-06-18` until a live handshake was
actually run against one; that was Bastion's own pin masquerading as a fact about the servers. A
server you add yourself is fronted the same way, and declares its own dialect when you add it.

Not built yet, in build order: the signed release path — Developer ID signing, notarization,
Sparkle, the appcast and a Homebrew cask. And a login item, which is what would let an
`type: http` client reach Bastion from cold the way a bridge-spawning one already can.

Five limitations worth knowing now:

- **Bastion has no login item yet.** A stdio client's bridge starts it on demand, so a Claude
  Desktop entry works from cold. A client configured with a plain `type: http` URL has no such
  path and needs Bastion already up — which is the case for the four repos below.
- **The repointed repos need Bastion running.** `mgcrea-ai/mcp-{shopify,keycloak,appstore-connect}/.mcp.json`
  now call `http://127.0.0.1:8720/...` instead of spawning anything, so with Bastion stopped those
  servers are simply unreachable. There is no login item yet; that lands with the release path.

- **Server-initiated requests are refused, not routed.** Sampling, elicitation and roots get a
  JSON-RPC error explaining why: a shared instance has no single client to ask, and picking one
  would hand one project's agent a prompt raised on behalf of another's. The 2026-07-28 spec
  replaces all three with Multi Round-Trip Requests and puts them on a ~12-month offramp. No server
  in the catalog uses any of the three, so the full MRTR resume path is unbuilt rather than broken —
  though a server somebody _adds_ could use one, which is the first thing the open list makes
  reachable that the closed one did not.
- **Responses are a single JSON object, never an SSE stream.** That means no
  `notifications/progress` on a long call and no `subscriptions/listen`. Both are optional in the
  spec, and both are real gaps.
- **`Mcp-Param-*` headers are forwarded but not validated.** Doing it needs a cached per-profile
  tool list to read `x-mcp-header` annotations from. No server in the catalog annotates a parameter,
  so it is unreachable with the seeded list and reachable with a server you add.

## Working on it

Requires macOS 26.0 and Xcode 26. The Swift half is `xcodebuild`, named by the Makefile rather than
wrapped by it.

```bash
make app            # build Bastion.app (Debug)
make run            # build and launch the menu bar agent
make stop           # quit it
make audit          # assert the listener is loopback-only and refuses foreign Origin/Host
make dialect        # assert both protocol eras against a running build
make builtin        # assert Bastion's own server: the write gate, and the secrets wall
make install        # install the Debug build to /Applications

make bundle         # build, stage node + npm, verify the install path, and sign a Release
make build-release  # bundle, then notarize and staple (needs AC_* credentials)
make wiring-check   # assert the config merge leaves other people's files alone
make wiring-check-real  # the same, against your actual client configs (read-only)
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

Four of the nine catalog servers are not published to npm, and in a Debug build a checkout wins over
an install anyway, so dogfooding wants
`~/Library/Application Support/io.mgcrea.bastion.debug/dev.json` pointing at them:

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
