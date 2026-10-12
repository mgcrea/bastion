# Only Bastion: an MCP allowlist for Claude Code profiles

Status: approved design, 2026-10-12. Implementation plan: not yet written.

## Problem

A Claude Code profile picks up MCP servers from four places, and Bastion only
writes one of them:

| Source                                   | Example on the reference machine, 2026-10-12                                                       |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `.claude.json` `mcpServers` and projects | Bastion's 24 entries, Cupertino's 12 stdio bridges, Armada                                         |
| A repository's `.mcp.json`               | none in use                                                                                        |
| Plugins, including account-synced ones   | ~45 servers from Marketing, Data, Design, Engineering, Productivity, Product Management and Stripe |
| claude.ai connectors                     | Gmail, Google Calendar, Google Drive, Claude Docs                                                  |

The last two arrive without anybody configuring them. The knowledge-work plugins
synced down from the claude.ai account each declare a dozen hosted servers
(HubSpot, Datadog, Klaviyo, Pendo…). Every VS Code session opened with a screen
of "requires authentication" and "failed to connect" lines for servers nobody
here uses, and the skills in those plugins, which are wanted, cannot be kept
without their servers.

The workaround applied by hand on 2026-10-12 was a `deniedMcpServers` list in
both profiles' `settings.json`: `{serverUrl: "https://*"}`, plus twelve
`plugin:<plugin>:<server>` names for placeholders declared with no URL at all.
A denylist names what it has seen. The next plugin with a URL-less server walks
past it.

Goal: one switch per Claude Code profile that lets through what was configured
on purpose and nothing else, kept current by Bastion and visible in the client
pane.

**This is hygiene, not a boundary.** User-scope `allowedMcpServers` merges with
every other settings scope, so a project's `.claude/settings.json` can widen
it. Only `allowManagedMcpServersOnly` in managed settings closes that, and this
design does not go there (see [Alternatives](#alternatives)).

## What Claude Code offers (researched 2026-10-12)

From the [managed MCP page](https://code.claude.com/docs/en/managed-mcp) and
the [MCP page](https://code.claude.com/docs/en/mcp):

- `allowedMcpServers` and `deniedMcpServers` are accepted in **any** settings
  scope, including `$CLAUDE_CONFIG_DIR/settings.json`. Denylists always win.
- An entry is one of `{serverUrl}` (exact, or with `*` wildcards in scheme,
  host, port and path), `{serverCommand: [...]}` (exact array of command and
  args; `env` is not compared), or `{serverName}`. In an allowlist,
  `serverName` takes only letters, digits, `-` and `_`.
- The filters apply to servers from every source, plugins and claude.ai
  included.
- `disableClaudeAiConnectors: true` stops Claude Code fetching claude.ai
  connectors, with any-source-true semantics. It does not reach Claude
  Desktop's chat.

### Verified on this machine

A throwaway `CLAUDE_CONFIG_DIR` holding a copy of `~/.claude.json`, a symlink to
`~/.claude/plugins`, and this `settings.json`:

```json
{
  "disableClaudeAiConnectors": true,
  "allowedMcpServers": [
    { "serverUrl": "http://127.0.0.1:8720/s/*" },
    { "serverUrl": "http://127.0.0.1:8790/mcp" },
    {
      "serverCommand": [
        "/Applications/Cupertino.app/Contents/Helpers/cupertino-bridge",
        "--server=calendar",
        "--client=claude-code"
      ]
    }
  ]
}
```

`claude mcp list` (Claude Code 2.1.296) reported all 24 Bastion entries, Armada
and `cupertino-calendar`; the other eleven Cupertino entries, every `plugin:`
server (including the URL-less placeholders) and every `claude.ai` connector
were gone. So a wildcard path matches Bastion's `/s/<profile>/<server>`, an
exact command array matches a stdio entry, and an allowlist needs no knowledge
of the plugins it excludes.

## Model

### The switch

Per Claude Code client row: `claude-code` and every `claude-code@<name>`. Other
families have no equivalent setting and do not show it.

Stored in UserDefaults as `clientLockdown`, a dictionary from client id to the
list of keys Bastion **added** to that file, beside `claudeProfilesAdopted`.
Presence of the id is "the user asked for this"; the key list is what turning
it off may remove. What the file holds is audited separately, every redraw,
exactly as wiring is.

A key that already held exactly the value Bastion would write (a
`disableClaudeAiConnectors: true` somebody set by hand) is adopted without
being recorded, so it outlives the switch. A key Bastion created, or took over
with `force`, is recorded.

### The file

`<config dir>/settings.json`, where the config directory is `ClaudeProfiles`'
`Row.directory` for a profile and the literal `~/.claude` for the default row.
That is the one asymmetry to keep straight: the default profile's
`.claude.json` sits **outside** its directory (`~/.claude.json`), but its
`settings.json` sits **inside** (`~/.claude/settings.json`).

A missing `settings.json` is created holding just the two keys.

### What is written

Exactly two top-level keys, which Bastion owns while the switch is on:

```json
"disableClaudeAiConnectors": true,
"allowedMcpServers": [ … ]
```

`allowedMcpServers` is generated, in this order:

1. `{ "serverUrl": "http://127.0.0.1:<port>/s/*" }`, with `<port>` from
   `Gateway.shared.port`. One entry covers every profile Bastion serves, so
   adding a profile does not change the file.
2. One entry per server in that profile's `.claude.json` that `isOurs` does not
   claim, from both the top-level `mcpServers` and every
   `projects[<path>].mcpServers`:
   - an entry with a `url` → `{ "serverUrl": <url> }`, exact;
   - an entry with a `command` → `{ "serverCommand": [command] + args }`, exact;
   - anything else (no `url`, no `command`) is skipped and reported, since
     Claude Code could not launch it either.

   Duplicates collapse; order follows the file, global entries first. Bastion's
   own entries are never listed one by one: the wildcard already covers them.

Servers from a repository's `.mcp.json` are not in `.claude.json` and are
**blocked**. The pane says so in one line beside the switch. Allowing them would
mean scanning repositories, which is the Workspaces feature's business, not
this one's.

`deniedMcpServers` is the user's. Bastion never reads it for status and never
writes it.

### Keeping the file's formatting

`settings.json` is hand-edited, and `ClientWiringMerge.write(_ root:)`
re-serialises with `.sortedKeys` and `.prettyPrinted`. That is acceptable for
`.claude.json`, a machine-written file, and not for this one: it would reorder
and re-indent somebody's settings to change two keys.

So a new Foundation-only `ClientSettingsSplice.swift` does for top-level JSON
keys what `ClientWiringTOML` does for TOML tables:

- A lexer walks the file once, tracking strings (with escapes), nesting depth
  and top-level `key: value` spans. It **refuses**, naming the offset, on a
  comment, a trailing comma, a duplicate top-level key, a top level that is not
  an object, or bytes that are not UTF-8. A refusal reads as `unreadable` and
  blocks every write, because every write begins with a read.
- To set a key that exists, the value span is replaced. To add one, it is
  inserted before the closing `}`, with a comma after the previous member if
  there is one, indented like the file's first member (two spaces if the
  object is empty).
- To remove a key, its member span and one adjoining comma are cut.
- Values Bastion inserts are serialised with `JSONSerialization`
  (`.prettyPrinted`, `.withoutEscapingSlashes`), re-indented to the member's
  depth.

The invariant, as for TOML: **every byte outside the spans Bastion rewrites is
unchanged**, and on followed by off returns the original file byte for byte
when neither key existed before.

The bytes go through the existing `ClientWiringMerge.write(_ data:…)`
unchanged: stamp check, `settings.json.bastion-backup`, temp file and swap,
`0600`, and no write when the bytes are identical.

### Turning it on, keeping it current, turning it off

- **On.** Read `settings.json` and `.claude.json`, build the allowlist, splice.
  If either key already exists with a value other than the one about to be
  written, refuse with `collision` naming the key, unless `force`. A forced
  write leaves the previous value in the backup.
- **Rewrite.** The existing `rewire` pass also re-runs the splice for every id
  in `clientLockdown`, under the same rules: never in a Debug build without
  `-autoWireClients YES`, failures logged rather than raised. A write that
  changes nothing is skipped, so running on every launch costs one read.
  `rewire` already runs on profile changes and launch; a port change in
  Settings triggers it too.
- **Off.** Remove each recorded key whose value is still Bastion-shaped
  (`allowedMcpServers` holding the wildcard entry, `disableClaudeAiConnectors`
  true). A `stale` list is still Bastion-shaped and goes without ceremony. A
  recorded key edited out of that shape (`drifted`) is refused unless `force`,
  so a hand edit is not silently dropped. Unrecorded keys stay. Remove the id
  from `clientLockdown`.
- **Unwire.** Unwiring a client turns its lockdown off first. An allowlist
  naming a Bastion that is no longer wired would block every server the
  profile has.

### Status

A second line in the client's audit, computed from one read of each file per
redraw, never cached:

| State                         | Meaning                                                                | Remedy                   |
| ----------------------------- | ---------------------------------------------------------------------- | ------------------------ |
| `off`                         | Not in `clientLockdown`, and neither key is Bastion-shaped.            | —                        |
| `on`                          | Both keys equal what Bastion would write now.                          | —                        |
| `stale — <names> not allowed` | Ours, but `.claude.json` gained a server, or the port changed.         | _Configure_ rewrites it. |
| `drifted`                     | In `clientLockdown`, but a key was edited, removed, or set to `false`. | _Configure_ with force.  |
| `left behind`                 | Not in `clientLockdown`, but the file holds Bastion's wildcard entry.  | _Turn off_ removes it.   |
| `unreadable`                  | The splice lexer refused `settings.json`.                              | A person edits the file. |

"Bastion-shaped" means `allowedMcpServers` contains
`http://127.0.0.1:<any port>/s/*`, the same loopback test `isOurs` applies to
an entry. It is what makes `left behind` detectable after UserDefaults is
lost. Turning off a `left behind` file removes `allowedMcpServers` only: with
the record gone, nothing says whether `disableClaudeAiConnectors` was Bastion's.

### Surfaces

- **Client pane** (`ClientDetail`), under Context: an **Only Bastion** toggle,
  the state and its remedy, the allowed list (Bastion, then each kept server by
  key), and the one-line note about `.mcp.json`.
- **MCP:** `set_client_lockdown { client, on, force? }`, `mutates: true`,
  returning `client`, `state`, `settings_path`, `backup`, `allowed` (the keys
  kept beside Bastion) and `skipped`. `list_clients` gains `lockdown` (the
  state string) on Claude Code rows.

## Alternatives

**Managed settings with `allowManagedMcpServersOnly`.** Writing
`/Library/Application Support/ClaudeCode/managed-settings.json` would make the
allowlist binding: no project could widen it. It needs an administrator
prompt, covers every profile at once with one list, and leaves no way to
loosen it for an afternoon of debugging without that prompt again. Worth
revisiting if this ever has to be a control rather than hygiene; the
allowlist builder is shared, so it would be a second writer, not a redesign.

**A maintained denylist.** What was done by hand. It has to name every plugin
server, and the placeholders need the scoped `plugin:x:y` form that the docs do
not promise. Rejected.

**Strictly Bastion only.** Dropping step 2 would block Cupertino and Armada
here, and anything else configured on purpose. Keeping what `.claude.json`
already holds makes the switch safe to flip on a working setup; removing a
server from the config is how to block it.

## Testing

No test target exists; the checks follow the repo's pattern.

- **`make wiring-check`** compiles `ClientSettingsSplice.swift` beside the
  existing files and adds sections:
  - every byte outside the spans is unchanged, over fixtures with unusual
    indentation, unicode, escaped quotes in strings and nested objects;
  - set on an existing key, add to a populated object, add to `{}`, add to an
    empty file;
  - on then off returns the original bytes; on twice is idempotent;
  - refusal on a comment, a trailing comma, a duplicate top-level key, a
    top-level array, invalid UTF-8, and a refusal never writes;
  - collision without `force`, takeover with it, backup written once;
  - an equal pre-existing key is adopted unrecorded and survives off; a
    recorded key edited out of shape refuses off without `force`.
- **`make unit`**: allowlist generation from `.claude.json`-shaped fixtures
  (global and project servers, URL and command, Bastion entries excluded,
  duplicates collapsed, unlaunchable entries skipped), and the state table,
  row by row.
- **`make wiring-check-real`**: computes the lockdown state for every real
  Claude Code profile, read-only.
- **Release check**, written into `docs/clients.md`: with the switch on,
  `CLAUDE_CONFIG_DIR=<dir> claude mcp list` shows no `plugin:` and no
  `claude.ai` line, and every Bastion and kept server.

## Documentation

A new **Only Bastion** section in `docs/clients.md`, after "Claude Code's
config directories": what the switch writes, why it is an allowlist, why the
file is spliced rather than serialised, what it does not cover (repository
`.mcp.json`, Claude Desktop chat, project settings widening it), and the
release check.

## On the reference machine, after shipping

Remove the hand-written `deniedMcpServers` from `~/.claude/settings.json` and
`~/.claude-skitrust/settings.json`, then turn the switch on for both rows. The
denylist is not a collision, since Bastion never touches it, but its
`https://*` entry would block any https server the allowlist keeps, and
denylists win. The hand-set `disableClaudeAiConnectors: true` is adopted
unrecorded and survives the switch being turned off.
