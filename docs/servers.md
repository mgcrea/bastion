# Servers

The catalog Bastion ships with, which is **not** the list of servers it runs.

Everything below the marker is generated from [`servers.json`](../servers.json) by
`make servers`, and CI fails if it has drifted. Edit the manifest, not this file.

This file is excluded from `oxfmt` for that reason. The formatter pads markdown
table cells to a common width and the generator does not, so with both running
`make servers` and `make format` would each undo the other and no state would
satisfy CI. A generated file's layout belongs to its generator.

## The catalog, the list, and what is actually closed

Three things that used to be one:

- **The catalog** is the table below. It ships with the app and nothing in it is
  installed until somebody asks. It is a starting point.
- **The list** is what one install runs. It lives in
  `~/Library/Application Support/io.mgcrea.bastion/servers.json`, the user edits
  it, and it is the only list the gateway, the supervisor and the profile store
  ever consult. It starts empty.
- **The code** arrives on demand. Nothing is bundled but the Node runtime and
  the npm that came with it; `ServerInstaller` fetches a server into Application
  Support when it is added, and `Remove` deletes it again.

v1 fixed all three at build time and called it a security property. It was two
properties wearing one coat, and only one of them was load-bearing:

**Kept.** A caller selects a server by *name*, never by a path or a command
line. The process Bastion starts inherits the user's credentials and runs
unsandboxed, so "run whatever the request names" is the same shape of hole as
CVE-2025-49596 — and it is still closed. A request names a profile and a server
id; the id resolves against the list the *user* installed or it 404s. Nothing
arriving over the wire can name a package, a path or an argv.

**Dropped.** That the list itself was fixed at compile time. It bought no safety
the rule above does not already buy — the person choosing was always the user —
and it cost Bastion the ability to run any server mgcrea had not written.

A custom server is added by **npm package** or by **https URL**, never by a
command line. A package entry supplies a package, a bin name and the variables
it reads; Bastion installs it with the embedded runtime and spawns it with an
environment Bastion built. There is no field for a path and no field for an
argv, which is what keeps "add a server" from becoming "run this command".

A **remote** entry supplies a URL instead, and that is the same rule meeting a
second transport. A URL in the list is a `fetch(whatever_you_typed)` primitive
pointed at whatever it resolves to, so the KEPT rule above needs a second
clause: nothing arriving over the wire can name an endpoint either, and the
endpoints the list may hold are constrained. `RemoteEndpoint` refuses anything
but https to a public host — loopback, private, link-local and the cloud
metadata address included, and Bastion's own gateway most of all, since a
server pointed back at `127.0.0.1:8720` would be a way to replay one client's
bearer token against every other profile. It is checked on every request rather
than once when the entry is added, because a name that passed yesterday can
resolve somewhere else today. `make remote-check` asserts all of it.

What Bastion does not do is curate. That problem is solved and free elsewhere —
Docker MCP Toolkit ships hundreds of curated servers, Anthropic ships MCPB
double-click install and an official registry. The part worth building is the
runtime underneath: supervision, identity, and a record of what was called.

## What a remote server keeps, and what it gives up

The transport itself — where a remote server may live, how OAuth works, and the
traps that only a live credential exposes — is in
[remote-servers.md](remote-servers.md).

Bastion's headline claim is one process per server instead of one per editor.
A remote server has no process, so that claim simply does not apply to it —
and it is worth saying which of the reasons for a gateway survive:

| | Remote server |
| --- | --- |
| One process, N clients | **Gone.** There was never a process to share. |
| Credentials in the Keychain | **Stronger.** The alternative is a key in plaintext in every repo's `.mcp.json`, which is the problem this app opens with. |
| Every tool call recorded | **Unchanged.** The same JSON-RPC frames cross the same gateway. |
| Per-profile identity | **Kept.** `prod/stripe` beside `connect/stripe` is two identities, one app. |
| Per-profile write gate | **Weakened**, and by name only — see the Write gate note above. |

One thing is genuinely worse than running your own copy. **The upstream rate
limit becomes a shared resource.** With one process per client each client spent
its own budget; behind one profile they spend one, so a client in a loop can
exhaust a limit for every other client of the same profile. There is no fix for
that at this layer — it is what sharing an identity means.

## What the audit log can and cannot see

Bastion sees the JSON-RPC frames crossing the gateway: which profile, which
tool, and the arguments it was called with — and what came back, for a profile
that asks for it. A credential is never recorded.

None of it is written to disk unless you turn on the audit log in
Settings › Activity, which keeps append-only segments under Application Support
with a hash chain over them. That chain detects an edited, removed or truncated
record; it is not proof against anyone who can write the file, because they can
recompute it.

It does **not** see what a server then does over the network or on the
filesystem. A server that reads a file it was never asked about does so out of
Bastion's sight. The Activity window is a record of requests, not a sandbox.

## Two protocol eras

The 2026-07-28 revision removed the `initialize` handshake: a modern client
declares its protocol version, identity and capabilities in each request's
`_meta`, so any request can be served by any instance. That is what makes one
shared server instance correct rather than a hack, and it is why Bastion fronts
clients with it.

None of the catalog entries below are modern. Every one runs an SDK whose newest
protocol is `2025-11-25`, and `server/discover` against one returns `-32601` —
the exact signal the spec names for recognising a legacy server. Bastion is
therefore what the spec calls a **dual-era server**: it answers modern requests
statelessly and legacy `initialize` handshakes too, and translates either onto
the one handshake it performed with the child at spawn.

The `dialect` column is the newest version the server itself speaks, measured
by handshaking with it — not the version Bastion offers clients. `make dialect`
asserts both eras against a running build.

## Reading the table

- **Write gate** — the environment variable that turns the destructive tools on.
  Set per profile, never globally. `read-only` means the server registers no
  mutating tool at all.
- **Secrets** — how many of the server's variables are credentials. Those live
  in the Keychain and are never written into a client config file.
- **Source** — `npm` is published, so Bastion can install it on demand; `local`
  is not published yet and resolves only against a checkout named by `dev.json`
  in a Debug build. Adding a `local` entry works; installing it reports "not
  published", which is the honest answer and better than a spawn that fails
  later. `remote` is somebody else's server at an https URL: nothing is
  installed, no process is started, and the Binary column is empty because there
  is none.
- **Write gate** on a remote entry names **tools**, not a variable. A child gets
  an environment variable that switches its destructive tools off inside the
  server; a remote server has no environment, so the gate moves to the only
  thing Bastion controls — what it forwards. The named tools are absent from
  `tools/list` with writes off, as is any tool the server itself annotates as
  not read-only. **This filters Bastion, not the server:** anyone holding the
  credential can call the same API directly, and the credential's own scopes
  remain the real boundary.

<!-- <generated:servers> generated from servers.json by `make servers` — do not edit by hand -->

| Server | Id | Binary | Source | Write gate | Secrets |
| --- | --- | --- | --- | --- | --- |
| [App Store Connect](https://github.com/mgcrea/mcp-appstore-connect) | `appstore-connect` | `appstore-connect-mcp` | `@mgcrea/mcp-appstore-connect` (npm) | `APP_STORE_CONNECT_ALLOW_WRITES` | 1 |
| [Reddit](https://github.com/mgcrea/mcp-reddit) | `reddit` | `reddit-mcp` | `@mgcrea/mcp-reddit` (npm) | `REDDIT_ALLOW_WRITES` | 1 |
| [X](https://github.com/mgcrea/mcp-x-api) | `x-api` | `x-api-mcp` | `mcp-x-api` (local) | `X_API_ALLOW_WRITES` | 2 |
| [UniFi Protect](https://github.com/mgcrea/mcp-unifi-protect) | `unifi-protect` | `unifi-protect-mcp` | `@mgcrea/mcp-unifi-protect` (npm) | `UNIFI_PROTECT_ALLOW_WRITES` | 3 |
| [UniFi Network](https://github.com/mgcrea/mcp-unifi-network) | `unifi-network` | `unifi-network-mcp` | `@mgcrea/mcp-unifi-network` (npm) | `UNIFI_ALLOW_WRITES` | 2 |
| [Stripe](https://docs.stripe.com/mcp) | `stripe` | — | `https://mcp.stripe.com` (remote) | `stripe_api_write`, `create_refund`, `stripe_report` (by name) | 1 |
| [Shopify](https://github.com/mgcrea/mcp-shopify) | `shopify` | `shopify-mcp` | `@mgcrea/mcp-shopify` (npm) | read-only | 1 |
| OVHcloud | `ovh-api` | `ovh-api-mcp` | `@mgcrea/mcp-ovh-api` (npm) | `OVH_ALLOW_WRITES` | 4 |
| Keycloak | `keycloak` | `keycloak-mcp` | `@mgcrea/mcp-keycloak` (npm) | `KEYCLOAK_ALLOW_WRITES` | 2 |

### App Store Connect

App Store Connect API: apps, versions, builds, TestFlight, listings, analytics, sales.

The inline key is why `secret` is a manifest field rather than a UI
guess. `.mcp.json` in mcp-appstore-connect currently holds this key in
plaintext; migrating it into a Bastion profile is the first dogfood
task in the build order.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | yes | — | The 10-character API key id. |
| `APP_STORE_CONNECT_ISSUER_ID` | yes | — | Issuer UUID from the Keys page. |
| `APP_STORE_CONNECT_P8` | — | yes | The .p8 private key, inline PEM. Preferred: Bastion keeps it in the Keychain and never writes it to disk. |
| `APP_STORE_CONNECT_P8_PATH` | — | — | Path to a .p8 file on disk. The legacy shape — it leaves the key readable outside the Keychain. |
| `APP_STORE_CONNECT_VENDOR_NUMBER` | — | — | Vendor number, needed only for sales and finance reports. |
| `APP_STORE_CONNECT_CONFIG` | — | — | Config file path. Bastion points this at the profile's own directory. |
| `APP_STORE_CONNECT_ALLOW_WRITES` | — | — | Enables the mutating tools: version metadata, screenshots, submissions, pricing. |

Satisfy exactly one of: **Inline private key** (`APP_STORE_CONNECT_P8`), **Private key file** (`APP_STORE_CONNECT_P8_PATH`)

Per-profile state: `APP_STORE_CONNECT_CONFIG`

### Reddit

Reddit API: subreddits, posts, comments, search, and the user's own history.

The clearest case for stateEnv and portEnv. This server logs a user in
over a local callback and keeps the refresh token in a file — both of
which are per-identity, so both must be per-profile.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `REDDIT_CLIENT_ID` | — | — | App client id. Anonymous app-only reads work without it; anything user-scoped does not. |
| `REDDIT_CLIENT_SECRET` | — | yes | App client secret. Empty for an installed app, set for a web or script app. |
| `REDDIT_USER_AGENT` | — | — | platform:app-id:version (by /u/username). Reddit throttles generic agents regardless of rate limit. |
| `REDDIT_REDIRECT_URI` | — | — | Loopback OAuth callback. Per-profile, or two profiles race for one port — and the URL must be registered with the Reddit app. |
| `REDDIT_TOKEN_PATH` | — | — | Where the refresh token is stored. Per-profile, or two profiles share one login. |
| `REDDIT_ALLOW_WRITES` | — | — | Enables posting, commenting and voting. |

Satisfy exactly one of: **Sign in with Reddit** (no variables — the server holds its own token)

Per-profile state: `REDDIT_TOKEN_PATH`

Per-profile OAuth callback: `REDDIT_REDIRECT_URI` as `http://127.0.0.1:{port}/callback`

### X

X (Twitter) API v2: posts, threads, timelines, search, bookmarks, and the Ads API.

Two write gates, not one: X_API_ALLOW_WRITES governs posting and
X_ADS_ALLOW_WRITES governs spending money. The manifest names the
first as the gate because that is the one the Activity window badges;
the second is an ordinary env entry that a profile sets deliberately.

X_API_MONTHLY_BUDGET_USD is here for the same reason a write gate is:
on this API a read has a price, so an unbounded profile is a bill.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `X_API_BEARER_TOKEN` | — | yes | App-only bearer token. Reads only; the Ads API rejects it outright. |
| `X_API_CLIENT_ID` | — | — | OAuth2 client id. Required for a user context, and therefore for writes and for Ads. |
| `X_API_CLIENT_SECRET` | — | yes | OAuth2 client secret, for a confidential client. |
| `X_API_REDIRECT_URI` | — | — | Loopback OAuth callback. Per-profile, or two profiles race for one port — and the URL must be registered with the X app. |
| `X_API_TOKEN_FILE` | — | — | Where the user token is stored. Per-profile, or two accounts share one login. |
| `X_API_CONFIG` | — | — | Config file path. Bastion points this at the profile's own directory. |
| `X_API_MONTHLY_BUDGET_USD` | — | — | Spend ceiling. X bills per read, so this is a real safety control, not a preference. |
| `X_API_ALLOW_WRITES` | — | — | Enables posting through the API rather than returning an intent URL. |
| `X_ADS_ENABLED` | — | — | Registers the Ads API tools. Needs a user context. Boolean — unset means off. |
| `X_ADS_ALLOW_WRITES` | — | — | Enables campaign mutations. No effect without X_ADS_ENABLED. Boolean — unset means off. |

Satisfy exactly one of: **App-only bearer token** (`X_API_BEARER_TOKEN`), **OAuth2 user context** (`X_API_CLIENT_ID`)

Per-profile state: `X_API_CONFIG`, `X_API_TOKEN_FILE`

Per-profile OAuth callback: `X_API_REDIRECT_URI` as `http://127.0.0.1:{port}/callback`

### UniFi Protect

UniFi Protect: cameras, event history, recordings, snapshots and NVR status.

Two auth shapes that are not interchangeable, which is why they are auth
modes rather than a pile of optional variables. A console API key is
refused by the private API this server reads history from, so a LAN-only
deployment genuinely needs a username and password; a cloud key reaches
the same API through api.ui.com and needs no local account at all.

Three state variables, all per-profile. The session file is an identity,
and the snapshot directory is camera footage — sharing either between two
profiles is the leak this app exists to prevent.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `UNIFI_PROTECT_HOST` | — | — | Console IP or hostname. https:// is assumed and a :port is preserved. |
| `UNIFI_PROTECT_USERNAME` | — | — | Console login. Use a Local-Access-Only account with View Only rights. |
| `UNIFI_PROTECT_PASSWORD` | — | yes | That account's password. |
| `UNIFI_PROTECT_API_KEY` | — | yes | unifi.ui.com API key. Selects cloud mode, which needs no local account. |
| `UNIFI_PROTECT_CONSOLE_ID` | — | — | Console id from api.ui.com/v1/hosts. Cloud mode only. |
| `UNIFI_PROTECT_MODE` | — | — | cloud or local. Inferred as cloud when a key and a console id are both set. |
| `UNIFI_PROTECT_TOTP` | — | yes | 2FA code. Expires in ~30s, so prefer the server's own login tool. |
| `UNIFI_PROTECT_VERIFY_TLS` | — | — | Verify the console certificate. Needs a hostname, not an IP. Boolean — unset means on. |
| `UNIFI_PROTECT_SESSION_FILE` | — | — | Cached session, mode 600. Per-profile, or two identities share one session. |
| `UNIFI_PROTECT_SNAPSHOT_DIR` | — | — | Where snapshots and exports are written. Per-profile, or one profile reads another's footage. |
| `UNIFI_PROTECT_CONFIG` | — | — | Config file path. Bastion points this at the profile's own directory. |
| `UNIFI_PROTECT_MAX_RETRIES` | — | — | Retries on 401 / 429 / 5xx. Defaults to 3. |
| `UNIFI_PROTECT_MAX_DOWNLOAD_BYTES` | — | — | Refuse a download larger than this. Defaults to 200000000. |
| `UNIFI_PROTECT_DEVICE_CACHE_TTL` | — | — | Camera id-to-name cache lifetime in seconds. Defaults to 60. |
| `UNIFI_PROTECT_ALLOW_WRITES` | — | — | Registers the mutating tools: recording settings, PTZ, device configuration. |

Satisfy exactly one of: **Cloud API key** (`UNIFI_PROTECT_API_KEY` + `UNIFI_PROTECT_CONSOLE_ID`), **Local account** (`UNIFI_PROTECT_HOST` + `UNIFI_PROTECT_USERNAME` + `UNIFI_PROTECT_PASSWORD`)

Per-profile state: `UNIFI_PROTECT_CONFIG`, `UNIFI_PROTECT_SESSION_FILE`, `UNIFI_PROTECT_SNAPSHOT_DIR`

### UniFi Network

UniFi Network API: sites, devices, clients, WLANs, port and firewall configuration.

The write gate here reaches network configuration, so a profile with it
on can take a site off the air. Two profiles - one read-only for asking
questions, one gated for changes - is the shape this is built for.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `UNIFI_HOST` | — | — | The console. A pasted browser URL is accepted and split. |
| `UNIFI_API_KEY` | — | yes | Settings, Control Plane, Integrations, Create API Key. |
| `UNIFI_CONSOLE_ID` | — | — | Console id from unifi.ui.com. Cloud mode only. |
| `UNIFI_MODE` | — | — | unifios, cloud or classic. Inferred from what is set. |
| `UNIFI_SITE` | — | — | Default site: UUID, legacy name or display name. |
| `UNIFI_USERNAME` | — | — | Legacy tier fallback only. A local admin, not an SSO account. |
| `UNIFI_PASSWORD` | — | yes | That admin's password. |
| `UNIFI_INSECURE_TLS` | — | — | Disable certificate verification, for this server only. Boolean — unset means off. |
| `UNIFI_ENABLE_LEGACY` | — | — | Registers the unifi_legacy_* tools. Boolean — unset means off. |
| `UNIFI_APP_VERSION` | — | — | Pin the controller version instead of probing it at startup. |
| `UNIFI_PAGE_LIMIT` | — | — | Page size. Defaults to 50. |
| `UNIFI_MAX_PAGES` | — | — | Pagination ceiling. Defaults to 20. |
| `UNIFI_MAX_RETRIES` | — | — | Retries on a transient failure. Defaults to 3. |
| `UNIFI_CONFIG` | — | — | Config file path. Bastion points this at the profile's own directory. |
| `UNIFI_ALLOW_WRITES` | — | — | Enables the mutating tools: WLANs, port profiles, firewall rules, device adoption. |

Satisfy exactly one of: **Console API key** (`UNIFI_HOST` + `UNIFI_API_KEY`), **Cloud API key** (`UNIFI_API_KEY` + `UNIFI_CONSOLE_ID`), **Local admin account** (`UNIFI_HOST` + `UNIFI_USERNAME` + `UNIFI_PASSWORD`)

Per-profile state: `UNIFI_CONFIG`

### Stripe

Stripe's own remote MCP server: the API surface, plus documentation and knowledge-base search.

REMOTE. This entry used to be a placeholder for @mgcrea/mcp-stripe, a
package that was never written and never published. Stripe operates a
real MCP server, so Bastion fronts that one instead: the part worth
building here was never a Stripe client, it was the runtime underneath
one - identity, credentials in the Keychain, and a record of every call.

The id is unchanged on purpose. Anyone who made a profile against the
placeholder keeps it.

DIALECT MEASURED 2026-08-31, and it is the oldest in this file. A live
handshake negotiates 2025-03-26 - two revisions behind the default an
unmeasured entry would have carried, which is exactly why the default is
never left in place. serverInfo reports stripe-mcp 1.0.0.

WRITE TOOLS ARE TWO LISTS, and the measurement is why. Of the four tools
hidden with writes off, only stripe_api_write is named below; the other
three - stripe_analytics, stripe_implementation_planner and
send_stripe_mcp_feedback - were caught solely by Stripe's own
readOnlyHint:false annotation. A hand-written denylist would have missed
three quarters of them, so the annotation is not a belt-and-braces extra
here, it is the half that works.

create_refund and stripe_report are named below and were NOT offered by
the account this was measured against. Kept rather than deleted: they
are in Stripe's published tool table, an account that exposes them wants
them gated, and a name that is never offered costs nothing.

Money moves through this one, so the gate is not a formality. Prefer a
restricted key scoped to reads and let the profile stay gated off - the
write gate cannot take back a permission the key already grants.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `STRIPE_SECRET_KEY` | — | yes | `Authorization: Bearer {value}` | Restricted API key, sent as the bearer token. A restricted key is the right one here: the write gate filters what Bastion forwards, it cannot take back a permission the key already grants. |
| `STRIPE_ACCOUNT_ID` | — | — | `Stripe-Account: {value}` | Connected account to act on behalf of, sent as Stripe-Account. Stripe does not support OAuth in this mode, so a profile using it must authenticate with a restricted key. |
| `STRIPE_API_VERSION` | — | — | `Stripe-Version: {value}` | Pin the API version instead of using the account default, sent as Stripe-Version. |

Hidden with writes off: `stripe_api_write`, `create_refund`, `stripe_report` — and any tool the server annotates as not read-only. This filters what Bastion forwards; it does not bind the server, so the credential's own scopes remain the real boundary.

Satisfy exactly one of: **Sign in with Stripe** (no variables — Bastion holds the token), **Restricted API key** (`STRIPE_SECRET_KEY`)

### Shopify

Shopify Admin GraphQL API: products, variants, collections, metafields, locations.

No write gate because there is no write path: every tool is a read.
That is why the build order takes this one end-to-end first — a bug in
the supervisor or the dialect layer cannot cost anybody data here.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `SHOPIFY_STORE_DOMAIN` | yes | — | Store handle or *.myshopify.com domain. A bare handle is expanded. |
| `SHOPIFY_CLIENT_ID` | yes | — | Custom app client id. |
| `SHOPIFY_CLIENT_SECRET` | yes | yes | Custom app client secret. Used as the Admin API access token. |
| `SHOPIFY_API_VERSION` | — | — | Admin API version, e.g. 2026-04. Defaults to the server's pinned version. |

### OVHcloud

OVHcloud API, focused on Object Storage: containers, objects, policies, regions.

Three auth modes, inferred from what is set. The signature triplet is
the only one of the three where every part is a secret, which is
exactly the sort of detail a hand-written profile form gets wrong.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `OVH_ENDPOINT` | — | — | Region endpoint: ovh-eu, ovh-ca, ovh-us. Defaults to ovh-eu. |
| `OVH_CLIENT_ID` | — | — | OAuth2 client id. |
| `OVH_CLIENT_SECRET` | — | yes | OAuth2 client secret. |
| `OVH_APPLICATION_KEY` | — | — | Application key, from https://eu.api.ovh.com/createToken/. |
| `OVH_APPLICATION_SECRET` | — | yes | Application secret. |
| `OVH_CONSUMER_KEY` | — | yes | Consumer key, which carries the granted scopes. |
| `OVH_ACCESS_TOKEN` | — | yes | A pre-minted access token. |
| `OVH_CLOUD_PROJECT` | — | — | Default public cloud project id, a 32-character hex string. |
| `OVH_REGION` | — | — | Default storage region, e.g. GRA, SBG, UK. |
| `OVH_ALLOW_WRITES` | — | — | Enables uploading, deleting and re-policying objects and containers. |

Satisfy exactly one of: **OAuth2 service account** (`OVH_CLIENT_ID` + `OVH_CLIENT_SECRET`), **Application key triplet** (`OVH_APPLICATION_KEY` + `OVH_APPLICATION_SECRET` + `OVH_CONSUMER_KEY`), **Access token** (`OVH_ACCESS_TOKEN`)

### Keycloak

Keycloak Admin REST API: realms, clients, users, roles, sessions.

The profile split is the whole point here: rgis and ivalis are two
realms on two servers with two admin identities, and a single global
instance could hold only one of them.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `KEYCLOAK_URL` | yes | — | Base URL of the Keycloak server, e.g. https://sso.example.com. |
| `KEYCLOAK_REALM` | — | — | Realm to administer. Defaults to master. |
| `KEYCLOAK_AUTH_REALM` | — | — | Realm to authenticate against, when it differs from the one being administered. |
| `KEYCLOAK_CLIENT_ID` | — | — | Client id. Defaults to admin-cli. |
| `KEYCLOAK_CLIENT_SECRET` | — | yes | Client secret. Selects the client_credentials grant. |
| `KEYCLOAK_USERNAME` | — | — | Admin username. Selects the password grant. |
| `KEYCLOAK_PASSWORD` | — | yes | Admin password. |
| `KEYCLOAK_ALLOW_WRITES` | — | — | Enables creating and modifying realms, clients, users and roles. |

Satisfy exactly one of: **Client credentials** (`KEYCLOAK_CLIENT_SECRET`), **Username and password** (`KEYCLOAK_USERNAME` + `KEYCLOAK_PASSWORD`)
<!-- </generated:servers> -->
