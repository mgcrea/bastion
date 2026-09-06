#!/usr/bin/env bash
# Assert the tool facade against a running Debug build.
#
# Four claims, none of which is visible from a unit test because each of them
# is about what a real client is actually served:
#
#   THE SAVING  A profile with the facade on is sent three tools instead of
#               every tool the server exposes, and the listing shrinks by an
#               order of magnitude.
#
#   THE WAY IN  Everything is still reachable — search finds a tool, describe
#               returns its schema, and call runs it and comes back with the
#               same answer a direct call would have given.
#
#   THE AUDIT   A call made through `bastion_call_tool` is recorded under the
#               REAL tool name. This is the whole reason the facade lives in
#               the gateway instead of being bought as a server, and it is the
#               one thing that fails silently: everything else goes on working
#               while the log quietly flattens to `bastion_call_tool`.
#
#   THE GATE    A profile with writes off never sees a mutating tool in the
#               index and cannot reach one through the dispatcher either.
#
#   THE WRITES  A profile with writes ON gets a SECOND dispatcher, and the
#               first one refuses to run anything mutating. This is what makes
#               allowlisting `bastion_call_tool` in an editor safe: Bastion
#               enforces the boundary rather than annotating it and hoping.
#
#   THE CLIENT  Two clients on ONE profile are served differently: the one that
#               loads schemas on demand by itself gets the real list, the other
#               gets the three. Only observable here — a unit test can pin the
#               rule but not that the gateway consults it per caller.
#
# Runs against scratch profiles of Bastion's own server, so it needs no
# credentials, no network and no installed package, and it removes them
# afterwards. Same bargain `builtin-check.sh` makes, for the same reason.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion"
PORT="${BASTION_PORT:-8720}"
SUPPORT="$HOME/Library/Application Support/io.mgcrea.bastion.debug"
BUNDLE="io.mgcrea.bastion.debug"

[ -x "$BIN" ] || { echo "no build — run \`make app\` first"; exit 2; }

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected '$3' in: ${2:0:400}" ;; esac; }
absent() { case "$2" in *"$3"*) bad "$1 — '$3' should not be there" ;; *) ok "$1" ;; esac; }

# The two scratch clients THE CLIENT is about. Neither is a real
# `ClientWiring` id, deliberately: minting a token to "claude-code" would
# overwrite the developer's own and unwire their editor. The table itself is
# pinned by `make unit`; what is provable only here is that the gateway asks
# the question per caller at all, and the per-client override is what lets an
# arbitrary id stand in for one that defers.
PLAINCLIENT="facade-check"
LAZYCLIENT="facade-check-defers"

mkdir -p "$SUPPORT"
for f in servers.json profiles.json import.json dev-token; do
  [ -f "$SUPPORT/$f" ] && cp "$SUPPORT/$f" "$SUPPORT/$f.facade-check-backup"
done
restore() {
  kill "${APP:-0}" 2>/dev/null || true
  wait "${APP:-0}" 2>/dev/null || true
  for f in servers.json profiles.json import.json dev-token; do
    [ -f "$SUPPORT/$f.facade-check-backup" ] && mv "$SUPPORT/$f.facade-check-backup" "$SUPPORT/$f"
  done
  rm -f "$SUPPORT/dev-token-$LAZYCLIENT" "$SUPPORT/imported.json"
  # The tokens too, not just the files holding them. A bearer token for a
  # client that does not exist, left valid in the Keychain, is exactly what
  # this app is for stopping.
  for c in "$PLAINCLIENT" "$LAZYCLIENT"; do
    security delete-generic-password -s "$BUNDLE.gateway" -a "$c" >/dev/null 2>&1 || true
  done
  defaults delete "$BUNDLE" lazyToolsDefault 2>/dev/null || true
  defaults delete "$BUNDLE" lazyToolsMovedToServers 2>/dev/null || true
  defaults delete "$BUNDLE" "lazyToolsClient.$LAZYCLIENT" 2>/dev/null || true
}
trap restore EXIT

# The app-wide switch ON, and the scratch server below carries NO override, so
# every assertion about the facade is also an assertion that the app-wide
# default actually reaches a server. A setting whose default nothing reads is a
# setting that silently does nothing.
defaults write "$BUNDLE" lazyToolsDefault -bool YES

# The one-shot has to be able to run. It is guarded by its own flag rather than
# by "the server has no value yet", so a previous run of this script would
# otherwise leave it permanently done.
defaults delete "$BUNDLE" lazyToolsMovedToServers 2>/dev/null || true

# One of the two clients loads schemas on demand. Set through the per-client
# override rather than by naming a client in `ToolFacade`'s table, so this stays
# true when the table changes and so no real client's token is touched.
defaults write "$BUNDLE" "lazyToolsClient.$LAZYCLIENT" -string true

# Both tokens minted by the app itself, through DevSeed, for the reason its
# `tokens` field states: `security` here would mean re-spelling the Keychain
# naming in shell. Empty `profiles`, because this script writes profiles.json
# directly a few lines down and an import that also wrote it would race.
cat > "$SUPPORT/import.json" <<JSON
{"token": "$PLAINCLIENT", "tokens": ["$LAZYCLIENT"], "profiles": []}
JSON

python3 - "$SUPPORT" <<'PY'
import json, os, sys
support = sys.argv[1]

def load(name, default):
    try:
        return json.load(open(os.path.join(support, name)))
    except Exception:
        return default

# No `lazyTools` key: the server expresses no preference, so it follows the
# app-wide switch set above. THE SERVER is where the override lives now, and
# THE SERVER below moves it through `upsert_profile` and reads the effect.
servers = [r for r in load("servers.json", []) if r.get("id") != "bastion"]
servers.insert(0, {"id": "bastion", "enabled": True})
json.dump(servers, open(os.path.join(support, "servers.json"), "w"), indent=2)

scratch = ("facadeoff", "facadeon", "facadero")
profiles = [
    p for p in load("profiles.json", [])
    if not (p.get("server") == "bastion" and p.get("name") in scratch)
]
# Two profiles of one server, differing only in the write gate. There used to
# be three, one per position of a per-profile tri-state; that setting moved to
# the server, so the third had nothing left to say. What replaces it as the
# source of an UNFRONTED listing is the deferring client, which is the path
# that now matters most anyway.
#
# `facadero` carries the RETIRED `lazyTools` key, which is the migration's only
# input: THE SERVER below asserts it was carried onto the server row. A
# migration that silently does nothing loses a setting somebody turned on, and
# the symptom is a listing that quietly grew back.
profiles.append({"name": "facadeon", "server": "bastion", "values": {}, "allowWrites": True})
profiles.append({"name": "facadero", "server": "bastion", "values": {}, "allowWrites": False,
                 "lazyTools": True})
json.dump(profiles, open(os.path.join(support, "profiles.json"), "w"), indent=2)
PY

pkill -f "$BIN" 2>/dev/null || true
sleep 1
# `-gatewayPort` as a launch argument for `builtin-check.sh`'s reason: without
# it, BASTION_PORT=8799 moves only the curl and every assertion lands on the
# Bastion somebody is working in.
"$BIN" --trial -gatewayPort "$PORT" >/tmp/bastion-facade.log 2>&1 &
APP=$!
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 1

TOKEN="$(cat "$SUPPORT/dev-token" 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "no dev-token in $SUPPORT — did the app consume import.json?"; exit 2; }
LAZYTOKEN="$(cat "$SUPPORT/dev-token-$LAZYCLIENT" 2>/dev/null)"
[ -n "$LAZYTOKEN" ] || { echo "no dev-token-$LAZYCLIENT in $SUPPORT"; exit 2; }

# `rpc <profile> <body>` — as the client that does NOT defer, which is every
# assertion in this file except the two under THE CLIENT.
rpc() {
  curl -s --max-time 15 \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$2" "http://127.0.0.1:$PORT/s/$1/bastion"
}

# The same call as the client that does. Same port, same profile, same body —
# the token is the only thing that differs, which is the whole point.
rpcLazyClient() {
  curl -s --max-time 15 \
    -H "Authorization: Bearer $LAZYTOKEN" -H 'Content-Type: application/json' \
    -d "$2" "http://127.0.0.1:$PORT/s/$1/bastion"
}

echo
echo "The saving"

# One profile, two tokens. The unfronted listing comes from the client that
# defers schemas itself — same profile, same process, same second — which is
# both a tighter comparison than two profiles ever were and the thing that
# would break first if the client axis stopped being consulted.
PLAIN="$(rpcLazyClient facadeon '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
LAZY="$(rpc facadeon  '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"

PLAIN_N=$(printf '%s' "$PLAIN" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')
LAZY_N=$(printf '%s' "$LAZY" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')
PLAIN_B=${#PLAIN}
LAZY_B=${#LAZY}

# Four, not three: `facadeon` allows writes, Bastion's own server annotates
# every declaration, so a write dispatcher is declared beside the other three.
# `facadero` below is the three-tool case.
[ "$LAZY_N" = "4" ] && ok "a server following the app-wide default gets four tools" \
  || bad "a server following the app-wide default gets four tools — got $LAZY_N"
[ "$PLAIN_N" -gt 10 ] && ok "and a client that defers gets all $PLAIN_N" \
  || bad "a client that defers still got the facade — got $PLAIN_N"
[ "$PLAIN_N" -gt 10 ] && ok "the server itself lists $PLAIN_N" \
  || bad "the server itself lists more than ten — got $PLAIN_N"
[ "$LAZY_B" -lt "$((PLAIN_B / 4))" ] \
  && ok "the listing shrank from ${PLAIN_B}B to ${LAZY_B}B" \
  || bad "the listing shrank by at least 4x — ${PLAIN_B}B to ${LAZY_B}B"
check "the three are named for the gateway" "$LAZY" "bastion_search_tools"
check "and the dispatcher is there" "$LAZY" "bastion_call_tool"
absent "no real tool name is in the listing" "$LAZY" "list_profiles"
# `Dialect.annotateList` has to go on running over a reply Bastion synthesised:
# a modern client reading a list with no ttlMs registers zero tools.
MODERN="$(curl -s --max-time 15 -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: tools/list' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"facade-check","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}' \
  "http://127.0.0.1:$PORT/s/facadeon/bastion")"
check "a modern client still gets a ttlMs" "$MODERN" '"ttlMs"'
check "and a cacheScope" "$MODERN" '"cacheScope"'

echo
echo "The way in"

SEARCH="$(rpc facadeon '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bastion_search_tools","arguments":{"query":"profiles"}}}')"
check "search finds a real tool" "$SEARCH" "list_profiles"
check "and says how to reach it" "$SEARCH" "bastion_describe_tool"

# A word nothing carries used to empty the whole result, which is what told a
# model searching App Store Connect for "version builds submission" that no such
# tool existed. It must come back with the tools that matched the rest, and it
# must say plainly that it did not match everything.
PARTIAL="$(rpc facadeon '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"bastion_search_tools","arguments":{"query":"profiles kubernetes"}}}')"
check "a word that matches nothing does not empty the result" "$PARTIAL" "list_profiles"
check "and the miss is admitted, not hidden" "$PARTIAL" "Nothing matches all of"
check "and the word that missed is named" "$PARTIAL" "kubernetes"

INDEX="$(rpc facadeon '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"bastion_search_tools","arguments":{"query":""}}}')"
check "an empty query lists everything" "$INDEX" "list_clients"

DESC="$(rpc facadeon '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"bastion_describe_tool","arguments":{"name":"list_profiles"}}}')"
check "describe returns the schema" "$DESC" "inputSchema"

TYPO="$(rpc facadeon '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"bastion_describe_tool","arguments":{"name":"list_profile"}}}')"
check "a mistyped name suggests the real one" "$TYPO" "list_profiles"

CALL="$(rpc facadeon '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"bastion_call_tool","arguments":{"name":"list_profiles","arguments":{}}}}')"
# The undispatched answer, as the client that is not fronted. Same profile as
# the dispatched one now, which makes the comparison stricter than it was: the
# two differ only in how the tool was named.
DIRECT="$(rpcLazyClient facadeon '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_profiles","arguments":{}}}')"
check "the dispatcher runs the real tool" "$CALL" "facadeon"
# Compared as parsed results, not as bytes: `JSONSerialization` does not fix a
# dictionary's key order, so two identical answers are routinely two different
# strings and a byte comparison here would fail at random.
if python3 -c 'import json,sys; a,b=json.load(open(sys.argv[1])),json.load(open(sys.argv[2])); sys.exit(0 if a["result"]==b["result"] else 1)' \
     <(printf '%s' "$CALL") <(printf '%s' "$DIRECT") 2>/dev/null; then
  ok "and returns exactly what a direct call returns"
else
  bad "the dispatched answer differs from the direct one"
  echo "        dispatched: ${CALL:0:400}"
  echo "        direct:     ${DIRECT:0:400}"
fi

# The rule that keeps a live session working when the toggle moves: a client
# still inside the 60s ttlMs is calling names from the list it already has.
STALE="$(rpc facadeon '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_profiles","arguments":{}}}')"
check "a pre-toggle tool name still works" "$STALE" "facadeon"

echo
echo "The audit"

# The claim the whole design rests on. Read as the client that is NOT fronted,
# so the reading is not itself a dispatch — it used to be a third profile, and
# the requirement was always "by a path that is not the one under test".
ACT="$(rpcLazyClient facadeon '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"recent_activity","arguments":{"limit":50}}}')"
check "the log names the real tool" "$ACT" "list_profiles"
absent "and never the dispatcher it arrived through" "$ACT" "bastion_call_tool"

# Deliberately after the audit read, and this is not cosmetic. A dispatch the
# facade ANSWERS rather than rewrites — an invented name — is genuinely a
# `bastion_call_tool` call, because there is no real tool behind it to name, so
# the log is right to record it that way. Run before the read, it lands in the
# window and the assertion above fails for a reason that has nothing to do with
# the claim it is making.
#
# The read is scoped to the caller's own profile (`recentActivity` filters on
# `entry.origin == caller`), which is why this ordering matters at all: it used
# to be read from a THIRD profile, and a caller-scoped read from a profile that
# never used the facade cannot see the dispatch it was supposed to be checking.
INVENTED="$(rpc facadeon '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"bastion_call_tool","arguments":{"name":"list_profilez","arguments":{}}}}')"
check "an invented name comes back with the near miss" "$INVENTED" "list_profiles"
check "and is marked an error" "$INVENTED" '"isError"'

echo
echo "The gate"

RO="$(rpc facadero '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"bastion_search_tools","arguments":{"query":""}}}')"
check "a read tool is in the index" "$RO" "list_profiles"
absent "a write tool is not" "$RO" "remove_profile"
GATED="$(rpc facadero '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"bastion_call_tool","arguments":{"name":"remove_profile","arguments":{"name":"facadeon","server":"bastion"}}}}')"
absent "and the dispatcher will not run it" "$GATED" '"removed"'

echo
echo "The server"

# Read off disk rather than inferred from a listing. The app-wide default is
# also on, so a migrated `true` and a missing value produce the same three
# tools — the file is the only place the two differ.
MIGRATED="$(python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])); print(next((r.get("lazyTools") for r in rows if r.get("id")=="bastion"), None))' "$SUPPORT/servers.json" 2>/dev/null)"
[ "$MIGRATED" = "True" ] \
  && ok "a lazyTools left on a profile was carried onto its server" \
  || bad "the migration did not reach servers.json — got '$MIGRATED'"

# The tier the setting moved to, moved through the surface an agent actually
# has. `upsert_profile` still accepts `lazy_tools` — an argument that started
# being silently ignored would be worse than one that was renamed — and it now
# writes through to the server, so this asserts the write-through and the tier
# in one call.
# Through the WRITE dispatcher: `upsert_profile` mutates, and the read one now
# refuses it. That refusal is the subject of THE WRITES below.
OFF="$(rpc facadeon '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"bastion_call_write_tool","arguments":{"name":"upsert_profile","arguments":{"name":"facadeon","server":"bastion","lazy_tools":false}}}}')"
check "upsert_profile still takes lazy_tools" "$OFF" 'lazy_tools'

AFTER="$(rpc facadeon '{"jsonrpc":"2.0","id":21,"method":"tools/list"}')"
AFTER_N=$(printf '%s' "$AFTER" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')
[ "$AFTER_N" = "$PLAIN_N" ] \
  && ok "turning it off on the server gives every client all $AFTER_N" \
  || bad "the server override did not reach the listing — got $AFTER_N, expected $PLAIN_N"

# And the other profile of that server moves with it, which is the whole
# difference between a server setting and the per-profile one it replaced.
RO_AFTER="$(rpc facadero '{"jsonrpc":"2.0","id":22,"method":"tools/list"}')"
absent "and the server's OTHER profile moved with it" "$RO_AFTER" "bastion_search_tools"

BACK="$(rpc facadeon '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"upsert_profile","arguments":{"name":"facadeon","server":"bastion","lazy_tools":true}}}')"
RESTORED="$(rpc facadeon '{"jsonrpc":"2.0","id":24,"method":"tools/list"}')"
RESTORED_N=$(printf '%s' "$RESTORED" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')
[ "$RESTORED_N" = "4" ] && ok "and turning it back on restores the facade" \
  || bad "turning it back on restores the facade — got $RESTORED_N"

echo
echo "The client"

# One profile, two tokens. `facadeon` hands the ordinary client three tools —
# asserted at the top of this file — and has to hand the deferring one all of
# them, from the same process, in the same second. Anything that made the
# gateway resolve the facade per profile alone would fail here and nowhere else.
CLIENTLAZY="$(rpcLazyClient facadeon '{"jsonrpc":"2.0","id":12,"method":"tools/list"}')"
CLIENTLAZY_N=$(printf '%s' "$CLIENTLAZY" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')

[ "$CLIENTLAZY_N" = "$PLAIN_N" ] \
  && ok "a client that defers schemas gets all $CLIENTLAZY_N from the same profile" \
  || bad "a client that defers schemas gets the real list — got $CLIENTLAZY_N, expected $PLAIN_N"
absent "and is never handed the dispatcher" "$CLIENTLAZY" "bastion_call_tool"
# Said again here rather than assumed from the top of the file: the pair is the
# claim, and half of it proves nothing.
[ "$LAZY_N" = "4" ] \
  && ok "while the other client, on that same profile, still gets the facade" \
  || bad "the ordinary client stopped getting the facade — got $LAZY_N"

echo
echo "The writes"

# The boundary the split exists for, proved in both directions against a real
# server. Bastion's own annotates every declaration from its `mutates` flag, so
# the classification here is exact rather than best-effort.
WRITELIST="$(rpc facadeon '{"jsonrpc":"2.0","id":30,"method":"tools/list"}')"
check "a writes-on profile is given a write dispatcher" "$WRITELIST" "bastion_call_write_tool"

# The audit first, and before any REFUSED call below, for the reason THE AUDIT
# states: a dispatch the facade refuses is genuinely a call to the dispatcher —
# there is no real tool behind it to name — so the log is right to record it
# that way, and running a refusal first would put the name in the window and
# fail the assertion for a reason unrelated to its claim.
UPSERTED="$(rpc facadeon '{"jsonrpc":"2.0","id":35,"method":"tools/call","params":{"name":"bastion_call_write_tool","arguments":{"name":"upsert_profile","arguments":{"name":"facadero","server":"bastion","allow_writes":false}}}}')"
check "the write dispatcher runs a write" "$UPSERTED" "facadero"
WACT="$(rpcLazyClient facadeon '{"jsonrpc":"2.0","id":36,"method":"tools/call","params":{"name":"recent_activity","arguments":{"limit":50}}}')"
check "and the log names the real tool" "$WACT" "upsert_profile"
absent "never the write dispatcher it arrived through" "$WACT" "bastion_call_write_tool"

# The claim that makes allowlisting the read dispatcher safe. Refused by
# Bastion, not merely marked: `remove_profile` is a real, destructive tool on a
# profile that IS allowed to call it, so nothing but the split is stopping this.
REFUSED="$(rpc facadeon '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"bastion_call_tool","arguments":{"name":"remove_profile","arguments":{"name":"facadero","server":"bastion"}}}}')"
check "the read dispatcher refuses a write" "$REFUSED" '"isError"'
check "and names the one that will run it" "$REFUSED" "bastion_call_write_tool"
STILL="$(rpc facadeon '{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"bastion_call_tool","arguments":{"name":"list_profiles","arguments":{}}}}')"
check "and the profile it was aimed at is still there" "$STILL" "facadero"

# Disjoint the other way, so nothing downstream has to check the split twice.
WRONGWAY="$(rpc facadeon '{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"bastion_call_write_tool","arguments":{"name":"list_profiles","arguments":{}}}}')"
check "the write dispatcher refuses a read" "$WRONGWAY" '"isError"'
check "and names the one that will run it" "$WRONGWAY" "bastion_call_tool"

# A writes-off profile has nothing to dispatch to, so it keeps the three.
ROLIST="$(rpc facadero '{"jsonrpc":"2.0","id":37,"method":"tools/list"}')"
RO_N=$(printf '%s' "$ROLIST" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')
[ "$RO_N" = "3" ] && ok "and a writes-off profile is given only the three" \
  || bad "a writes-off profile is given only the three — got $RO_N"
absent "with no write dispatcher among them" "$ROLIST" "bastion_call_write_tool"

echo
echo "$pass/$((pass + fail)) passed"
[ "$fail" -eq 0 ] || { echo "$fail failed"; exit 1; }
