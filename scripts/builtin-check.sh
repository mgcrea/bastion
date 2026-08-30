#!/usr/bin/env bash
# Assert Bastion's own MCP server against a running Debug build.
#
# Two claims are worth having a check hold, because both are invisible until
# they are already wrong:
#
#   THE GATE   A profile with writes off is served the read tools and nothing
#              else, and a mutating tool called anyway is refused rather than
#              run. The gate has to hold at BOTH points — `tools/list` is
#              advisory, and a client may have cached an older one.
#
#   THE WALL   No tool returns a credential. `set_credential` writes one, and
#              nothing reads one back; `list_profiles` names which secrets are
#              set and never what they are set to.
#
# Plus the two self-referential refusals — the control plane cannot switch
# itself off or delete itself — and the licence carve-out, which is the one
# place the gateway deliberately serves an unlicensed request.
#
# Runs against a scratch profile of its own and removes it afterwards, so it
# does not need, touch or notice the developer's real setup.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion"
PORT="${BASTION_PORT:-8720}"
SUPPORT="$HOME/Library/Application Support/io.mgcrea.bastion.debug"

[ -x "$BIN" ] || { echo "no build — run \`make app\` first"; exit 2; }

pass=0 fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
# `check <label> <haystack> <needle>`
check() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected '$3' in: $2" ;; esac; }
absent() { case "$2" in *"$3"*) bad "$1 — '$3' should not be there" ;; *) ok "$1" ;; esac; }

# The built-in server is off by default and needs a profile, so the check
# arranges both in the store's own files before launching. Backed up and put
# back on the way out: this is somebody's real Application Support directory.
mkdir -p "$SUPPORT"
for f in servers.json profiles.json; do
  [ -f "$SUPPORT/$f" ] && cp "$SUPPORT/$f" "$SUPPORT/$f.builtin-check-backup"
done

restore() {
  kill "${APP:-0}" 2>/dev/null || true
  wait "${APP:-0}" 2>/dev/null || true
  for f in servers.json profiles.json; do
    if [ -f "$SUPPORT/$f.builtin-check-backup" ]; then
      mv "$SUPPORT/$f.builtin-check-backup" "$SUPPORT/$f"
    fi
  done
}
trap restore EXIT

python3 - "$SUPPORT" <<'PY'
import json, os, sys
support = sys.argv[1]

def load(name, default):
    path = os.path.join(support, name)
    try:
        return json.load(open(path))
    except Exception:
        return default

servers = [r for r in load("servers.json", []) if r.get("id") != "bastion"]
servers.insert(0, {"id": "bastion", "enabled": True})
json.dump(servers, open(os.path.join(support, "servers.json"), "w"), indent=2)

profiles = [
    p for p in load("profiles.json", [])
    if not (p.get("server") == "bastion" and p.get("name") in ("checkro", "checkrw"))
]
# Two profiles of one server, which is also a check that the write gate is per
# profile rather than per server: same tools, same install, different answer.
profiles.append({"name": "checkro", "server": "bastion", "values": {}, "allowWrites": False})
profiles.append({"name": "checkrw", "server": "bastion", "values": {}, "allowWrites": True})
json.dump(profiles, open(os.path.join(support, "profiles.json"), "w"), indent=2)
PY

pkill -f "$BIN" 2>/dev/null || true
sleep 1
# Deliberately NOT `--trial`. The licence carve-out is one of the things under
# test, and arming a trial would hide it.
"$BIN" >/tmp/bastion-builtin.log 2>&1 &
APP=$!
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 1

TOKEN="$(cat "$SUPPORT/dev-token" 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "no dev-token in $SUPPORT"; exit 2; }

# `rpc <profile> <body>`
rpc() {
  curl -s --max-time 10 \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$2" "http://127.0.0.1:$PORT/s/$1/bastion"
}
# The modern era mirrors its `_meta` into headers, and the gateway rejects a
# frame whose headers disagree with its body — so a modern call needs both.
# `mrpc <profile> <method> <body>`
mrpc() {
  curl -s --max-time 10 \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' -H "Mcp-Method: $2" \
    -d "$3" "http://127.0.0.1:$PORT/s/$1/bastion"
}
# `tool <profile> <name> <arguments-json>` — returns the tool's own text, not
# the JSON-RPC envelope. Matching against the envelope means matching against
# JSON escaped inside a JSON string, where `"name" : "one"` is spelled
# `\"name\" : \"one\"` and every needle is unreadable.
toolraw() {
  rpc "$1" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}"
}
tool() {
  toolraw "$@" \
    | python3 -c 'import sys,json
d=json.load(sys.stdin)
r=d.get("result",{})
c=r.get("content")
print(c[0]["text"] if c else json.dumps(d))'
}

echo
echo "Licence"
# No key is configured in a Debug build and no trial is armed, so every relayed
# request is refused — and this one still has to be served.
check "the built-in server answers unlicensed" \
  "$(rpc checkro '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')" '"tools"'
absent "and is not given the licence sentence" \
  "$(rpc checkro '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')" 'not licensed'

echo
echo "Handshakes"
check "legacy initialize is answered" \
  "$(rpc checkro '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"check"},"capabilities":{}}}')" \
  '"protocolVersion":"2025-06-18"'
check "modern server/discover is answered" \
  "$(mrpc checkro server/discover '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}')" \
  'supportedVersions'
check "an unknown method is -32601" \
  "$(rpc checkro '{"jsonrpc":"2.0","id":1,"method":"resources/list"}')" '-32601'

echo
echo "The write gate"
RO="$(rpc checkro '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
RW="$(rpc checkrw '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
check  "writes off still lists the read tools" "$RO" 'list_servers'
absent "writes off hides remove_server"       "$RO" 'remove_server'
absent "writes off hides set_credential"      "$RO" 'set_credential'
absent "writes off hides add_custom_server"   "$RO" 'add_custom_server'
check  "writes on lists remove_server"        "$RW" 'remove_server'
check  "writes on lists set_credential"       "$RW" 'set_credential'
# The gate is not merely a filter on the list: a client with a stale list, or
# one guessing a name, has to be refused at the point of use too.
check "a mutating tool called anyway is refused" \
  "$(tool checkro remove_server '{"id":"unifi-protect"}')" 'write gate is off'
# A refusal has to arrive as a tool result the model can read, not as a
# JSON-RPC error the client swallows — so this one looks at the envelope.
check "and the refusal is a tool error, not a transport error" \
  "$(toolraw checkro remove_server '{"id":"unifi-protect"}')" '"isError"'

echo
echo "The control plane cannot turn on itself"
check "disable_server refuses bastion" \
  "$(tool checkrw disable_server '{"id":"bastion"}')" 'cannot disable itself'
check "remove_server refuses bastion" \
  "$(tool checkrw remove_server '{"id":"bastion"}')" 'cannot remove itself'
check "the id is reserved against a custom server" \
  "$(tool checkrw add_custom_server '{"id":"bastion","display_name":"X","npm_name":"@x/y","env":[{"name":"A"}]}')" \
  'reserved'

echo
echo "Secrets are write-only"
tool checkrw add_custom_server \
  '{"id":"checkscratch","display_name":"Scratch","summary":"check","npm_name":"@mgcrea/mcp-checkscratch","env":[{"name":"CHECK_TOKEN","required":true,"secret":true,"description":"a token"}]}' >/dev/null
tool checkrw upsert_profile '{"name":"one","server":"checkscratch"}' >/dev/null
tool checkrw set_credential '{"profile":"one","server":"checkscratch","variable":"CHECK_TOKEN","value":"s3cr3t-canary"}' >/dev/null
PROFILES="$(tool checkrw list_profiles '{"server":"checkscratch"}')"
check  "list_profiles names a secret that is set" "$PROFILES" 'CHECK_TOKEN'
absent "and never its value"                      "$PROFILES" 's3cr3t-canary'
absent "no tool reads a credential back"          "$RW"       'get_credential'
check "a secret handed to upsert_profile is refused" \
  "$(tool checkrw upsert_profile '{"name":"one","server":"checkscratch","values":{"CHECK_TOKEN":"s3cr3t-canary"}}')" \
  'set with set_credential'
absent "so it never reaches profiles.json" \
  "$(cat "$SUPPORT/profiles.json")" 's3cr3t-canary'

echo
echo "Disabling"
# Relaunched WITH a trial for this section only. The licence gate sits ahead of
# the disabled check for a relayed server — deliberately, since it is the last
# point before anything can be spawned — so an unlicensed build answers every
# such request with the licence sentence and the disabled one is unreachable.
# Which is correct, and means the sentence can only be observed from the side of
# the gate a paying user is on.
kill "$APP" 2>/dev/null || true
wait "$APP" 2>/dev/null || true
sleep 1
"$BIN" --trial >>/tmp/bastion-builtin.log 2>&1 &
APP=$!
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 1

tool checkrw disable_server '{"id":"checkscratch"}' >/dev/null
check "a disabled server refuses with its own sentence" \
  "$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
      "http://127.0.0.1:$PORT/s/one/checkscratch")" 'switched off'
absent "and drops out of /health" \
  "$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")" \
  'checkscratch'
check "its profile survives being disabled" \
  "$(tool checkrw list_profiles '{"server":"checkscratch"}')" '"name" : "one"'

tool checkrw enable_server '{"id":"checkscratch"}' >/dev/null
check "and it answers again once enabled" \
  "$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")" \
  'checkscratch'

echo
echo "Cleanup"
check "remove_server takes the profile with it" \
  "$(tool checkrw remove_server '{"id":"checkscratch"}')" '"removed" : true'
absent "and the profile is gone" \
  "$(tool checkrw list_profiles '{"server":"checkscratch"}')" '"name" : "one"'

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d/%d passed\033[0m\n' "$pass" "$pass"
else
  printf '\033[31m%d/%d passed, %d failed\033[0m\n' "$pass" "$((pass + fail))" "$fail"
fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
