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

Bastion curates lightly, and only to fill the first screen. The catalog seeds
twenty-two entries — eleven servers written here, and eleven endpoints their own
vendors operate — because a catalog that opens with nothing recognisable in it
teaches nobody what the app is for. It is still not trying to be a directory:
Docker MCP Toolkit ships hundreds of curated servers, Anthropic ships MCPB
double-click install and an official registry, and anything not seeded here is
one npm package name or one URL away. The part worth building is the runtime
underneath: supervision, identity, and a record of what was called.

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

None of the catalog entries below are modern. The eleven children run an SDK
whose newest protocol is `2025-11-25`, and `server/discover` against one returns
`-32601` — the exact signal the spec names for recognising a legacy server. The
eleven remote entries carry that revision as a seeded starting point; ten of them
refuse `initialize` without a credential, so the first real handshake through a
profile is what measures each one, and Cloudflare Docs, which answers
unauthenticated, was measured at `2025-11-25`. Bastion is
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
- **Source** — `npm` is published, so Bastion can install it on demand.
  `remote` is somebody else's server at an https URL: nothing is installed, no
  process is started, and the Binary column is empty because there is none. (The
  manifest also allows `local`, a checkout named by `dev.json` in a Debug build,
  for a server not published yet; no catalog entry uses it today.)
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
| CloudKit | `cloudkit` | `cloudkit-mcp` | `mcp-cloudkit` (local) | `CLOUDKIT_ALLOW_WRITES` | 1 |
| [Reddit](https://github.com/mgcrea/mcp-reddit) | `reddit` | `reddit-mcp` | `@mgcrea/mcp-reddit` (npm) | `REDDIT_ALLOW_WRITES` | 1 |
| [X](https://github.com/mgcrea/mcp-x) | `x` | `x-mcp` | `@mgcrea/mcp-x` (npm) | `X_ALLOW_WRITES` | 2 |
| [UniFi Protect](https://github.com/mgcrea/mcp-unifi-protect) | `unifi-protect` | `unifi-protect-mcp` | `@mgcrea/mcp-unifi-protect` (npm) | `UNIFI_PROTECT_ALLOW_WRITES` | 3 |
| [UniFi Network](https://github.com/mgcrea/mcp-unifi-network) | `unifi-network` | `unifi-network-mcp` | `@mgcrea/mcp-unifi-network` (npm) | `UNIFI_ALLOW_WRITES` | 2 |
| [Stripe](https://docs.stripe.com/mcp) | `stripe` | — | `https://mcp.stripe.com` (remote) | `stripe_api_write`, `create_refund`, `stripe_report` (by name) | 1 |
| [Shopify](https://github.com/mgcrea/mcp-shopify) | `shopify` | `shopify-mcp` | `@mgcrea/mcp-shopify` (npm) | read-only | 1 |
| [OVHcloud](https://github.com/mgcrea/mcp-ovh) | `ovh` | `ovh-mcp` | `@mgcrea/mcp-ovh` (npm) | `OVH_ALLOW_WRITES` | 4 |
| [Keycloak](https://github.com/mgcrea/mcp-keycloak) | `keycloak` | `keycloak-mcp` | `@mgcrea/mcp-keycloak` (npm) | `KEYCLOAK_ALLOW_WRITES` | 2 |
| [npm](https://github.com/mgcrea/mcp-npm) | `npm` | `npm-mcp` | `@mgcrea/mcp-npm` (npm) | `NPM_ALLOW_WRITES` | 2 |
| [GitHub](https://github.com/github/github-mcp-server) | `github` | — | `https://api.githubcopilot.com/mcp/` (remote) | `actions_run_trigger`, `add_comment_to_pending_review`, `add_issue_comment`, `add_reply_to_pull_request_comment`, `assign_copilot_to_issue`, `assign_copilot_to_issue_with_intent`, `create_branch`, `create_gist`, `create_or_update_file`, `create_pull_request`, `create_pull_request_with_copilot`, `create_repository`, `delete_file`, `delete_repository`, `discussion_comment_write`, `dismiss_notification`, `fork_repository`, `issue_write`, `label_write`, `manage_notification_subscription`, `manage_repository_notification_subscription`, `mark_all_notifications_read`, `merge_pull_request`, `projects_write`, `pull_request_review_write`, `push_files`, `request_copilot_review`, `star_repository`, `sub_issue_write`, `unstar_repository`, `update_gist`, `update_pull_request`, `update_pull_request_branch` (by name) | 1 |
| [Notion](https://developers.notion.com/docs/mcp) | `notion` | — | `https://mcp.notion.com/mcp` (remote) | read-only | 1 |
| [Linear](https://linear.app/docs/mcp) | `linear` | — | `https://mcp.linear.app/mcp` (remote) | read-only | 1 |
| [Sentry](https://mcp.sentry.dev/) | `sentry` | — | `https://mcp.sentry.dev/mcp` (remote) | read-only | 1 |
| [Atlassian](https://github.com/atlassian/atlassian-mcp-server) | `atlassian` | — | `https://mcp.atlassian.com/v2/mcp` (remote) | read-only | 1 |
| [Figma](https://developers.figma.com/docs/figma-mcp-server/) | `figma` | — | `https://mcp.figma.com/mcp` (remote) | read-only | 1 |
| [Vercel](https://vercel.com/docs/agent-resources/vercel-mcp) | `vercel` | — | `https://mcp.vercel.com` (remote) | `deploy_to_vercel`, `use_vercel_cli`, `import-claude-design-from-url`, `buy_pro`, `buy_credits`, `buy_addon`, `buy_domain`, `change_toolbar_thread_resolve_status`, `reply_to_toolbar_thread`, `edit_toolbar_message`, `add_toolbar_reaction` (by name) | 1 |
| [Cloudflare](https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/) | `cloudflare` | — | `https://mcp.cloudflare.com/mcp` (remote) | read-only | 1 |
| [Cloudflare Docs](https://github.com/cloudflare/mcp-server-cloudflare/tree/main/apps/docs-ai-search) | `cloudflare-docs` | — | `https://docs.mcp.cloudflare.com/mcp` (remote) | read-only | 1 |
| [Cloudflare Observability](https://github.com/cloudflare/mcp-server-cloudflare/tree/main/apps/workers-observability) | `cloudflare-observability` | — | `https://observability.mcp.cloudflare.com/mcp` (remote) | read-only | 1 |
| [iOS Device](https://github.com/mgcrea/mcp-ios-device) | `ios-device` | `ios-device-mcp` | `@mgcrea/mcp-ios-device` (npm) | `IOS_DEVICE_ALLOW_WRITES` | — |

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

### CloudKit

CloudKit management API: container schema — record types, fields, Development/Production diff and deploy.

A separate service from App Store Connect, not a feature of it: different
host (api.icloud.apple.com), different credential (a static management
token, not a minted JWT), no field in common. An App Store Connect key
gives no access here and this token gives no access there — which is
the whole reason this is its own server rather than folded into
appstore-connect, where it lived for one commit before the split.

The API is undocumented. Every route was read out of the `cktool` binary
Xcode ships (`strings $(xcrun -f cktool)`); cloudkit_request is a
GET-by-default escape hatch for whatever that reading got wrong. The one
route it refuses even with writes on is the container's environment
reset — wipes all Development data — which is deliberately not a tool
at all, so exposing it through the escape hatch would defeat the point
of leaving it out.

cloudkit_deploy_schema always fetches and returns the pending diff before
promoting Development to Production, and refuses when there is nothing
to deploy. Production is additive-only forever once first deployed — a
field can be added, never removed, renamed or retyped — so that diff is
the one thing worth reading before confirm: true.

Local until published — npm 404s on @mgcrea/mcp-cloudkit today, so this
entry only resolves against a checkout under MCP_ROOT. docsUrl is null
for the same reason: the GitHub repo does not exist yet.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `CLOUDKIT_MANAGEMENT_TOKEN` | yes | yes | CloudKit management token, from icloud.developer.apple.com/dashboard/account/tokens — CloudKit Management Tokens. Can rewrite the container's schema; scope it and revoke when done. |
| `CLOUDKIT_TEAM_ID` | yes | — | 10-character Apple Developer team id, e.g. 75QE9PRT3V. Also in the app's exportOptions.plist. |
| `CLOUDKIT_CONTAINER_ID` | — | — | Default container, e.g. iCloud.io.mgcrea.Balise, so it need not be passed on every call. cloudkit_list_containers finds it if unset. |
| `CLOUDKIT_CONFIG` | — | — | Config file path. Bastion points this at the profile's own directory. |
| `CLOUDKIT_MAX_RETRIES` | — | — | Retry budget for 429/5xx responses. Defaults to 3. |
| `CLOUDKIT_ALLOW_WRITES` | — | — | Enables cloudkit_deploy_schema and cloudkit_import_schema. Both additionally require confirm: true on every call. |

Per-profile state: `CLOUDKIT_CONFIG`

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

Two write gates, not one: X_ALLOW_WRITES governs posting and
X_ADS_ALLOW_WRITES governs spending money. The manifest names the
first as the gate because that is the one the Activity window badges;
the second is an ordinary env entry that a profile sets deliberately.

X_MONTHLY_BUDGET_USD is here for the same reason a write gate is:
on this API a read has a price, so an unbounded profile is a bill.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `X_BEARER_TOKEN` | — | yes | App-only bearer token. Reads only; the Ads API rejects it outright. |
| `X_CLIENT_ID` | — | — | OAuth2 client id. Required for a user context, and therefore for writes and for Ads. |
| `X_CLIENT_SECRET` | — | yes | OAuth2 client secret, for a confidential client. |
| `X_REDIRECT_URI` | — | — | Loopback OAuth callback. Per-profile, or two profiles race for one port — and the URL must be registered with the X app. |
| `X_TOKEN_FILE` | — | — | Where the user token is stored. Per-profile, or two accounts share one login. |
| `X_CONFIG` | — | — | Config file path. Bastion points this at the profile's own directory. |
| `X_MONTHLY_BUDGET_USD` | — | — | Spend ceiling. X bills per read, so this is a real safety control, not a preference. |
| `X_ALLOW_WRITES` | — | — | Enables posting through the API rather than returning an intent URL. |
| `X_ADS_ENABLED` | — | — | Registers the Ads API tools. Needs a user context. Boolean — unset means off. |
| `X_ADS_ALLOW_WRITES` | — | — | Enables campaign mutations. No effect without X_ADS_ENABLED. Boolean — unset means off. |

Satisfy exactly one of: **App-only bearer token** (`X_BEARER_TOKEN`), **OAuth2 user context** (`X_CLIENT_ID`)

Per-profile state: `X_CONFIG`, `X_TOKEN_FILE`

Per-profile OAuth callback: `X_REDIRECT_URI` as `http://127.0.0.1:{port}/callback`

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

### npm

npm registry: packages, versions, downloads, advisories, dist-tags, orgs, tokens and trusted publishing.

No auth modes, and not because there is only one credential. This
server starts with NOTHING configured — every packument, search and
advisory read is public — and a mode has to name at least one
variable, which the zero-config path has not got. So the choice is
not a mode: either NPM_TOKEN is set, or the server reads ~/.npmrc.

Which is exactly why NPM_CONFIG_USERCONFIG is state. HOME is the real
home, so a profile that names no token quietly borrows the machine's
`npm login` — two profiles are then one npm user wearing two names,
and the audit line says which profile called, not who published. A
second identity points this at its own file, or sets NPM_TOKEN.

The writes worth naming are irreversible in npm's own terms, and the
gate is not the only thing standing in front of them: publish and
unpublish both offer a dry run, and everything irreversible also
wants an explicit `confirm: true`. npm demands a fresh one-time
password on every trusted-publisher endpoint, the READ included, so
unattended trust configuration is impossible by construction rather
than by policy.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `NPM_TOKEN` | — | yes | npm access token. Optional: with none set the server falls back to the token `npm login` wrote to ~/.npmrc. A granular token with 'Bypass 2FA' enabled is refused by every trusted-publisher write. |
| `NPM_REGISTRY` | — | — | Registry to talk to. Defaults to https://registry.npmjs.org, and the .npmrc token is looked up for whichever host this names, never sent to another. |
| `NPM_CONFIG_USERCONFIG` | — | — | Which .npmrc the fallback token is read from. Unset means the machine's own ~/.npmrc, which every profile would then share. |
| `NPM_MCP_CONFIG` | — | — | Config file path. Bastion already points the default at the profile's own directory; set this only to name a file elsewhere. |
| `NPM_OTP_MODE` | — | — | How the one-time password npm demands on every trusted-publisher call is obtained: web opens npm's confirmation page and waits, static uses NPM_OTP, none refuses with instructions. Defaults to web. |
| `NPM_OTP` | — | yes | A one-time password, and the only thing NPM_OTP_MODE=static will start without complaining about. Rarely right: a code lasts about five minutes, so one set at spawn is dead before anything calls a tool. |
| `NPM_AUTO_OPEN_BROWSER` | — | — | Whether the one-time-password flow launches a browser, or only prints the authorization URL. Boolean — unset means on. |
| `NPM_ALLOW_WRITES` | — | — | Registers the write tools: publish and unpublish, dist-tags, deprecation, package access, org and team membership, tokens, and trusted-publisher changes. |

Per-profile state: `NPM_CONFIG_USERCONFIG`, `NPM_MCP_CONFIG`

### GitHub

GitHub's own remote MCP server: repositories, issues, pull requests, Actions, code scanning and Dependabot alerts.

REMOTE. GitHub operates this one; Bastion holds the credential and the
audit line and forwards the call.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

WRITE TOOLS TAKEN FROM THE PUBLISHED TOOL TABLE, not from a live
tools/list - the endpoint 401s before it will enumerate. Thirty-three
names, and delete_repository is the one worth reading twice. The list is
belt and braces either way: Bastion also gates anything the server
annotates readOnlyHint:false, which is the half that caught three
quarters of Stripe's write surface.

The token is the real boundary, not the gate. A classic PAT with repo
scope reaches every repository the account can see, including private
ones in other organisations. Prefer a fine-grained token.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `GITHUB_TOKEN` | — | yes | `Authorization: Bearer {value}` | Personal access token, sent as the bearer token. Scope it to the repositories you actually want reachable: the write gate filters what Bastion forwards, it cannot take back a permission the token already grants. |

Hidden with writes off: `actions_run_trigger`, `add_comment_to_pending_review`, `add_issue_comment`, `add_reply_to_pull_request_comment`, `assign_copilot_to_issue`, `assign_copilot_to_issue_with_intent`, `create_branch`, `create_gist`, `create_or_update_file`, `create_pull_request`, `create_pull_request_with_copilot`, `create_repository`, `delete_file`, `delete_repository`, `discussion_comment_write`, `dismiss_notification`, `fork_repository`, `issue_write`, `label_write`, `manage_notification_subscription`, `manage_repository_notification_subscription`, `mark_all_notifications_read`, `merge_pull_request`, `projects_write`, `pull_request_review_write`, `push_files`, `request_copilot_review`, `star_repository`, `sub_issue_write`, `unstar_repository`, `update_gist`, `update_pull_request`, `update_pull_request_branch` — and any tool the server annotates as not read-only. This filters what Bastion forwards; it does not bind the server, so the credential's own scopes remain the real boundary.

Satisfy exactly one of: **Sign in with GitHub** (no variables — Bastion holds the token), **Personal access token** (`GITHUB_TOKEN`)

### Notion

Notion's own remote MCP server: search, read and update pages, databases and comments.

REMOTE. Its own discovery document calls it "Notion MCP (Beta)", so
expect the tool surface to move.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

NO writeTools LIST. The endpoint 401s before it will enumerate and
Notion publishes no stable tool table, so naming tools here would be
guesswork that silently matches nothing. Writes are gated by the
server's own readOnlyHint:false annotations instead. Say that out loud
in the UI rather than implying a hand-checked denylist exists.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `NOTION_TOKEN` | — | yes | `Authorization: Bearer {value}` | Internal integration token, sent as the bearer token. A Notion integration reaches only the pages explicitly shared with it, so the sharing list is the real boundary here. |

Satisfy exactly one of: **Sign in with Notion** (no variables — Bastion holds the token), **Integration token** (`NOTION_TOKEN`)

### Linear

Linear's own remote MCP server: issues, projects, cycles, comments and documents.

REMOTE. The cleanest OAuth story in this file: discovery advertises a
registration_endpoint, PKCE, and scopes_supported [read, write], so
Bastion's dynamic registration has everything it needs.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

THERE IS A READ-ONLY URL and this entry does not use it. Linear also
serves https://mcp.linear.app/mcp/readonly, where the SERVER enforces
what writeTools can only filter. One url per entry, so this is a real
fork in the road: point a second entry at it, or tell people who want
writes off to use a key scoped to read. Worth deciding rather than
leaving to whoever reads this next.

NO writeTools LIST - 401 before enumeration, same as the others. The
annotation gate carries it.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `LINEAR_API_KEY` | — | yes | `Authorization: Bearer {value}` | Linear API key, sent as the bearer token. Linear issues read and write as separate OAuth scopes, so a key minted for reads is a stronger control than the write gate. |

Satisfy exactly one of: **Sign in with Linear** (no variables — Bastion holds the token), **API key** (`LINEAR_API_KEY`)

### Sentry

Sentry's own remote MCP server: issues, events, releases and Seer analysis across your organisations.

REMOTE. docs.sentry.io/product/sentry-mcp/ 301s to mcp.sentry.dev,
which is both the server and its documentation, so docsUrl points
there.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

NO writeTools LIST. Sentry documents permission scopes rather than a
tool table, so there is nothing to copy that would not be invented.
The annotation gate is what is actually holding writes here.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `SENTRY_ACCESS_TOKEN` | — | yes | `Authorization: Bearer {value}` | Sentry user auth token, sent as the bearer token. Its own scopes decide what is reachable; project:write and event:write are the ones to leave off unless something needs them. |

Satisfy exactly one of: **Sign in with Sentry** (no variables — Bastion holds the token), **User auth token** (`SENTRY_ACCESS_TOKEN`)

### Atlassian

Atlassian's own Rovo MCP server: Jira, Confluence, Jira Service Management, Bitbucket and Compass.

REMOTE. v2 is the current path - anything still pointing at
mcp.atlassian.com/v1/sse is on a version Atlassian has retired.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

ONLY THE SERVICE ACCOUNT KEY IS OFFERED, and that is deliberate.
Atlassian takes two token shapes: a service account API key as
`Authorization: Bearer <key>`, which fits a header format cleanly, and
a personal API token as `Authorization: Basic <base64(email:token)>`,
which would make the user paste a base64 blob they had to build
themselves. Personal-token users should sign in with OAuth instead.

Permissions are grouped upstream (read_jira, write_jira, delete_jira
and so on) and delete_jira and manage_jira are admin-enabled and off by
default, so most accounts cannot reach the destructive half at all.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `ATLASSIAN_API_KEY` | — | yes | `Authorization: Bearer {value}` | Service account API key, sent as the bearer token. An organisation admin must enable API token authentication before any key works; if that is off, OAuth is the only way in. |

Satisfy exactly one of: **Sign in with Atlassian** (no variables — Bastion holds the token), **Service account API key** (`ATLASSIAN_API_KEY`)

### Figma

Figma's own remote MCP server: design file context, components and variables for coding agents.

REMOTE. Figma also ships a local server that talks to the desktop app;
this entry is the hosted one, which is the one Figma recommends.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

THE TOKEN HEADER IS THE UNCERTAIN PART. Figma's REST API authenticates
with X-Figma-Token, not a bearer token, and the MCP endpoint's own
challenge asks for Bearer. Bearer is what is written here because that
is what the endpoint asked for, but it is untested against a real
token. If it is refused, the fix is one header format, not an entry.

NO writeTools LIST. Mostly a read surface, and 401 before enumeration.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `FIGMA_ACCESS_TOKEN` | — | yes | `Authorization: Bearer {value}` | Figma personal access token, sent as the bearer token. Note that Figma's REST API takes its tokens in X-Figma-Token instead; if this path is refused, sign in with OAuth. |

Satisfy exactly one of: **Sign in with Figma** (no variables — Bastion holds the token), **Personal access token** (`FIGMA_ACCESS_TOKEN`)

### Vercel

Vercel's own remote MCP server: projects, deployments, runtime logs, Web Analytics and documentation search.

REMOTE. Its discovery document points authorization_servers at
vercel.com rather than at itself, so the OAuth dance leaves the MCP
host entirely.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

VERCEL SAYS IT SUPPORTS 2026-07-28. Their changelog announces it, which
would make this the first entry in the file that is modern rather than
legacy. It is NOT written into dialect above, because a handshake that
proposes a version the server does not take fails the connection, and
nothing here has proved it. Measure it, then raise this field - that
order round the wrong way is an outage.

THIS ONE SPENDS MONEY. buy_pro, buy_credits, buy_addon and buy_domain
are real tools on a real payment method, and deploy_to_vercel and
use_vercel_cli change what is serving production. All eleven are named
in writeTools, taken from Vercel's published tool table.

VERCEL ALLOWLISTS CLIENTS. Their documentation says the server "only
supports AI clients that have been reviewed and approved by Vercel" and
names twelve; Bastion is not among them. Dynamic registration may
simply be refused, in which case the access-token mode is the way in
and this is worth an approach to Vercel rather than a workaround.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `VERCEL_TOKEN` | — | yes | `Authorization: Bearer {value}` | Vercel access token, sent as the bearer token. Scope it to one team if you can - this server can deploy code and spend money, and the token's own scopes are the only thing that stops it. |

Hidden with writes off: `deploy_to_vercel`, `use_vercel_cli`, `import-claude-design-from-url`, `buy_pro`, `buy_credits`, `buy_addon`, `buy_domain`, `change_toolbar_thread_resolve_status`, `reply_to_toolbar_thread`, `edit_toolbar_message`, `add_toolbar_reaction` — and any tool the server annotates as not read-only. This filters what Bastion forwards; it does not bind the server, so the credential's own scopes remain the real boundary.

Satisfy exactly one of: **Sign in with Vercel** (no variables — Bastion holds the token), **Access token** (`VERCEL_TOKEN`)

### Cloudflare

Cloudflare's own remote MCP server: the API surface across zones, DNS, Workers, R2 and the rest of the account.

REMOTE. Cloudflare runs seventeen separate hosted endpoints rather than
one; three of them are in this catalog - the API surface here, the
documentation search, and observability. The other fourteen (Radar,
Workers Bindings, Workers Builds, Browser Run, AI Gateway, Logpush,
GraphQL, DNS Analytics, Audit Logs, Container, AI Search, DEX, CASB and
the Agents SDK docs) are the same shape if anyone wants them.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

THE BROADEST SURFACE IN THE FILE. Cloudflare advertises this one as
2,500+ API endpoints, which is most of an account behind a single
credential. The token's permissions are the boundary; the gate is not.

NO writeTools LIST - 401 before enumeration. The annotation gate holds
writes, and on a surface this wide that is worth stating plainly to
anyone about to turn the gate off.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | — | yes | `Authorization: Bearer {value}` | Cloudflare API token, sent as the bearer token. Mint it against the specific zones and permissions you want reachable rather than reusing an account-wide token. |

Satisfy exactly one of: **Sign in with Cloudflare** (no variables — Bastion holds the token), **API token** (`CLOUDFLARE_API_TOKEN`)

### Cloudflare Docs

Cloudflare's documentation search, as a remote MCP server. Needs no credential.

REMOTE, and the only entry in this file that needs no credential at
all. A POST of `initialize` with no Authorization header returns 200.
So authModes is empty, the way Shopify's is, and for the same reason:
there is nothing to authenticate.

DIALECT MEASURED 2026-09-02, and it is the only one in this batch that
is. An unauthenticated handshake negotiates 2025-11-25 and serverInfo
reports docs-ai-search 0.4.13. Every other endpoint added alongside it
401s before it will say, and carries a seeded value instead.

TOOL LIST MEASURED 2026-09-02 as well, and it is read-only: exactly two
tools, search_cloudflare_documentation and migrate_pages_to_workers_guide,
both annotated readOnlyHint:true. There is no write surface to gate.

Bastion still counts this entry as HAVING a write path, and that is not a
bug - "read-only" is not a claim the app can make about a remote server in
advance, so hasWritePath says yes for every remote entry. Over-reporting is
the safe direction and this note is the only place the difference is
written down.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `CLOUDFLARE_DOCS_TOKEN` | — | yes | `Authorization: Bearer {value}` | Not needed. This server answers unauthenticated, and a remote entry has to declare at least one variable somewhere for a value to land; leave it empty. |

### Cloudflare Observability

Cloudflare Workers logs and analytics, as a remote MCP server: query invocations, errors and traces.

REMOTE. A narrow read surface next to the full Cloudflare API entry:
Workers logs, analytics and traces, which is what you want open during
an incident without opening the account with it.

DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
in this family that answers unauthenticated actually negotiates. Every
other one 401s before it will say, so this number is a starting point and
not a measurement - RemoteInstance logs `dialect drift` on the first real
handshake and Activity shows what was negotiated. Correct this field from
that line. Stripe is the reason the distinction is written down: it was
carried at the default until a handshake proved it two revisions older.

Its own variable rather than sharing CLOUDFLARE_API_TOKEN with the API
entry, because these are separate profiles against separate servers and
a token minted for reading logs should not have to be the token that
can edit DNS.

| Variable | Required | Secret | Sent as | Meaning |
| --- | --- | --- | --- | --- |
| `CLOUDFLARE_OBSERVABILITY_TOKEN` | — | yes | `Authorization: Bearer {value}` | Cloudflare API token with Workers Observability read access, sent as the bearer token. |

Satisfy exactly one of: **Sign in with Cloudflare** (no variables — Bastion holds the token), **API token** (`CLOUDFLARE_OBSERVABILITY_TOKEN`)

### iOS Device

Drive a physical iPhone or iPad: screenshot, accessibility tree, tap, swipe, type, and app lifecycle.

No credentials, so no auth modes. What authorises this server is the trust
relationship between this Mac and the phone - pairing, Developer Mode, and
the separate Enable UI Automation toggle - none of which passes through a
profile. That is also why there is no auth_status tool to name here.

Two lanes reach the device and they fail independently. `xcrun devicectl`
covers app lifecycle and needs nothing installed on the phone; everything
that sees or touches the screen goes through a WebDriverAgent runner the
user builds and starts themselves, reached over the IPv6 tunnel CoreDevice
already maintains. ios_device_diagnostics reports both separately, so
'the device is fine, the runner is not up' is a distinguishable answer.

The write gate is unusually load-bearing here. With it on, a model can tap
anything on an unlocked phone in someone's hand. IOS_DEVICE_LAUNCH_ARGS is
the mitigation worth setting beside it: it pins the app under test into a
fixture mode by default rather than its owner's real account.

Published 2026-09-04 at 0.1.0, with a SLSA provenance attestation from the
tag-triggered CI job over OIDC. A 0.0.0 placeholder sits below it on npm:
OIDC cannot create a package name, so the name had to be claimed by hand
before CI could publish anything. Do not install that one.

The package ships a second binary, ios-device-wda, which builds and starts
the WebDriverAgent runner. Bastion does not run it - it is a one-off the user
invokes themselves, and the screen tools stay unavailable, and say so, until
they have.

| Variable | Required | Secret | Meaning |
| --- | --- | --- | --- |
| `IOS_DEVICE_ID` | — | — | CoreDevice identifier, UDID or name of the device to drive. Unset uses the only connected device; two connected and no value is an error that names them. |
| `IOS_DEVICE_WDA_URL` | — | — | Explicit WebDriverAgent URL. Unset derives it from the device's CoreDevice tunnel, which is the normal path and needs no port forwarding. |
| `IOS_DEVICE_LAUNCH_ARGS` | — | — | Launch arguments applied when a launch passes none, e.g. -CanopyDemoMode to open fixtures instead of the owner's real account. |
| `IOS_DEVICE_OUTPUT_DIR` | — | — | Where saved screenshots and pulled app containers land. Defaults to a directory under TMPDIR. |
| `IOS_DEVICE_ALLOW_WRITES` | — | — | Enables the nine tools that drive the device: tap, tap_element, swipe, type, press_button, install, launch, terminate, pull_container. |

Per-profile state: `IOS_DEVICE_OUTPUT_DIR`
<!-- </generated:servers> -->
