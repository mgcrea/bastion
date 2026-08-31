# Remote servers

Everything Bastion learned by actually running one, rather than by reading about
it. `docs/servers.md` describes the catalog; this describes the transport under
the remote half of it, and the traps that only a live credential exposes.

## What a remote server is, and what it costs

A **child** server is an npm package Bastion installs and runs, speaking stdio.
A **remote** server is an https endpoint somebody else operates. Nothing is
installed, no process is started, and the headline claim — one process per
server instead of one per editor — does not apply to it at all.

Three of the four reasons to put a gateway in front of a server survive:

|                             | Remote server                                                                    |
| --------------------------- | -------------------------------------------------------------------------------- |
| One process, N clients      | **Gone.** There was never a process to share.                                    |
| Credentials in the Keychain | **Stronger.** The alternative is a key in plaintext in every repo's `.mcp.json`. |
| Every tool call recorded    | **Unchanged.** The same JSON-RPC frames cross the same gateway.                  |
| Per-profile identity        | **Kept.** `prod/stripe` beside `connect/stripe` is two identities, one app.      |
| Per-profile write gate      | **Weakened**, and by name only — see below.                                      |

One thing is genuinely worse than running your own copy: **the upstream rate
limit becomes a shared resource.** With one process per client each spent its
own budget; behind one profile they spend one. There is no fix at this layer.

## Where a remote server may live

The catalog's KEPT rule is that nothing arriving over the wire can name a
package, a path or an argv. A remote server replaces the command line with a
URL, so the rule needs a second clause — and a URL in the installed list is a
`fetch(whatever_you_typed)` primitive pointed at whatever it resolves to. The
interesting targets are all on the inside:

- `169.254.169.254`, the cloud metadata address, which hands credentials to
  anything that asks.
- The user's own LAN: a router's admin page, a NAS, a printer.
- **Bastion's own gateway on `127.0.0.1:8720`**, which is the sharp one. A
  client's bearer token is minted for the gateway, so a "remote server" pointed
  back at it would replay that token against every other profile in the app,
  from inside the one component allowed to hold it.

`RemoteEndpoint` refuses all of it: https only, to a public host, checked on
**every request** rather than once when the entry was added — a name that passed
yesterday can resolve somewhere else today. A cross-origin redirect is refused
rather than followed without the credential, because following it without the
header just fails, and following it with the header is how a token is stolen.

`make remote-check` asserts this as a pure function of a URL: no app, no
network.

## The write gate, and what it cannot promise

`writeGate` is an environment variable, and a remote server has no environment.
So the gate moves to the only thing Bastion controls — what it forwards. Named
tools are **absent from `tools/list`** with writes off rather than offered and
refused, so a model never plans around a tool it cannot use, and a call made
anyway is still refused in case a client cached an older list.

**This filters Bastion, not the server.** Anyone holding the credential can call
the same API directly. The credential's own scopes are the real boundary, which
is why the Stripe entry says to use a restricted key.

Two lists do the work, and the measurement changed which one matters. Of the
four tools hidden on a live Stripe profile, **only one was named in the
manifest**; the other three were caught solely by the server's own
`readOnlyHint: false` annotation:

| Tool                            | Caught by                                |
| ------------------------------- | ---------------------------------------- |
| `stripe_api_write`              | manifest `writeTools` **and** annotation |
| `stripe_analytics`              | annotation only                          |
| `stripe_implementation_planner` | annotation only                          |
| `send_stripe_mcp_feedback`      | annotation only                          |

A hand-written denylist would have missed three quarters of them. The annotation
is not a belt-and-braces extra here; it is the half that works. The manifest list
survives for servers that annotate nothing.

## OAuth

A remote profile authenticates with a static credential in a header, or with
OAuth 2.1. Both are permanent: a Connect platform acting on a connected account
**can only** use a restricted key, because Stripe does not support OAuth there.

What OAuth adds is the thing a gateway is uniquely placed to do: the consent
happens **once, per profile**, and every client shares the result without ever
seeing a token. Nothing is typed into a config file, and access is revoked from
the provider's dashboard rather than hunted for across four repos.

The flow, in order:

1. An unauthenticated request earns a `401` with
   `WWW-Authenticate: Bearer resource_metadata=…`. Parsed, never guessed — a
   server may put its metadata anywhere and say so only here.
2. RFC 9728 protected-resource metadata names the authorization server.
3. RFC 8414 authorization-server metadata. **The issuer it declares must match
   the one it was fetched for**; a mismatch is refused, because that is how a
   discovery document gets aimed at somebody else's authorization server.
4. RFC 7591 dynamic registration, **per profile**. Two profiles of one server
   are two identities, so one client id each keeps "revoke this one" meaning
   what it says on both ends.
5. PKCE S256 (RFC 7636), plus `resource` audience binding (RFC 8707) so a token
   minted here cannot be replayed against a different MCP server that trusts the
   same authorization server.
6. The token set lands in its **own Keychain scope**, never in `values`. That is
   what makes it structurally impossible for the profile editor to render a
   token as an editable field, or for a tool to return one.

**Authorization is only ever started by a person**, from the profile editor. It
needs a human at a browser and may never finish, and `Supervisor.call` is
synchronous on a connection's own thread — so a client whose profile is not
authorized is told to go and authorize it, naming the profile, rather than left
holding a socket. **Refresh is started by a request**, because it needs nobody:
it happens inline on a 401 and the request is retried once, behind a per-profile
lock so four clients hitting an expired token do not spend the same refresh
token four times.

When both are present, **OAuth wins over a typed key.** The opposite failure —
"I authorized this and it still says my credential is wrong" — is far worse than
its mirror, and the editor says which is in force. Signing out hands the key its
job back.

## The traps, all of them measured

Every one of these was found by running the thing, and none is documented where
you would look for it.

### A registration endpoint accepting a redirect URI proves nothing

The first implementation used `ASWebAuthenticationSession` with a private-use URI
scheme, which RFC 8252 §7.1 endorses and which Stripe's dynamic registration
**accepts** — `201 Created`, redirect URI echoed back. It does not work:

```
[safe-links] redirect (io.mgcrea.bastion.debug:/oauth/callback?code=…)
blocked. URL has invalid protocol
```

Stripe's consent page runs a link guard that refuses to navigate anywhere that
is not http or https. The authorization succeeds, the page says "Authorization
successful", a real code is minted — and the browser then declines to hand it
back, so the app waits for a callback that has already been thrown away.

The fix is the RFC 8252 §7.3 loopback redirect,
`http://127.0.0.1:<port>/oauth/callback`, which is http and survives the guard.
`RemoteOAuthCallback` binds `INADDR_LOOPBACK` on port 0, lives for one request or
five minutes, and closes.

Deliberately **not** on the gateway. `Gateway.route` checks `Host`, then
`Origin`, then the bearer token _before_ dispatching, and `audit-listener.sh`
asserts that order; a redirect arrives with no bearer token, so a route there
would mean a carve-out in front of the exact check the audit exists to protect.

The lesson generalises: **registration accepting a redirect URI is not evidence
the consent page will navigate to it. Only a real click is.**

### RFC 8414 inserts the well-known segment in the middle

For issuer `https://access.stripe.com/mcp`, the metadata is at

```
https://access.stripe.com/.well-known/oauth-authorization-server/mcp   200
https://access.stripe.com/mcp/.well-known/oauth-authorization-server   404
```

The intuitive concatenation is the one that fails. Both forms appear in the
wild, so `RemoteOAuth.metadataURLs` returns every spec-legal location in order.

### The tool surface changes with the auth mode

This is the one most likely to bite somebody else. The same server, the same
account, two credentials:

| Restricted API key        | OAuth session                     |
| ------------------------- | --------------------------------- |
| `get_stripe_account_info` | —                                 |
| —                         | `list_available_accounts_or_orgs` |
| —                         | `manage_stripe_accounts`          |

A key is bound to one account, so a single-account tool makes sense. An OAuth
session can span several, so Stripe swaps it for account-selection tools.
**Anything that hardcodes a Stripe MCP tool name breaks when the auth mode
changes**, and nothing in the docs says so.

Note that `manage_stripe_accounts` is annotated `readOnlyHint: true` and is
therefore exposed with writes off. That is defensible — it changes which account
the session acts on, which is session state and not account data — but it is the
one place where "read-only" is doing slightly more work than the words suggest.

### The dialect was two revisions off, and only a credential could show it

`mcp.stripe.com` refuses `initialize` without a credential, so for a while the
entry carried the default an unmeasured server gets, `2025-11-25`. A live
handshake negotiates **`2025-03-26`** — the oldest in the catalog. Nothing would
have looked broken; the manifest would simply have been claiming a version the
server does not speak.

This is the second time this repo has been caught by exactly that. The first was
the manifest claiming `2025-06-18` for every child server until a handshake was
run against one.

### Stripe is a public client, and issues no session

- `token_endpoint_auth_methods_supported: ["none"]` — there is no client secret,
  which removes the most dangerous thing the flow would otherwise store.
- No `Mcp-Session-Id` is issued, so a refreshed token needs no re-handshake.
- `stripe_api_read` needs both `stripe_api_operation_id` (e.g. `GetBalance`) and
  a `parameters` object, even an empty one.

### A Keychain item added from the command line wedges the whole gateway

Not OAuth-specific, but it cost an afternoon. An item created with
`security add-generic-password` carries no ACL entry for the Bastion binary, so
the first read blocks in `securityd` waiting for a consent click nobody is there
to give. Because bearer-token authentication is _also_ a Keychain read, that
wedges **every** request the gateway has, and the symptom is an empty response
with no log line — which reads as a transport bug and is not one.

Let the app write its own items. `scripts/remote-live-check.sh` seeds through
`import.json` for exactly this reason.

## What asserts what

|                          |                                                                                                                                                                                                                                                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make remote-check`      | The endpoint rules, the SSE collapse, the OAuth client and the callback listener, as pure functions. No app, no network.                                                                                                                                                                                       |
| `make remote-live-check` | The whole path against `mcp.stripe.com`. Needs no credential: an unauthenticated `initialize` is answered with 401, which exercises DNS pre-flight, https, the POST, the profile's headers, the status mapping and the sentence a client is left holding.                                                      |
| `make audit`             | The five listener rules — for **both** listeners, since the callback added a second one — plus that the app still ships no entitlements file, which `URLSession` and the OAuth flow both turned out not to need. It also fails if a third listener ever appears, rather than vouching for two and ignoring it. |
| `make builtin`           | That no tool returns a secret, tokens included.                                                                                                                                                                                                                                                                |

A local fake server is deliberately **not** part of this. It would have to live
on `127.0.0.1`, which `RemoteEndpoint` refuses by design and must go on
refusing; adding a bypass so a test could pass would delete the property under
test. The coverage is split instead: pure functions locally, the real path
against a real server.
