# Clients

`docs/servers.md` describes what Bastion runs and `docs/remote-servers.md` the
transport under the remote half of it. This describes the other end: the four
MCP clients Bastion knows how to configure, why they do not all get the same
entry, and what the client pane can and cannot tell you about a file it does not
own.

## The four clients

| Client         | Config                                                            | Root key     | Transport |
| -------------- | ----------------------------------------------------------------- | ------------ | --------- |
| Claude Code    | `~/.claude.json`                                                  | `mcpServers` | HTTP      |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers` | bridge    |
| VS Code        | `~/Library/Application Support/Code/User/mcp.json`                | `servers`    | HTTP      |
| Cursor         | `~/.cursor/mcp.json`                                              | `mcpServers` | HTTP      |

Two disagreements shape the whole design, and neither is Bastion's to fix.
Clients disagree about **where servers live** in the file — `mcpServers` here,
`servers` there — and they disagree about **whether they can reach a URL at
all**.

VS Code's path is `User/mcp.json`, deliberately not `User/settings.json`.
settings.json is JSONC: it has comments and trailing commas, and round-tripping
it through `JSONSerialization` would silently delete every comment in a file the
user hand-wrote. mcp.json is strict JSON and is where VS Code keeps MCP servers
anyway.

## Why Claude Desktop gets a bridge

Three clients get a URL and no child process of their own:

```json
{
  "type": "http",
  "url": "http://127.0.0.1:8720/s/prod/stripe",
  "headers": { "Authorization": "Bearer …" }
}
```

Claude Desktop gets `bastion-bridge` instead, spawned per server:

```json
{
  "command": "…/Bastion.app/Contents/Helpers/bastion-bridge",
  "args": ["--profile=prod", "--server=stripe"],
  "env": { "BASTION_TOKEN": "…" }
}
```

**Both doors to a URL are closed, and only one of them is visible from the file.**

1. `claude_desktop_config.json` is validated against a **stdio-only schema**.
   Entries need a `command`; `type: "http"` and `url` fail validation. This is
   the door the config file shows you, and it is the reason the ecosystem
   converged on `npx mcp-remote <url>` as a stdio shim — the same shape as
   `bastion-bridge`, arrived at for the same reason.

2. Claude Desktop **does** reach remote MCP servers, through Custom Connectors
   (Settings → Connectors), which take a URL. But Claude connects to a custom
   connector **from Anthropic's cloud infrastructure rather than from the local
   device**, across every client — the server has to be reachable from
   Anthropic's public IP ranges. `http://127.0.0.1:8720` is unreachable by
   construction.

So the bridge is not the current best option for Claude Desktop pending better
support upstream. It is the **only** option, and door 2 is the one that keeps it
that way regardless of what Claude Desktop adds next: Bastion's gateway is
loopback-only, and that is the security posture rather than an implementation
detail. Anyone proposing to retire the bridge has to answer door 2 first.

Verified against Anthropic's help centre on 2026-08-31:
[getting started with custom connectors](https://support.anthropic.com/en/articles/11175166-getting-started-with-custom-connectors-using-remote-mcp),
[building custom connectors](https://support.anthropic.com/en/articles/11503834-building-custom-connectors-via-remote-mcp-servers).

The bridge itself is thin, and `apps/apple/BastionBridge/main.swift` opens with
why. It holds no credential beyond the token it is handed, opens no protected
path, and makes exactly one kind of network call: a POST to `127.0.0.1`. The
supervised child, the Keychain and the audit record are all on the far side of
it. It is **not** a byte pump — HTTP is request/response, so each JSON-RPC frame
has to be recognised, sent as its own POST and matched back to a reply, which is
why it reads frames rather than chunks.

### One failure mode the pane cannot see

Newer Claude Desktop builds are reported to respond to a config that fails
validation by **silently dropping the entire `mcpServers` map on load** — so one
hand-added HTTP entry takes every valid stdio entry with it, Bastion's included.
This is from community writeups rather than official documentation, so treat it
as likely rather than certain.

Bastion only ever writes valid stdio entries into that file and so cannot cause
it. What matters is that Bastion also cannot **detect** it: the file on disk
still audits as `configured` while Claude Desktop is running none of it. If
Claude Desktop shows no Bastion tools against a green pane, this is the first
thing to check, and `claude_desktop_config.json.bastion-backup` is the recovery
path.

## What goes in the file, and what never does

The entry carries a **bearer token issued to that client**. It never carries a
credential. That split is what makes writing somebody else's config defensible
at all: what leaks if the file leaks is a revocable loopback token, not a
brokerage refresh token.

One token per client, minted once and **reused** rather than reminted. Minting
replaces the Keychain item, and every config already carrying the old token would
stop working — so re-running _Configure_ to pick up a newly added server would
silently break the entries it was not touching.

The key an entry is filed under is `<prefix><server>`, where the prefix is the
`clientKeyPrefix` setting and is **empty by default**. It used to be a hard-coded
`bastion-`, which is Bastion's opinion imposed on a file somebody else owns, and
it is not free: the key becomes part of every tool name the model reads, so a
`shopify` entry is `mcp__bastion_shopify__…` for as long as the config lives. A
second profile of the same server would collide, so both then carry the profile
name — decided across the whole set rather than per entry, so the key for
`shopify` does not change shape depending on which profiles happen to be
selected.

## Recognising Bastion's own entries

`isOurs` is the load-bearing predicate: it decides what _Remove Bastion's
entries_ takes out, what a rename may clean up, and what the app refuses to
touch. It is deliberately **narrow**, and deliberately **not** compared against
the current bridge path or port:

- A `command` ending in `/Contents/Helpers/bastion-bridge` — wherever the bundle
  was at the time. An entry left by a copy that has since moved is exactly the
  one worth cleaning up, and refusing to recognise it would leave a dead entry in
  somebody's config forever.
- A URL matching the endpoint grammar exactly: a loopback host (`127.0.0.1`,
  `localhost`, `::1`) and exactly `/s/<profile>/<server>`. A loopback URL that is
  not two segments under `/s/` is somebody else's local server, and Bastion has
  no business rewriting it.

Everything else is somebody else's, permanently.

## What the client pane reports

The pane re-reads the config on **every redraw** and caches nothing. The file
belongs to another application that may have rewritten it a second ago, so a
remembered status is a claim about a file this app did not watch. It is one read
per pass, though, feeding every panel — the status, the per-entry badges and both
foreign lists used to be independent reads, each free to disagree with the
others.

### Per entry

| Badge              | Meaning                                                      | Remedy                           |
| ------------------ | ------------------------------------------------------------ | -------------------------------- |
| `configured`       | Ours, pointing where it should.                              | —                                |
| `not written`      | No entry under that key.                                     | _Configure_                      |
| `points elsewhere` | Ours, but at a previous build, port, or the other transport. | _Configure_ rewrites it.         |
| `taken`            | Present, and **not** ours.                                   | Change the prefix, or remove it. |

The distinction between the last two is the whole point. `points elsewhere` is a
drifted copy of ours and the remedy is to write over it; `taken` is somebody
else's server, and writing over it **is** the damage. An entry of the wrong
_shape_ is stale too — a config wired before the bridge existed holds an HTTP
entry, and that is precisely the one worth rewriting.

The header sentence is the same per-entry states reduced, in this precedence:
collides ▸ stale ▸ not configured (when _all_ are missing) ▸ incomplete ▸
configured. Header and badges are two renderings of one computation, which is how
they are kept from disagreeing about a file neither of them owns.

### The servers Bastion did not write

Every key under the root that `isOurs` does not claim is listed, with what it
points at. These are the servers the client starts itself: no Bastion token, no
per-profile write gate, and nothing they do reaches the activity log. Listing
them is the point of the app stated against somebody's actual config.

Claude Code additionally keeps a servers object **per project folder**, and on a
machine that has been using MCP for a while that is where most of the un-migrated
servers live — ninety-eight folders in the file this was written against. Those
get their own card, grouped by folder, because they are a different scope with a
different remedy: a project server is wired for one folder and invisible
everywhere else, which is exactly why they accumulate.

A folder with no `mcpServers` key and a folder with an empty one are **different
statements** and do not collapse into one. The first is a folder nobody has
wired; the second was wired and then emptied.

### Removing one

_Remove…_ on a foreign entry takes out exactly that key, after an alert naming
it, its scope and the backup. It **refuses** any key `isOurs` claims — removing
Bastion's own entries is _Remove Bastion's entries_, which knows about the whole
set, and the two paths must not be able to do each other's job by accident.
Emptying a servers object leaves it `{}` rather than deleting the key.

## Writing into somebody else's file

Three properties, because the file is not Bastion's:

1. **Every unrelated key survives.** `~/.claude.json` on the machine this was
   written against holds nine global MCP servers, ninety-eight project blocks and
   seventy-five other top-level keys; Claude Desktop's carries seven entries plus
   `coworkUserFilesPath` and `preferences`. All of it has to come back
   byte-identical from a write that adds one key.
2. **The previous contents are recoverable** — copied to
   `<name>.bastion-backup` first.
3. **A crash mid-write cannot leave a truncated config.** Written to a temp file
   beside the target, then swapped. The result is `chmod 0600`, because it now
   carries a bearer token and did not necessarily before.

Bastion declines to write for exactly two reasons, both about a file it does not
own and neither recoverable by trying again: a key it would write is already
taken by an entry it did not write, or two profiles reduce to one key. The second
was unreachable while the prefix was a constant and became reachable the moment
it could be typed by hand; refusing beats writing one entry and leaving the other
profile silently unwired.

Nested writes read-modify-write the two dictionaries explicitly rather than
subscripting through them. Swift dictionaries are value types, and the obvious
`root["projects"]![folder]!["mcpServers"]` chain edits copies — a write that
appears to succeed and changes nothing.

## What asserts what

|                          |                                                                                                                                                                                                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make wiring-check`      | The merge, the audit, per-entry state, the foreign listings and single-key removal, against fixtures shaped like the real files. No app, no I/O beyond a temp directory.                                                                                         |
| `make wiring-check-real` | The same properties against **your actual** Claude Code, Claude Desktop and VS Code configs. Read-only: parsed, merged and pruned in memory, then compared. Fixtures only cover the shapes somebody thought of; this covers the ones nobody would have invented. |

`ClientWiringMerge.swift` imports nothing but Foundation precisely so those two
targets can compile it beside `scripts/wiring-check.swift` and run the result —
which is the whole test story for a project with no test target. Everything
policy-shaped — which clients exist, where their configs live, which key and
which transport each gets — stays in `ClientWiring.swift`, which can keep
importing AppKit.
