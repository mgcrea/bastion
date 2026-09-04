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
BUNDLE="io.mgcrea.bastion.debug"

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

# The audit log is state this script both asserts the absence of and then
# creates, so it has to start from nothing. Moved aside rather than deleted,
# like the two files above: a developer running this must not lose a log they
# were keeping.
[ -d "$SUPPORT/audit" ] && mv "$SUPPORT/audit" "$SUPPORT/audit.builtin-check-backup"

restore() {
  kill "${APP:-0}" 2>/dev/null || true
  wait "${APP:-0}" 2>/dev/null || true
  for f in servers.json profiles.json; do
    if [ -f "$SUPPORT/$f.builtin-check-backup" ]; then
      mv "$SUPPORT/$f.builtin-check-backup" "$SUPPORT/$f"
    fi
  done
  defaults delete "$BUNDLE" auditEnabled 2>/dev/null || true
  defaults delete "$BUNDLE" auditPayloads 2>/dev/null || true
  rm -rf "$SUPPORT/audit"
  if [ -d "$SUPPORT/audit.builtin-check-backup" ]; then
    mv "$SUPPORT/audit.builtin-check-backup" "$SUPPORT/audit"
  fi
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
    if not (p.get("server") == "bastion" and p.get("name") in ("checkro", "checkrw", "checknosy"))
]
# Two profiles of one server, which is also a check that the write gate is per
# profile rather than per server: same tools, same install, different answer.
profiles.append({"name": "checkro", "server": "bastion", "values": {}, "allowWrites": False})
profiles.append({"name": "checkrw", "server": "bastion", "values": {}, "allowWrites": True})
# A third, for the scoping check: what one profile's agent may read of another's.
# Seeded with an explicit captureMode, which is also the fixture for the
# preservation check further down.
profiles.append({
    "name": "checknosy", "server": "bastion", "values": {}, "allowWrites": True,
    "captureMode": "argumentsAndResults",
})
json.dump(profiles, open(os.path.join(support, "profiles.json"), "w"), indent=2)
PY

pkill -f "$BIN" 2>/dev/null || true
sleep 1
# Deliberately NOT `--trial`. The licence carve-out is one of the things under
# test, and arming a trial would hide it.
#
# `-gatewayPort` goes in as a launch argument, the same way `audit-listener.sh`
# passes it and for the same reason: without it, BASTION_PORT=8799 moves only
# the curl below, the build under test still tries 8720, fails to bind beside a
# Bastion someone is working in, and every assertion lands on that other copy —
# which answers about ITS servers and ITS profiles, so the whole run fails
# saying the fixture profiles do not exist.
"$BIN" -gatewayPort "$PORT" >/tmp/bastion-builtin.log 2>&1 &
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
# JSON escaped inside a JSON string, where `"name":"one"` is spelled
# `\"name\":\"one\"` and every needle is unreadable.
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
absent "writes off hides update_server"       "$RO" 'update_server'
check  "writes on lists remove_server"        "$RW" 'remove_server'
check  "writes on lists set_credential"       "$RW" 'set_credential'
check  "writes on lists update_server"        "$RW" 'update_server'
# The one read tool that reaches the network. It is a read tool because a
# `--dry-run` writes nothing — but that makes it the first thing a read-only
# profile can use to cause an outbound request, so which side of the gate it
# lands on is a decision worth pinning rather than inferring from the table.
check  "writes off still lists check_server_update" "$RO" 'check_server_update'
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
check "update_server refuses bastion" \
  "$(tool checkrw update_server '{"id":"bastion"}')" 'nothing to update'
check "check_server_update refuses bastion" \
  "$(tool checkro check_server_update '{"id":"bastion"}')" 'nothing to update'
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
echo "The audit log records arguments, and never a credential"
# The log now carries what a tool was called with, which puts `set_credential`
# — whose argument IS the secret — in the one place a model can read back.
# `CallCapture.neverCapture` is what stops it; this is the assertion that says
# so, and it is the reason THE WALL survived the feature.
ACTIVITY="$(tool checkrw recent_activity '{"limit":200}')"
check  "recent_activity records the call"     "$ACTIVITY" 'set_credential'
absent "and never the credential it carried"  "$ACTIVITY" 's3cr3t-canary'
# An ordinary tool's arguments ARE recorded, or the check above would pass on a
# build that simply records nothing.
tool checkrw get_server '{"id":"checkscratch"}' >/dev/null
check "an ordinary tool's arguments are recorded" \
  "$(tool checkrw recent_activity '{"limit":200}')" 'checkscratch'

echo
echo "With the audit log off, a payload never reaches disk"
# The DEFAULT guarantee, and the one most people rely on without knowing it:
# with the Audit pane untouched, the Activity window is a ring in memory and
# nothing outlives the app. It is not a property of intent — `hostLog` mirrors
# every line to stderr, which for a LaunchServices-started app outlives the
# process and lands outside Bastion's 0o700 directory — so `hostCall` keeps
# payloads off it deliberately, and this is what says it worked. The canary is a
# server id that exists nowhere, so a hit anywhere can only be the argument.
#
# `list_profiles` rather than `get_server`: a tool that REFUSES names what it
# was given in its error sentence, and that sentence is an ordinary log line
# that has always gone to stderr. This has to be a call that succeeds, or the
# check measures the error message instead of the capture path.
tool checkrw list_profiles '{"server":"payload-canary-zzz"}' >/dev/null
check  "the argument is captured in memory" \
  "$(tool checkrw recent_activity '{"limit":200}')" 'payload-canary-zzz'
absent "and never written under Application Support" \
  "$(grep -rl 'payload-canary-zzz' "$SUPPORT" 2>/dev/null || true)" 'payload-canary-zzz'
absent "and never mirrored to stderr" \
  "$(cat /tmp/bastion-builtin.log)" 'payload-canary-zzz'
absent "and no audit directory is created" \
  "$(ls "$SUPPORT/audit" 2>/dev/null || true)" 'jsonl'

echo
echo "With the audit log on, the record is on disk and the chain holds"
# The other half of the same claim. Relaunched with the log on, because the two
# switches are read as defaults and this asserts what they actually do — not
# that a setting exists.
kill "$APP" 2>/dev/null || true
wait "$APP" 2>/dev/null || true
sleep 1
defaults write "$BUNDLE" auditEnabled -bool true
defaults write "$BUNDLE" auditPayloads -bool true
"$BIN" -gatewayPort "$PORT" >>/tmp/bastion-builtin.log 2>&1 &
APP=$!
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 1

tool checkrw list_profiles '{"server":"ondisk-canary-zzz"}' >/dev/null
sleep 1
SEGMENT="$(ls "$SUPPORT"/audit/*.jsonl 2>/dev/null | head -1)"
check  "a segment is written"            "${SEGMENT:-none}" '.jsonl'
check  "and holds the call"              "$(cat "$SEGMENT" 2>/dev/null)" 'list_profiles'
check  "with the argument"               "$(cat "$SEGMENT" 2>/dev/null)" 'ondisk-canary-zzz'
check  "each record carries a link"      "$(cat "$SEGMENT" 2>/dev/null)" '"prev"'
check  "and its own hash"                "$(cat "$SEGMENT" 2>/dev/null)" '"hash"'
# 0600, because this file now holds what tools were called with. `.atomic`
# would have silently reset it to 0644, which is why the writer appends.
#
# `/usr/bin/stat` by full path: a GNU coreutils `stat` earlier on PATH reads -f
# as --file-system and prints block counts, so this asserted against whatever
# Homebrew had installed rather than against the file.
check  "the segment is readable only by its owner" \
  "$(/usr/bin/stat -f '%Lp' "$SEGMENT" 2>/dev/null)" '600'
# And the wall still stands: a credential is not payload, whatever is on disk.
tool checkrw set_credential '{"profile":"one","server":"checkscratch","variable":"CHECK_TOKEN","value":"s3cr3t-canary"}' >/dev/null 2>&1 || true
sleep 1
absent "a credential still never reaches the file" \
  "$(cat "$SUPPORT"/audit/*.jsonl 2>/dev/null)" 's3cr3t-canary'

defaults delete "$BUNDLE" auditEnabled 2>/dev/null || true
defaults delete "$BUNDLE" auditPayloads 2>/dev/null || true

echo
echo "recent_activity is scoped to the profile that asked"
# `origin` used to be a filter rather than a scope, so any profile's agent
# could read every other profile's lines. Harmless while a line was a tool
# name; a cross-profile leak the moment lines carry arguments.
SCOPED="$(tool checknosy recent_activity '{"limit":200}')"
absent "another profile's lines are not reported" "$SCOPED" 'checkrw/bastion'
absent "nor their arguments"                      "$SCOPED" 'checkscratch'
check  "its own lines still are"                  "$SCOPED" 'checknosy/bastion'
# And asking for another profile by name is refused rather than obeyed.
absent "naming another profile does not widen the scope" \
  "$(tool checknosy recent_activity '{"limit":200,"origin":"checkrw/bastion"}')" 'checkscratch'

# A profile's recording setting is not something this tool takes, so editing an
# unrelated field must carry it rather than rebuild the profile without it.
# Silent either way until someone notices their choice was undone.
tool checkrw upsert_profile '{"name":"checknosy","server":"bastion","allow_writes":true}' >/dev/null
check "upsert_profile preserves a capture setting it was not given" \
  "$(cat "$SUPPORT/profiles.json")" 'argumentsAndResults'

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
"$BIN" --trial -gatewayPort "$PORT" >>/tmp/bastion-builtin.log 2>&1 &
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
  "$(tool checkrw list_profiles '{"server":"checkscratch"}')" '"name":"one"'

tool checkrw enable_server '{"id":"checkscratch"}' >/dev/null
check "and it answers again once enabled" \
  "$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")" \
  'checkscratch'

echo
echo "Updating"
# `checkscratch` names a package that is not on npm, so nothing here reaches the
# registry: both tools refuse before they would start one. That is the point of
# testing this end — an assertion that had to download something would be an
# assertion about whether npm was reachable today.
check "check_server_update refuses a server with no code on disk" \
  "$(tool checkro check_server_update '{"id":"checkscratch"}')" 'no code on disk yet'
check "and names the tool that fixes it" \
  "$(tool checkro check_server_update '{"id":"checkscratch"}')" 'update_server'
check "an unknown id is refused rather than checked" \
  "$(tool checkro check_server_update '{"id":"nope-zzz"}')" 'not in your server list'
check "update_server refuses an unknown id" \
  "$(tool checkrw update_server '{"id":"nope-zzz"}')" 'not in your server list'
# Nothing has asked npm anything, and `availability` is in-memory only, so the
# honest answer is a missing key rather than a confident "up to date".
absent "get_server claims no update state before a check has run" \
  "$(tool checkrw get_server '{"id":"checkscratch"}')" '"state":"up-to-date"'
absent "and list_servers advertises no version to update to" \
  "$(tool checkrw list_servers '{}')" 'update_available'

echo
echo "Cleanup"
check "remove_server takes the profile with it" \
  "$(tool checkrw remove_server '{"id":"checkscratch"}')" '"removed":true'
absent "and the profile is gone" \
  "$(tool checkrw list_profiles '{"server":"checkscratch"}')" '"name":"one"'

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d/%d passed\033[0m\n' "$pass" "$pass"
else
  printf '\033[31m%d/%d passed, %d failed\033[0m\n' "$pass" "$((pass + fail))" "$fail"
fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
