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

For a **remote** server none of this applies, because there is no process to share. Three of the
four reasons to put a gateway in front of a server survive — the Keychain, the audit line, and
per-profile identity — and one does not. The write gate is the one that weakens: a child gets an
environment variable that switches its destructive tools off inside the server, and a remote server
has no environment, so the gate becomes a list of tool names Bastion refuses to forward. That
filters Bastion, not the server. Anyone holding the credential can call the same API directly, and
the credential's own scopes are the real boundary — which is why the Stripe entry says to use a
restricted key.

## Servers

**Bastion ships with nothing installed.** It ships with a _catalog_ of nine, listed in
[`servers.json`](servers.json) and documented in [docs/servers.md](docs/servers.md); the list an
install actually runs lives in Application Support, starts empty, and the user edits it. Install
Install from the catalog, or add any other MCP server by npm package name. Code is fetched on demand into
Bastion's own directory and run with the Node runtime in the app — the bundle carries node and npm
and no servers at all.

The transport, its rules, and everything measured rather than assumed about it are in
[docs/remote-servers.md](docs/remote-servers.md).

For a remote server there is a second way to authenticate, and it is the one worth having.
**Bastion runs the OAuth dance once, per profile, and every client shares the result without ever
seeing a token** — nothing is typed into a config file, and access is revoked from the provider's
own dashboard rather than hunted for across four repos. Press _Sign in with Stripe_ on a profile;
Bastion discovers the authorization server from the 401, registers itself dynamically, runs PKCE
S256 in an ephemeral browser window, and keeps the token in the Keychain, refreshing it behind
every client's back. A restricted key still works and is not going away — it is the only thing that
works for a Connect platform acting on a connected account, where Stripe does not support OAuth.

One entry in the catalog is not a package. **Stripe runs its own MCP server**, and Bastion fronts
that rather than shipping a client for it — the entry used to be a placeholder for
`@mgcrea/mcp-stripe`, a package nobody ever wrote. This is the same position the catalog already
takes: what is worth building is the runtime underneath a server, not another server. A **remote**
entry has no package, no process and nothing to install; what it still has is the credential in the
Keychain instead of in every repo's `.mcp.json`, one identity per profile, and every call in the
audit log. What it does not have is the headline — see [Status](#status).

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

Bastion sees the JSON-RPC frames crossing the gateway: which profile, which method, which tool, and
the arguments it was called with. A profile can opt into recording what came back as well; that is
off by default, because a result is the unbounded half.

**A credential is never recorded.** `set_credential` takes a secret as an argument, so its arguments
are dropped whatever the setting says, and any value under a key the server's manifest marks secret
is blanked. That is a rule in one place — `CallCapture` — rather than a habit at three call sites,
and `make builtin` plants a canary through `set_credential` and asserts it never comes back out.

**Nothing recorded is written to disk unless you ask for it.** By default the log is a bounded ring
in memory, cleared when Bastion quits. This is not a matter of intent: every ordinary log line is
mirrored to stderr, which for an app started by LaunchServices outlives the process, so payloads
take a separate path that never reaches it. `make builtin` asserts that too, against the real
bundle.

Settings › Activity turns on a durable **audit log**: append-only JSONL under Application Support,
0600, in segments, with retention by age and size. Whether that file carries arguments and results
is a second switch, off on its own — keeping a record of _which_ tools ran is a smaller thing to
leave on disk than keeping what they were called with.

Each record carries a hash of the one before it, so an edited field, a removed record or a truncated
file can be detected. That is the whole claim, and it is worth being exact about: it catches
tampering by something that does not know it is a chain, and corruption by something that was not
trying. It is **not** proof against anyone who can write the file, because they can recompute it.
Retention drops whole segments for the same reason — a chain cannot lose a record from the middle
and still verify.

Export writes the segments plus a `manifest.json` naming each one, its record count and its digest,
with the chain head. The count matters: a chain cannot detect its own truncation, because lopping
off the tail leaves a shorter valid chain. Signing is optional and goes in `signature.json` beside
the manifest rather than inside it — a signature written into the bytes it signs is what makes half
the signed-JSON formats in the world ambiguous. A signature proves the export came from this Mac and
was not altered afterwards; it does not prove the log was not curated before it was signed, and it
means nothing to a recipient who has not been given the key some other way.

An agent asking Bastion for recent activity is answered with **its own profile's lines** — which it
already sent and received, so it learns nothing it did not have. Another profile's lines never carry
arguments or results.

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

A remote server adds a sixth, and it is the same rule pointed outward. The five above constrain what
may reach Bastion; a URL in the installed list constrains where Bastion may reach, and it is the
analogue of a command line — `fetch(whatever_you_typed)` beside `spawn(whatever_you_typed)`.

6. A remote endpoint is **https to a public host**, checked on every request rather than once when
   it was added, because a name that passed yesterday can resolve somewhere else today. Loopback,
   private, link-local and the cloud metadata address are refused; so is Bastion's own gateway,
   which is the sharp one — a "remote server" pointed at `127.0.0.1:8720` would be a way to replay
   one client's bearer token against every other profile in the app. A cross-origin redirect is
   refused rather than followed without the credential.

```bash
make audit
```

[`scripts/audit-listener.sh`](scripts/audit-listener.sh) launches the built bundle and asserts all of
it: loopback-only via `lsof`, a foreign `Origin` and a rebound `Host` both refused, the refusal
order, unauthenticated and wrong-token requests refused, and that `profiles.json` holds no value for
any variable the manifest marks secret. It replaces cupertino's `audit-network.sh`, whose claim — no
network at all — Bastion cannot make. The property worth keeping was "a claim CI can check", not the
particular claim.

[`scripts/remote-check.swift`](scripts/remote-check.swift) asserts rule 6 as a pure function of a
URL — 45 checks, no app and no network — and `make remote-live-check` asserts the whole path against
Stripe's real server, which needs no credential because an unauthenticated `initialize` is answered
with a 401 that exercises every step but the last.

The app ships with **no entitlements file at all**. Spawning children and binding loopback need
none, and with the sandbox off `com.apple.security.network.server` is unnecessary. An empty
permission set that is true by construction is checkable; one arrived at by deletion is not, so the
audit asserts the setting is absent rather than empty.

## Status

Built and verified:

|                         |                                                                                     |
| ----------------------- | ----------------------------------------------------------------------------------- |
| **Gateway**             | loopback HTTP, `Origin` / `Host` / bearer, hand-written so the checks are auditable |
| **Supervisor**          | one child per profile, id remapping, backoff, circuit breaker, idle stop            |
| **Dialect**             | dual-era: modern 2026-07-28 and legacy `initialize`, onto legacy children           |
| **Catalog**             | nine seeded servers, a generator, and a CI drift check                              |
| **Server store**        | the user's own list, on-demand npm install, add, remove, and a per-server switch    |
| **Remote servers**      | an https endpoint fronted like any other server — Stripe's, in the catalog          |
| **OAuth 2.1**           | discovery, dynamic registration, PKCE and refresh — one consent, every client       |
| **Bastion's server**    | Bastion as one of its own servers, so an agent can manage it — off by default       |
| **Keychain**            | per-profile credentials, per-client tokens                                          |
| **Activity window**     | what is running, who is attached, and every tool call with its arguments, live      |
| **`bastion-bridge`**    | stdio hosts reach the gateway over HTTP; starts Bastion if it is not up             |
| **Migration**           | four `.mcp.json` credential sets moved into the Keychain, configs repointed         |
| **`make smoke`**        | four concurrent clients, colliding ids, exactly one child, `kill -9` recovery       |
| **`make audit`**        | the five security rules, against the real bundle                                    |
| **`make dialect`**      | 24 conformance checks across both eras                                              |
| **`make builtin`**      | the write gate hides the write tools, and no tool returns a secret                  |
| **`make unit`**         | dialect, HTTP parser, call capture and the audit chain — 183 checks                 |
| **`make audit-check`**  | an export signature through a round trip, key loss included — 18 checks             |
| **`make remote-check`** | where a remote server may live, the SSE collapse, and the OAuth client — 79 checks  |

Bastion is what the 2026-07-28 spec calls a **dual-era server**. A modern client declares its
protocol version, identity and capabilities in each request's `_meta` and needs no handshake at
all; a legacy client opens with `initialize` and is served that way. Both land on the one handshake
Bastion took with the child at spawn, and `server/discover` — mandatory in the modern revision, and
implemented by none of these servers — is synthesised from it.

None of the nine catalog servers are modern. Every one runs an SDK whose newest protocol is
`2025-11-25`, which is what they negotiate. The manifest said `2025-06-18` until a live handshake was
actually run against one; that was Bastion's own pin masquerading as a fact about the servers. A
server you add yourself is fronted the same way, and declares its own dialect when you add it.

**Stripe's is the oldest dialect in the file**, and it took a credential to find out.
`mcp.stripe.com` refuses `initialize` without one — it answers 401 with a `WWW-Authenticate` naming
its protected-resource metadata — so for a while the entry carried the default an unmeasured server
gets. A live handshake negotiates `2025-03-26`, two revisions behind that default, which is exactly
why the default is never left in place: the manifest would have claimed a version this server does
not speak, and nothing would have looked wrong.

Not built yet, in build order: the signed release path — Developer ID signing, notarization,
Sparkle, the appcast and a Homebrew cask. And a login item, which is what would let an
`type: http` client reach Bastion from cold the way a bridge-spawning one already can.

Seven limitations worth knowing now:

- **Bastion has no login item yet.** A stdio client's bridge starts it on demand, so a Claude
  Desktop entry works from cold. A client configured with a plain `type: http` URL has no such
  path and needs Bastion already up — which is the case for the four repos below.
- **The repointed repos need Bastion running.** `mgcrea-ai/mcp-{shopify,keycloak,appstore-connect}/.mcp.json`
  now call `http://127.0.0.1:8720/...` instead of spawning anything, so with Bastion stopped those
  servers are simply unreachable. There is no login item yet; that lands with the release path.

- **A remote server's write gate is a filter, not a boundary.** A child gets an environment
  variable that switches its destructive tools off inside the server. A remote server has no
  environment, so the gate becomes a list of tool names Bastion will not forward — plus any tool
  the server annotates as not read-only. Anyone holding the credential can call the same API
  directly, so the credential's own scopes are the real boundary. For Stripe that means a
  restricted key, which is what its catalog entry says.
- **A remote server's rate limit is shared.** With one process per client each client spent its own
  budget upstream. Behind one profile they spend one, so a client in a loop can exhaust the limit
  for every other client of that profile. That is what sharing an identity means, and there is no
  fix for it at this layer.
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
make unit           # assert the dialect translation and the HTTP parser
make remote-check   # assert the endpoint rules, the SSE collapse, and the OAuth client
make remote-live-check  # assert the remote transport against Stripe's real server
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
make catalog-check  # fail if servers.json disagrees with the servers themselves
make lint
make format
```

`servers-check` and `catalog-check` point in opposite directions and neither substitutes for the
other. The first asserts every generated copy matches the manifest; the second asserts the
manifest matches the servers it describes — that a declared variable is one the server actually
reads, that a write gate is read as a boolean, and that a variable typed as a switch states the
same default its own schema does. Only the second can catch a rename upstream, and only it can
catch a `boolean.default` of `false` on a setting the server defaults to `true`, which the
profile editor would present as the safe choice. It reads the sibling checkout named by
`MCP_ROOT` (default `~/Projects/mgcrea/mgcrea-ai`) and skips, passing, when there is none.

A Debug build carries its own bundle identifier, `io.mgcrea.bastion.debug`. That is not cosmetic:
Keychain items are scoped by app identity, so a shared identifier means a debug build reads,
overwrites and deletes the credentials the real app is holding.

[`docs/keychain.md`](docs/keychain.md) covers the rest: which scope holds what, why keychain prompts
happened and what actually fixed them, and what adopting the data protection keychain would cost —
including why the entitlement is worth having for iCloud sync and _not_ worth having to stop prompts.

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

One of the nine catalog servers is not published to npm, and in a Debug build a checkout wins over
an install anyway, so dogfooding wants
`~/Library/Application Support/io.mgcrea.bastion.debug/dev.json` pointing at them:

```json
{
  "node": "/opt/homebrew/opt/node@24/bin/node",
  "repo": "/Users/you/Projects/mgcrea/mgcrea-ai"
}
```

## Licence

Source-available for the app, so a program that holds every credential you own can be read and
compiled by the people trusting it; the notarized build is sold.

|                                                   |                                                                                                                     |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| [`apps/apple/`](apps/apple/LICENSE)               | Source-available. Read it, modify it, compile it, run your own build. Binary redistribution is the reserved part.   |
| `apps/api/`, `apps/website/`, `scripts/`, `docs/` | [MIT](LICENSE). The audits in particular are more useful copied than reserved.                                      |
| The signed build                                  | [EULA](apps/apple/EULA). $14.99 (€14.99 in the EU), every 1.x release, every Mac you own. Thirty days, full refund. |

The check is offline and cannot become anything else: `scripts/audit-listener.sh` asserts on every
build that the app binds loopback and nothing else, and an activation call would be the second
exception after `Updates.swift`. What that costs — a refunded key keeps working until the next
release — is written down in the EULA rather than left to be discovered.

[`docs/licensing.md`](docs/licensing.md) has the reasoning: what is gated and what is deliberately
not, why there is a trial as well as a refund, and why hardening the check is refused by
construction.
