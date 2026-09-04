# Clients

`docs/servers.md` describes what Bastion runs and `docs/remote-servers.md` the
transport under the remote half of it. This describes the other end: the seven
MCP clients Bastion knows how to configure, why they do not all get the same
entry, and what the client pane can and cannot tell you about a file it does not
own.

## The seven clients

| Client          | Config                                                            | Root key      | Format | Transport  |
| --------------- | ----------------------------------------------------------------- | ------------- | ------ | ---------- |
| Claude Code     | `~/.claude.json`                                                  | `mcpServers`  | JSON   | HTTP       |
| Claude Desktop  | `~/Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers`  | JSON   | bridge     |
| VS Code         | `~/Library/Application Support/Code/User/mcp.json`                | `servers`     | JSON   | HTTP       |
| Cursor          | `~/.cursor/mcp.json`                                              | `mcpServers`  | JSON   | HTTP       |
| LM Studio       | `~/.lmstudio/mcp.json`                                            | `mcpServers`  | JSON   | **bridge** |
| Windsurf        | `~/.codeium/windsurf/mcp_config.json`                             | `mcpServers`  | JSON   | **bridge** |
| ChatGPT & Codex | `~/.codex/config.toml`                                            | `mcp_servers` | TOML   | HTTP       |

Three disagreements shape the whole design, and none is Bastion's to fix.
Clients disagree about **where servers live** in the file — `mcpServers` here,
`servers` there, `mcp_servers` in a third — about **what the file is written
in**, and about **whether they can reach a URL at all**.

The last row is one client rather than three: the ChatGPT desktop app, the Codex
CLI and the Codex IDE extension all read that same file. Three rows would mean
three gateway tokens overwriting each other in it, and an unwire of any one of
them taking the other two out.

VS Code's path is `User/mcp.json`, deliberately not `User/settings.json`.
settings.json is JSONC: it has comments and trailing commas, and round-tripping
it through `JSONSerialization` would silently delete every comment in a file the
user hand-wrote. mcp.json is strict JSON and is where VS Code keeps MCP servers
anyway. Codex has no equivalent escape — its servers live in the same file as
everything else it is configured with — which is what [the one TOML
client](#the-one-toml-client) is about.

The last two arrived from Cupertino, which had them first and which this list is
otherwise kept in step with. Both get the bridge, and neither for Claude
Desktop's reason — they get it because nobody has _checked_ that they take a
URL in the shape this app writes.

LM Studio demonstrably reaches remote servers: the config it was added from
holds three. But all three are a bare `url` with no `type` beside it and no
header anywhere in the file, and the entry Bastion writes for `.http` is `type`,
`url` and `headers` — so the token-carrying half is the unverified half.
Windsurf was not installed at all, and its documented remote shape is a
`serverUrl` key this app does not write.

The asymmetry is the point: a bridge entry spawns a process, which is a cost. An
HTTP entry a client silently ignores is a client that does not work, with nothing
on either side saying why. Either row moves to `.http` the moment somebody
watches a header carry a token into it.

## What a client pays to be wired at all

Every client wired to a profile is sent every tool definition that profile's
server exposes, before it can call one, and holds them for the whole
conversation. That is the largest fixed charge a shared gateway imposes:
`prod/appstore-connect` is 85 tools and about 26.2k tokens per connect. The
profile row in the window carries the figure, so it is readable rather than
inferred.

Some clients already handle this themselves. Claude Code defers a tool's schema
until something reaches for it, so its window holds the names and almost nothing
else. Claude Desktop, and most editors, do not — they take the whole listing on
connect and there is nothing the user can do about it from that side.

**Load tools on demand** (Settings › General, with a per-profile override under
Context) is Bastion's answer for the clients that cannot. With it on, a client is
served three tools instead of the server's own:

| Tool                    | What it does                                                              |
| ----------------------- | ------------------------------------------------------------------------- |
| `bastion_search_tools`  | Names and one-line summaries, filtered by a query; empty lists everything |
| `bastion_describe_tool` | One tool's full input schema, by exact name                               |
| `bastion_call_tool`     | Runs one, by name and arguments                                           |

`prod/appstore-connect` becomes three tools and about 0.4k tokens on connect,
with the full index costing about 3.2k only if something asks for it. Nothing
becomes unreachable, and a client still holding a pre-toggle list keeps working:
a real tool name is forwarded as it always was.

MCP has no method for fetching a schema later — `inputSchema` is required in a
`tools/list` entry — so an index and a dispatcher is the only shape lazy
discovery can take. Doing it in the gateway rather than buying a facade server
is what keeps it honest: Bastion opens `bastion_call_tool` back up into the
`tools/call` it stands for before the audit chain, the Activity window or the
write gate sees the frame, so all three go on naming the real tool.

**What it costs is on the client's side.** Every call arrives at the editor as
`bastion_call_tool`, so a per-tool approval rule there — Claude Code's
`mcp__appstore-connect__app_store_connect_update_app`, say — collapses into one
rule covering every tool on that server. Bastion's own gate is unaffected: a
write tool is still absent from the index and still refused by the dispatcher
for a profile with writes off. But the editor's gate is coarser, which is why it
is off by default.

The switch is app-wide because the answer is usually the same for every profile
on one machine. It is overridable per profile because it is not always: a profile
wired to Claude Code should be set to off there, since Claude Code defers tool
schemas by itself and so gains nothing while still paying the coarser approval
rule. A profile that has expressed no preference follows the app-wide setting,
which is the same tri-state **Record** uses one section further down.

## Why Claude Desktop gets a bridge

Four clients get a URL and no child process of their own:

```json
{
  "type": "http",
  "url": "http://127.0.0.1:8720/s/prod/stripe",
  "headers": { "Authorization": "Bearer …" }
}
```

Codex takes a URL too, in its own spelling — no `type`, because a `url` is what
makes an entry streamable HTTP there, and `http_headers` because that is the
field that takes a literal token (`bearer_token_env_var` names an environment
variable, and Bastion has no way to put one in Codex's environment):

```toml
[mcp_servers.stripe]
url = "http://127.0.0.1:8720/s/prod/stripe"
http_headers = { Authorization = "Bearer …" }
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

## The one TOML client

Four of the five configs are JSON and are serialised from a dictionary, which is
safe because the files hold nothing but data. `~/.codex/config.toml` is not like
that. On the machine this was written against it carries twenty-seven
`[projects."…"]` tables, a `[features]` block, a `[shell_environment_policy.set]`
table and a multi-line string full of markdown — hand-written structure and
prose, with the MCP servers a small part of it.

So there is no TOML library here, and that is the same objection that keeps VS
Code on `mcp.json`: **round-tripping somebody's hand-written file through any
serialiser reformats it and deletes its comments.** `ClientWiringTOML` instead
locates the lines that hold MCP servers, replaces those, and quotes every other
byte of the file verbatim. A wire against the real config produces a `diff` with
one hunk in it, and that hunk is a pure addition.

### The invariant

> The scanner may fail to **describe** a server. It must never fail to **name**
> one.

A server it could see but not parse still appears in the servers dictionary,
which makes `isOurs` false, which makes `collisions` refuse to write over it. If
it were dropped instead, `collisions` would see nothing in the way, a wire would
append a second `[mcp_servers.<name>]`, and **a duplicate key does not cost one
entry — it makes the whole file fail to parse**, taking every server and every
project trust level with it. That is a read bug with a catastrophic write
consequence, and it is why extents and values are two different jobs:

- The **lexer** decides where a table starts and stops. It may refuse, and a
  refusal makes the client read as `unreadable` — which makes every write path
  refuse too, because they all begin with a read.
- The **value parser** is best effort and never refuses. A value it cannot type
  is omitted rather than guessed; `identity` returning nothing is already a case
  the pane knows how to render.

It refuses a dotted key under `[mcp_servers]`, an array of tables, a multi-line
inline table, an unterminated string and non-UTF-8 bytes, naming the line —
because the remedy for each is a person looking at it.

### What a span is

A server's lines run from its `[mcp_servers.<name>]` header to the last line
under it that says something, **not** to the next header. The blank line and the
comment above the next table belong to the next table, which is what stops an
unwire eating somebody's section separator. Leading comments are never part of a
span either: an unwire may leave an orphan comment, which is strictly better
than deleting a user's prose. A server can own more than one span —
`[mcp_servers.node_repl.env]` is a second one — and removing the server takes
both.

New blocks land just past the last `mcp_servers` span in the file, counting the
ones about to be deleted. Counting those too is what puts a second wire in the
same place as the first, and it groups Bastion's entries with the servers
already there rather than stranding them past an unrelated table.

A deleted block takes the blank line above it, and a written block always puts
one back — even when one is already there. Insertion and deletion are then exact
inverses, which is what makes **wire → unwire return the original bytes**. The
conditional version was prettier by one blank line and ate a blank line the user
had written.

One case cannot round-trip exactly, and it is worth stating rather than glossing:
a file with **no final newline** has to gain one before anything can be appended,
and an unwire has no way to know that newline was Bastion's.

### Two traps worth naming

Swift's `"\r\n"` is **one** `Character` — a grapheme cluster — so `c == "\n"` is
false for a CRLF break and `hasSuffix("\n")` is false for a CRLF-terminated
string. An early version read a whole CRLF file as a single line, found no
servers in it, and appended blocks to the end of what it thought was line one.
There is one named definition of what ends a line now.

And the file's multi-line string of markdown sits directly above the first
server. Prose is allowed to contain a `[` at column 0, a `#`, and the words of a
table header. A line scanner that does not track `"""` and `'''` mints servers
out of somebody's commit-message notes and then deletes the lines it invented.

### What the ChatGPT app does to this file

The ChatGPT desktop app **rewrites `config.toml` on launch**, and is reported to
set `enabled = false` on a server it did not expect
([openai/codex#34807](https://github.com/openai/codex/issues/34807)). Three
consequences, none of them fatal:

- **Formatting.** Bastion's guarantee is one-directional: _Bastion_ does not
  reformat this file. If the ChatGPT app serialises and rewrites it, comments and
  ordering are lost and that is not Bastion's doing — but
  `config.toml.bastion-backup` is then a snapshot of the last pre-rewrite
  formatting and will be stale. Codex CLI users who never launch the desktop app
  get the full guarantee.
- **Spans moving.** Harmless. Every read rescans and nothing is cached.
- **`enabled = false` landing on one of ours.** This is the real one. The entry
  still points where it should, so `isOurs` still claims it and the audit still
  says `configured` while Codex runs none of it — the Claude Desktop blind spot
  above, **except detectable**, because the fact is a key in the file rather than
  something done quietly at load. The row says so, and says the remedy:
  _Configure_ re-renders the whole block from the entry Bastion builds, and
  `enabled` is not in it.

### Per-project `.codex/config.toml` is deferred

Codex also reads a `.codex/config.toml` inside a repository, closest to the
working directory, above the global file. Bastion does not touch it, for three
reasons of increasing weight:

1. The project-scope code is Claude Code's shape — `projects[folder].mcpServers`
   inside the one file Bastion already opens. Codex's `[projects."…"]` tables
   carry `trust_level`, **not servers**; all twenty-seven in the real file do.
   Reading them as an MCP project scope would be a straightforward lie, so the
   pane renders no projects card for Codex rather than an empty one.
2. Codex's project scope is a directory-tree lookup, not an index. Listing it
   would mean crawling the filesystem for `.codex/config.toml` files, and there
   is no UI here that names a folder.
3. The decisive one: **`.codex/config.toml` lives inside a repository, and
   Bastion writes a bearer token.** The whole defence of writing somebody else's
   config is that what leaks is a revocable loopback token rather than a
   brokerage refresh token. That holds for a file in `$HOME`. It does not hold
   for a file one `git add -A` from a public commit.

The only defensible version of this is `bearer_token_env_var = "BASTION_TOKEN"`,
which puts a _name_ rather than a secret in the committed file. It needs the user
to export the variable themselves, so it is a real feature with real onboarding
rather than a scope tweak — and that, not convenience, is the condition under
which this becomes worth doing.

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

Note what is **not** in that list: `type`. Nothing in the policy layer reads it,
which is why a Codex entry — `url` and `http_headers`, no `type` — flows through
`isOurs`, `target`, the audit, the collision check and the merge without any of
them learning the file is TOML. The format shows up in exactly two places: the
function that opens the file, and the one that writes it.

## Which clients are shown

Knowing how to configure a client and having it installed are different facts,
and only the second is about this Mac. The sidebar lists the installed ones and
drops the whole _Clients_ section when there are none: a row that cannot be acted
on is a support burden with no action attached, and nobody needs to be told their
Mac is missing an editor they never wanted. `isInstalled` asks LaunchServices
first, so an editor in `~/Applications` or on a second volume counts, and falls
back to the config directory for the two clients that are a command rather than
an app.

`list_clients` filters the same way and then says what it left out:

```json
{
  "clients": [{ "id": "claude-code", "installed": true, "status": "configured" }],
  "not_installed": ["cursor", "windsurf"],
  "note": "Not on this Mac, so not listed: Cursor, Windsurf. Bastion can still wire any of them; pass include_not_installed for their rows."
}
```

Named rather than dropped, which is the one place this parts company with the
sidebar. A window can afford to say nothing about an absent client, because the
person reading it knows what they have installed. An agent does not, and one that
cannot see `cursor` anywhere will report Bastion as unable to configure Cursor
rather than reporting Cursor as absent. `include_not_installed` gives the full
rows back.

Neither filter narrows what can be wired. `wire_client` resolves against the
whole list, so wiring a client before installing it works and writes the config
it will read on first launch.

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
| `server off`       | Ours, and its server is switched off in Bastion.             | Switch the server back on.       |

The distinction between the last two is the whole point. `points elsewhere` is a
drifted copy of ours and the remedy is to write over it; `taken` is somebody
else's server, and writing over it **is** the damage. An entry of the wrong
_shape_ is stale too — a config wired before the bridge existed holds an HTTP
entry, and that is precisely the one worth rewriting.

The header sentence is the same per-entry states reduced, in this precedence:
collides ▸ stale ▸ not configured (when _all_ are missing) ▸ incomplete ▸
configured. Header and badges are two renderings of one computation, which is how
they are kept from disagreeing about a file neither of them owns.

### Servers that are switched off

_Configure_ writes the profiles whose server is switched on, and only those. It
is the same list `wire_client` writes from and the one `list_clients` and the
sidebar dot report against, so a client is never wired to a server the gateway
would refuse, and configuring a client for one server does not put every
switched-off server back into its file.

Switching a server off does **not** rewrite anyone's config: that is a much
larger action than the toggle looks, and an entry that fails with Bastion's own
sentence is a better outcome than one that silently vanished. An entry already in
the file therefore stays, and this is the pane that says so. The row remains,
dimmed and badged `server off`, and it is left out of the header sentence — an
entry Bastion refuses to serve and refuses to write is not something the client
is missing. _Remove Bastion's entries_ takes it out, and switching the server
back on returns the row to the audit.

A switched-off server with nothing in the file gets no row at all: `not written`
would promise a write _Configure_ is not going to make.

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

Four properties, because the file is not Bastion's:

1. **Every unrelated key survives.** `~/.claude.json` on the machine this was
   written against holds nine global MCP servers, ninety-eight project blocks and
   seventy-five other top-level keys; Claude Desktop's carries seven entries plus
   `coworkUserFilesPath` and `preferences`. All of it has to come back
   byte-identical from a write that adds one key.
2. **The previous contents are recoverable** — copied to
   `<name>.bastion-backup` first.
3. **A crash mid-write cannot leave a truncated config.** Written to a temp file
   beside the target, then swapped. The result is `chmod 0600`, because it now
   carries a bearer token and did not necessarily before. (A no-op for Codex,
   whose `config.toml` and `auth.json` are both already `-rw-------`.)
4. **A merge is never landed on bytes it was not computed from.** Every write is
   conditional on the file's size and modification date at the moment it was
   read; if either moved, the write is refused and the whole operation runs
   again against the file as it now is — collision check included, since the
   entry that arrived in the window is exactly the one that has to be noticed.

The fourth is a narrower window rather than a closed one, and it is worth being
precise about which failure it removes. A process holding its own copy of the
whole file — Claude Code for the length of a session, the ChatGPT app on launch —
still wins by writing last, and nothing short of a lock neither side takes would
change that. What it removes is Bastion silently dropping a change that landed
while it was reading. The stakes are higher here than for a config full of plain
commands: these entries carry a bearer token, so a lost write does not leave a
server missing, it leaves a client that reaches the endpoint and fails to
authenticate.

The writer takes **bytes**, and the JSON path serialises into it, because the two
formats disagree about everything except this. Asking the backup-and-atomicity
question twice is how the second answer ends up subtly weaker. For TOML the first
property is stronger than "every unrelated key survives": every unrelated
**byte** does, because nothing outside the spliced spans is re-encoded at all.

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

|                          |                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make wiring-check`      | The merge, the audit, per-entry state, the foreign listings and single-key removal, against fixtures shaped like the real files. No app, no I/O beyond a temp directory.                                                                                                                                                                                             |
| `make wiring-check-real` | The same properties against **your actual** Claude Code, Claude Desktop, VS Code and Codex configs, dispatching on the file extension the way `ClientWiring` dispatches on a client's format. Read-only: parsed, merged and pruned in memory, then compared. Fixtures only cover the shapes somebody thought of; this covers the ones nobody would have invented.    |
| `make facade`            | Load-on-demand end to end against a running Debug build: the listing actually shrinks, search finds a tool and describe returns its schema, a dispatched call is recorded under the **real** tool name, and a write tool is neither indexed nor reachable for a profile with writes off. Scratch profiles of Bastion's own server, so no credentials and no network. |

The TOML half adds its own sections, and they are all the same question asked of
bytes rather than of parsed values: every byte outside our spans is unchanged,
comments survive both directions, a wire is idempotent, a wire followed by an
unwire is the original file, a hand-written entry is never re-rendered, a refusal
never writes, and — over every fixture — **a splice can never write a name
twice**.

`ClientWiringMerge.swift` and `ClientWiringTOML.swift` import nothing but
Foundation precisely so those two targets can compile them beside
`scripts/wiring-check.swift` and run the result —
which is the whole test story for a project with no test target. Everything
policy-shaped — which clients exist, where their configs live, which key and
which transport each gets — stays in `ClientWiring.swift`, which can keep
importing AppKit.
