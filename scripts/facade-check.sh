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

mkdir -p "$SUPPORT"
for f in servers.json profiles.json; do
  [ -f "$SUPPORT/$f" ] && cp "$SUPPORT/$f" "$SUPPORT/$f.facade-check-backup"
done
restore() {
  kill "${APP:-0}" 2>/dev/null || true
  wait "${APP:-0}" 2>/dev/null || true
  for f in servers.json profiles.json; do
    [ -f "$SUPPORT/$f.facade-check-backup" ] && mv "$SUPPORT/$f.facade-check-backup" "$SUPPORT/$f"
  done
  defaults delete "$BUNDLE" lazyToolsDefault 2>/dev/null || true
}
trap restore EXIT

# The app-wide switch ON, so the three profiles below cover all three states of
# the tri-state: one following it, one overriding to off, one overriding to on.
# A setting whose default nothing reads is a setting that silently does nothing,
# and that is precisely the bug a per-profile-only version would have had.
defaults write "$BUNDLE" lazyToolsDefault -bool YES

python3 - "$SUPPORT" <<'PY'
import json, os, sys
support = sys.argv[1]

def load(name, default):
    try:
        return json.load(open(os.path.join(support, name)))
    except Exception:
        return default

servers = [r for r in load("servers.json", []) if r.get("id") != "bastion"]
servers.insert(0, {"id": "bastion", "enabled": True})
json.dump(servers, open(os.path.join(support, "servers.json"), "w"), indent=2)

scratch = ("facadeoff", "facadeon", "facadero")
profiles = [
    p for p in load("profiles.json", [])
    if not (p.get("server") == "bastion" and p.get("name") in scratch)
]
# Three profiles of one server, one per state of the tri-state. The pair is the
# measurement — same tools, same process, one number each — and the third is the
# write gate under a facade.
#
# `facadeon` carries NO lazyTools key on purpose: it is the profile that has
# expressed no preference, so every assertion about the facade below is also an
# assertion that the app-wide default actually reaches a profile.
profiles.append({"name": "facadeoff", "server": "bastion", "values": {}, "allowWrites": True,
                 "lazyTools": False})
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
[ -n "$TOKEN" ] || { echo "no dev-token in $SUPPORT"; exit 2; }

# `rpc <profile> <body>`
rpc() {
  curl -s --max-time 15 \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$2" "http://127.0.0.1:$PORT/s/$1/bastion"
}

echo
echo "The saving"

PLAIN="$(rpc facadeoff '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
LAZY="$(rpc facadeon  '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"

PLAIN_N=$(printf '%s' "$PLAIN" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')
LAZY_N=$(printf '%s' "$LAZY" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))')
PLAIN_B=${#PLAIN}
LAZY_B=${#LAZY}

[ "$LAZY_N" = "3" ] && ok "a profile following the app-wide default gets three tools" \
  || bad "a profile following the app-wide default gets three tools — got $LAZY_N"
[ "$PLAIN_N" != "3" ] && ok "and a profile overriding it to off gets all $PLAIN_N" \
  || bad "a profile overriding to off still got the facade"
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
DIRECT="$(rpc facadeoff '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_profiles","arguments":{}}}')"
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

INVENTED="$(rpc facadeon '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"bastion_call_tool","arguments":{"name":"list_profilez","arguments":{}}}}')"
check "an invented name comes back with the near miss" "$INVENTED" "list_profiles"
check "and is marked an error" "$INVENTED" '"isError"'

# The rule that keeps a live session working when the toggle moves: a client
# still inside the 60s ttlMs is calling names from the list it already has.
STALE="$(rpc facadeon '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_profiles","arguments":{}}}')"
check "a pre-toggle tool name still works" "$STALE" "facadeon"

echo
echo "The audit"

# The claim the whole design rests on. `recent_activity` is read from a THIRD
# profile so the reading is not itself the thing being read.
ACT="$(rpc facadeoff '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"recent_activity","arguments":{"limit":50}}}')"
check "the log names the real tool" "$ACT" "list_profiles"
absent "and never the dispatcher it arrived through" "$ACT" "bastion_call_tool"

echo
echo "The gate"

RO="$(rpc facadero '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"bastion_search_tools","arguments":{"query":""}}}')"
check "a read tool is in the index" "$RO" "list_profiles"
absent "a write tool is not" "$RO" "remove_profile"
GATED="$(rpc facadero '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"bastion_call_tool","arguments":{"name":"remove_profile","arguments":{"name":"facadeon","server":"bastion"}}}}')"
absent "and the dispatcher will not run it" "$GATED" '"removed"'

echo
echo "$pass/$((pass + fail)) passed"
[ "$fail" -eq 0 ] || { echo "$fail failed"; exit 1; }
