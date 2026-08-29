# Servers

The closed list of MCP servers Bastion supervises in v1.

Everything below the marker is generated from [`servers.json`](../servers.json) by
`make servers`, and CI fails if it has drifted. Edit the manifest, not this file.

This file is excluded from `oxfmt` for that reason. The formatter pads markdown
table cells to a common width and the generator does not, so with both running
`make servers` and `make format` would each undo the other and no state would
satisfy CI. A generated file's layout belongs to its generator.

## Why the list is closed

Bastion spawns manifest-listed servers and nothing else. That is a security
property rather than a missing feature: the process it starts inherits the
user's credentials and runs unsandboxed, so "run whatever the config names" is
the same shape of hole as CVE-2025-49596. The catalog problem is solved and free
elsewhere — Docker MCP Toolkit ships hundreds of curated servers, Anthropic
ships MCPB double-click install and an official registry. The part worth
building is the runtime underneath: supervision, identity, and a record of what
was called.

## What the audit log can and cannot see

Bastion sees the JSON-RPC frames crossing the gateway: which tool, which
arguments, which profile, how long, what came back. It does **not** see what a
server then does over the network or on the filesystem. A server that reads a
file it was never asked about does so out of Bastion's sight. The Activity
window is a record of requests, not a sandbox.

## Two protocol eras

The 2026-07-28 revision removed the `initialize` handshake: a modern client
declares its protocol version, identity and capabilities in each request's
`_meta`, so any request can be served by any instance. That is what makes one
shared server instance correct rather than a hack, and it is why Bastion fronts
clients with it.

None of the servers below are modern. Every one runs an SDK whose newest
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
- **Source** — `npm` is published and installable; `local` is a private checkout
  under the mgcrea-ai directory.

<!-- <generated:servers> generated from servers.json by `make servers` — do not edit by hand -->

| Server | Id | Binary | Source | Write gate | Secrets |
| --- | --- | --- | --- | --- | --- |
| [Shopify](https://github.com/mgcrea/mcp-shopify) | `shopify` | `shopify-mcp` | `@mgcrea/mcp-shopify` (npm) | read-only | 1 |
| [App Store Connect](https://github.com/mgcrea/mcp-appstore-connect) | `appstore-connect` | `appstore-connect-mcp` | `@mgcrea/mcp-appstore-connect` (npm) | `APP_STORE_CONNECT_ALLOW_WRITES` | 1 |
| Keycloak | `keycloak` | `keycloak-mcp` | `mcp-keycloak` (local) | `KEYCLOAK_ALLOW_WRITES` | 2 |
| OVHcloud | `ovh-api` | `ovh-api-mcp` | `@mgcrea/mcp-ovh-api` (npm) | `OVH_ALLOW_WRITES` | 4 |
| [Reddit](https://github.com/mgcrea/mcp-reddit) | `reddit` | `reddit-mcp` | `mcp-reddit` (local) | `REDDIT_ALLOW_WRITES` | 1 |
| [X](https://github.com/mgcrea/mcp-x-api) | `x-api` | `x-api-mcp` | `mcp-x-api` (local) | `X_API_ALLOW_WRITES` | 2 |
| TastyTrade | `tastytrade` | `tastytrade-mcp` | `mcp-tastytrade` (local) | `TASTYTRADE_ALLOW_TRADING` | 2 |
| BoursoBank | `boursobank` | `boursobank-mcp` | `mcp-boursobank` (local) | `BOURSOBANK_ALLOW_TRADING` | 1 |
| Buzzberg | `buzzberg` | `buzzberg-mcp` | `mcp-buzzberg` (local) | read-only | — |
| Yahoo Finance | `yahoo-finance` | `yahoo-finance-mcp` | `mcp-yahoo-finance` (local) | read-only | 2 |

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

Fill exactly one of: **Inline private key** (`APP_STORE_CONNECT_P8`), **Private key file** (`APP_STORE_CONNECT_P8_PATH`)

Per-profile state: `APP_STORE_CONNECT_CONFIG`

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

Fill exactly one of: **Client credentials** (`KEYCLOAK_CLIENT_SECRET`), **Username and password** (`KEYCLOAK_USERNAME` + `KEYCLOAK_PASSWORD`)

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

Fill exactly one of: **OAuth2 service account** (`OVH_CLIENT_ID` + `OVH_CLIENT_SECRET`), **Application key triplet** (`OVH_APPLICATION_KEY` + `OVH_APPLICATION_SECRET` + `OVH_CONSUMER_KEY`), **Access token** (`OVH_ACCESS_TOKEN`)

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

Per-profile state: `REDDIT_TOKEN_PATH`

Per-profile OAuth callback: `REDDIT_REDIRECT_URI`

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
| `X_ADS_ENABLED` | — | — | Registers the Ads API tools. Needs a user context. |
| `X_ADS_ALLOW_WRITES` | — | — | Enables campaign mutations. No effect without X_ADS_ENABLED. |

Fill exactly one of: **App-only bearer token** (`X_API_BEARER_TOKEN`), **OAuth2 user context** (`X_API_CLIENT_ID`)

Per-profile state: `X_API_CONFIG`, `X_API_TOKEN_FILE`

Per-profile OAuth callback: `X_API_REDIRECT_URI`

### TastyTrade

TastyTrade brokerage API: accounts, positions, balances, quotes, and order entry.

The reason write gates are per-profile rather than global. One
tastytrade/cert profile with trading on and one tastytrade/prod
profile with trading off is a sane setup; a single global switch
makes it unexpressible.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `TASTYTRADE_CLIENT_SECRET` | yes | yes | OAuth client secret. |
| `TASTYTRADE_REFRESH_TOKEN` | yes | yes | Long-lived refresh token. This is the credential that can move money. |
| `TASTYTRADE_ENV` | — | — | prod or cert. cert is the sandbox, and the right default for a first profile. |
| `TASTYTRADE_SCOPE` | — | — | OAuth scope. Defaults to `read trade`; narrow it to `read` for a read-only profile. |
| `TASTYTRADE_ALLOW_TRADING` | — | — | Enables order entry. The highest-consequence gate in the manifest. |

### BoursoBank

BoursoBank customer API: accounts, transactions, statements, market data.

Logs in through a real browser session and needs MFA, so a profile of
this server is not merely credentials — it is a live session with a
timeout. The supervisor's idle-stop policy has to account for that.

The session cache is not a secret in the Keychain sense but it is
bearer-equivalent while it lasts, which is why it is stateEnv.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `BOURSOBANK_CLIENT_NUMBER` | yes | — | Customer number used to log in. |
| `BOURSOBANK_PASSWORD` | — | yes | Login password. Omit to log in interactively instead. |
| `BOURSOBANK_SESSION_PATH` | — | — | Where the authenticated session is cached. Per-profile. |
| `BOURSOBANK_DOCUMENTS_DIR` | — | — | Where downloaded statements land. Per-profile. |
| `BOURSOBANK_ALLOW_TRADING` | — | — | Enables order entry on the linked brokerage account. |

Per-profile state: `BOURSOBANK_SESSION_PATH`, `BOURSOBANK_DOCUMENTS_DIR`

### Buzzberg

Buzzberg market intelligence: speaker calls, timelines and crowd sentiment.

Holds no credential at all — it drives a browser. It is in the
manifest for supervision and audit, not for secret storage, and it is
the one entry that proves those two jobs are separable.

It also spawns a browser, so its memory cost is unlike every other
entry here. Idle-stop matters more for this one than for any other.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `BUZZBERG_BROWSER_CHANNEL` | — | — | Browser channel to drive, e.g. chrome. Defaults to chrome. |
| `BUZZBERG_BROWSER_EXECUTABLE_PATH` | — | — | Explicit browser binary, when the channel cannot be found. |
| `BUZZBERG_BROWSER_HEADLESS` | — | — | Run the browser headless. On by default. |

### Yahoo Finance

Yahoo Finance market data: quotes, fundamentals, holders, time series.

Read-only and normally credential-free: the cookie and crumb are a
fallback for when the anonymous path is throttled. Marked secret
anyway, because a session cookie is a session cookie.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `YAHOO_FINANCE_COOKIE` | — | yes | Session cookie, when the anonymous crumb flow is being refused. |
| `YAHOO_FINANCE_CRUMB` | — | yes | Matching crumb for the cookie above. |
| `YAHOO_FINANCE_CONCURRENCY` | — | — | Parallel requests. Defaults to 4. |
<!-- </generated:servers> -->
