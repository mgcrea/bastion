#!/usr/bin/env bash
# Assert configuration sync end to end against a running Debug build.
#
# The Debug build carries no iCloud entitlement, so it cannot reach the real
# key-value store. `-syncCloudFile <path>` swaps in a JSON file with the same
# keys and values, which this script seeds, reads and empties. Everything
# between the file and the stores is the code the Release build runs.
#
# What it holds:
#
#   ARRIVAL    what another Mac wrote lands here: a catalog server, a profile
#              without the per-Mac value it was sent with, a workspace, and a
#              custom server that waits for a yes before it runs.
#   SENDING    a change made here reaches the cloud, from this Mac, with a
#              rename carrying `was` and a removal leaving a tombstone.
#   RESTRAINT  a value from a newer Bastion is left byte for byte; a relaunch
#              with nothing changed writes nothing; a deleted store file is
#              filled back rather than deleted everywhere; an emptied cloud
#              deletes nothing here.
#
# Runs against Debug's own Application Support, backed up first and put back
# exactly as found on the way out, like `builtin-check.sh`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion"
PORT="${BASTION_PORT:-8720}"
SUPPORT="$HOME/Library/Application Support/io.mgcrea.bastion.debug"
BUNDLE="io.mgcrea.bastion.debug"
WORK="$(mktemp -d)"
CLOUD="$WORK/cloud.json"
LOG="$WORK/bastion.log"
MAC="$(scutil --get ComputerName)"
FILES="servers.json profiles.json workspaces.json skill-sources.json skills.json sync-state.json"

[ -x "$BIN" ] || { echo "no build — run \`make app\` first"; exit 2; }

pass=0 fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
# `check <label> <haystack> <needle>`
check() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected '$3' in: $2" ;; esac; }
absent() { case "$2" in *"$3"*) bad "$1 — '$3' should not be there" ;; *) ok "$1" ;; esac; }

mkdir -p "$SUPPORT"
for f in $FILES; do
  [ -f "$SUPPORT/$f" ] && cp -p "$SUPPORT/$f" "$WORK/$f.backup"
done
SYNC_DEFAULT="$(defaults read "$BUNDLE" iCloudSyncEnabled 2>/dev/null || true)"
LAZY_TOOLS="$(defaults read "$BUNDLE" lazyToolsDefault 2>/dev/null || true)"
defaults write "$BUNDLE" iCloudSyncEnabled -bool true
defaults write "$BUNDLE" lazyToolsDefault -bool false

stop_app() {
  kill "${APP:-0}" 2>/dev/null || true
  wait "${APP:-0}" 2>/dev/null || true
  APP=0
}

restore() {
  # The arrival leaves a waiting approval in the Debug keychain item; removing
  # the server is what forgets it.
  if [ "${APP:-0}" != 0 ]; then
    tool synccheck remove_server '{"id":"synccheck-remote"}' >/dev/null 2>&1
    tool synccheck remove_server '{"id":"synccheck-local"}' >/dev/null 2>&1
  fi
  stop_app
  for f in $FILES; do
    if [ -f "$WORK/$f.backup" ]; then cp -p "$WORK/$f.backup" "$SUPPORT/$f"; else rm -f "$SUPPORT/$f"; fi
  done
  for pair in "iCloudSyncEnabled:$SYNC_DEFAULT" "lazyToolsDefault:$LAZY_TOOLS"; do
    key="${pair%%:*}" value="${pair#*:}"
    case "$value" in
      1) defaults write "$BUNDLE" "$key" -bool true ;;
      0) defaults write "$BUNDLE" "$key" -bool false ;;
      *) defaults delete "$BUNDLE" "$key" 2>/dev/null || true ;;
    esac
  done
  rm -rf "$WORK"
}
trap restore EXIT

# The built-in server, on, with a profile that may write, so the tools below
# can be called. Everything else in the developer's files stays as it is and
# is pushed to the file cloud like any other local configuration.
python3 - "$SUPPORT" <<'PY'
import json, os, sys
support = sys.argv[1]
def load(name, default):
    try:
        return json.load(open(os.path.join(support, name)))
    except Exception:
        return default
servers = [r for r in load("servers.json", []) if r.get("id") not in ("bastion", "linear", "npm", "synccheck-remote")]
servers.insert(0, {"id": "bastion", "enabled": True})
# A catalog id this build does not ship: what an older or newer build left.
servers = [r for r in servers if r.get("id") not in ("synccheck-retired", "synccheck-local")]
servers.append({"id": "synccheck-retired", "enabled": True})
# A custom server set up on this Mac before sync, never recorded as allowed.
servers.append({"id": "synccheck-local", "enabled": True, "definition": {
    "displayName": "Sync Check Local", "summary": "here", "url": "https://local.example.com/mcp",
    "dialect": "2025-11-25", "stateEnv": [],
    "env": [{"name": "SYNC_LOCAL_TOKEN", "required": False, "secret": True, "description": "token",
             "header": {"name": "Authorization", "format": "Bearer {value}"}}]}})
json.dump(servers, open(os.path.join(support, "servers.json"), "w"), indent=2)
profiles = [p for p in load("profiles.json", []) if not p.get("name", "").startswith("synccheck")]
profiles.append({"name": "synccheck", "server": "bastion", "values": {}, "allowWrites": True})
json.dump(profiles, open(os.path.join(support, "profiles.json"), "w"), indent=2)
workspaces = [w for w in load("workspaces.json", []) if w.get("name") not in ("synccheck", "synccheck-garbled")]
workspaces.append({"name": "synccheck-garbled", "folders": [], "profiles": [], "skills": []})
json.dump(workspaces, open(os.path.join(support, "workspaces.json"), "w"), indent=2)
PY

# What this Mac agreed with the cloud last time: both entities above, and the
# epoch the cloud carries. Without it every check below would be a first run.
EPOCH="synccheck-epoch-1"
AGREED="2026-01-01T00:00:00.000Z"
python3 - "$SUPPORT/sync-state.json" "$EPOCH" "$AGREED" <<'PY'
import json, sys
path, epoch, at = sys.argv[1:4]
entry = lambda entity: {"at": at, "from": "Other Mac", "entity": entity, "carry": {}, "held": False}
json.dump({"epoch": epoch, "snapshot": {
    "server": {"synccheck-retired": entry({"enabled": True})},
    "workspace": {"synccheck-garbled": entry({"name": "synccheck-garbled", "folders": [], "profiles": [], "skills": []})},
}}, open(path, "w"))
PY

# Another Mac's writes. Stamped a minute ahead, so they are newer than the
# files just written and win the first-run merge.
python3 - "$CLOUD" "$EPOCH" "$AGREED" <<'PY'
import json, sys, datetime
def key(kind, ident):
    h = 0xcbf29ce484222325
    for b in ident.encode():
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{kind}/{h:016x}"
at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def env(kind, ident, entity, v=1):
    return {"v": v, "kind": kind, "id": ident, "at": at, "from": "Other Mac", "deleted": False, "entity": entity}
items = [
    env("server", "linear", {"enabled": True}),
    # A child catalog server, off, so nothing is downloaded.
    env("server", "npm", {"enabled": False}),
    env("profile", "synccheck/npm", {"name": "synccheck", "server": "npm", "allowWrites": False,
        "values": {"NPM_REGISTRY": "https://registry.example", "NPM_BIN": "/tmp/not-npm"}}),
    env("workspace", "synccheck", {"name": "synccheck", "folders": ["~/synccheck-nowhere"], "profiles": [], "skills": []}),
    env("server", "synccheck-remote", {"enabled": True, "definition": {
        "displayName": "Sync Check Remote", "summary": "check", "url": "https://mcp.example.com/mcp",
        "dialect": "2025-11-25", "stateEnv": [],
        "env": [{"name": "SYNC_CHECK_TOKEN", "required": False, "secret": True, "description": "token",
                 "header": {"name": "Authorization", "format": "Bearer {value}"}}]}}),
    env("profile", "synccheck/synccheck-remote", {"name": "synccheck", "server": "synccheck-remote", "allowWrites": False, "values": {}}),
    # The same server as edited on the other Mac: same URL, another summary.
    env("server", "synccheck-local", {"enabled": True, "definition": {
        "displayName": "Sync Check Local", "summary": "edited elsewhere", "url": "https://local.example.com/mcp",
        "dialect": "2025-11-25", "stateEnv": [],
        "env": [{"name": "SYNC_LOCAL_TOKEN", "required": False, "secret": True, "description": "token",
                 "header": {"name": "Authorization", "format": "Bearer {value}"}}]}}),
    env("server", "synccheck-future", {"enabled": True, "shape": "from a newer Bastion"}, v=2),
]
cloud = {key(e["kind"], e["id"]): json.dumps(e, sort_keys=True) for e in items}
retired = {"v": 1, "kind": "server", "id": "synccheck-retired", "at": sys.argv[3], "from": "Other Mac", "deleted": False, "entity": {"enabled": True}}
cloud[key("server", "synccheck-retired")] = json.dumps(retired, sort_keys=True)
# A value under a key this build cannot read at all.
cloud[key("workspace", "synccheck-garbled")] = "not an envelope"
cloud["epoch"] = sys.argv[2]
json.dump(cloud, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
FUTURE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print([v for v in d.values() if 'synccheck-future' in v][0])" "$CLOUD")"

launch() {
  pkill -f "$BIN" 2>/dev/null || true
  sleep 1
  # `--trial`, so a relayed call reaches the supervisor rather than stopping
  # at the licence: the waiting-server refusal is what is under test.
  "$BIN" --trial -gatewayPort "$PORT" -syncCloudFile "$CLOUD" >>"$LOG" 2>&1 &
  APP=$!
  for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
  sleep 1
}

rpc() {
  curl -s --max-time 10 \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$3" "http://127.0.0.1:$PORT/s/$1/$2"
}
tool() {
  rpc "$1" bastion "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}" \
    | python3 -c 'import sys,json
d=json.load(sys.stdin)
c=d.get("result",{}).get("content")
print(c[0]["text"] if c else json.dumps(d))'
}
# `envelope <kind> <id>`: the cloud's envelope for one entity, or nothing.
envelope() {
  python3 - "$CLOUD" "$1" "$2" <<'PY'
import json, sys
cloud = json.load(open(sys.argv[1]))
for value in cloud.values():
    try:
        e = json.loads(value)
    except ValueError:
        continue  # the epoch, and a value no build can read
    if isinstance(e, dict) and e.get("kind") == sys.argv[2] and e.get("id") == sys.argv[3]:
        print(json.dumps(e, sort_keys=True))
PY
}

launch
TOKEN="$(cat "$SUPPORT/dev-token" 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "no dev-token in $SUPPORT"; exit 2; }

echo
echo "Arrival"
servers="$(tool synccheck list_servers '{}')"
check "a catalog server arrives" "$servers" '"id":"linear"'
check "a custom server arrives, waiting" "$servers" '"awaiting_approval"'
check "and says where from" "$servers" '"from":"Other Mac"'
linear="$(tool synccheck get_server '{"id":"linear"}')"
check "the catalog server arrives switched on" "$linear" '"enabled":true'
profiles="$(tool synccheck list_profiles '{"server":"npm"}')"
check "a profile arrives for a server that is off" "$profiles" 'synccheck'
check "with its synced value" "$profiles" 'https://registry.example'
absent "but not the per-Mac value it was sent with" "$profiles" '/tmp/not-npm'
check "a workspace arrives" "$(tool synccheck list_workspaces '{}')" 'synccheck-nowhere'
waiting="$(rpc synccheck synccheck-remote '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
check "a waiting server is refused before it is reached" "$waiting" 'has not been allowed on this Mac'


local_server="$(tool synccheck get_server '{"id":"synccheck-local"}')"
check "a server set up here takes the other Mac's edit" "$local_server" 'edited elsewhere'
absent "and does not wait for a yes it already had" "$local_server" 'awaiting_approval'

echo
echo "What this build cannot read or resolve"
check "a catalog id this build does not ship is never sent as a deletion" "$(envelope server synccheck-retired)" '"deleted": false'
check "and stays in servers.json" "$(cat "$SUPPORT/servers.json")" 'synccheck-retired'
check "an unreadable key is not taken as a deletion" "$(tool synccheck list_workspaces '{}')" 'synccheck-garbled'
check "and is left as it was" "$(cat "$CLOUD")" 'not an envelope'

echo
echo "Sending"
tool synccheck upsert_profile '{"name":"synccheck","server":"npm","values":{"NPM_REGISTRY":"https://changed.example"}}' >/dev/null
sleep 3
sent="$(envelope profile synccheck/npm)"
check "a local edit reaches the cloud" "$sent" 'https://changed.example'
check "from this Mac" "$sent" "\"from\": \"$MAC\""
absent "still without the per-Mac value" "$sent" 'NPM_BIN'
tool synccheck rename_profile '{"name":"synccheck","server":"npm","new_name":"synccheck-renamed"}' >/dev/null
sleep 3
check "a rename leaves a tombstone for the old name" "$(envelope profile synccheck/npm)" '"deleted": true'
check "and carries was on the new one" "$(envelope profile synccheck-renamed/npm)" '"was": "synccheck/npm"'
tool synccheck remove_profile '{"name":"synccheck-renamed","server":"npm"}' >/dev/null
sleep 3
check "a removal leaves a tombstone" "$(envelope profile synccheck-renamed/npm)" '"deleted": true'


echo
echo "A rename that arrives as its tombstone first"
tool synccheck upsert_profile '{"name":"synccheck-r","server":"npm","values":{"NPM_REGISTRY":"https://r.example"}}' >/dev/null
tool synccheck set_credential '{"profile":"synccheck-r","server":"npm","variable":"NPM_TOKEN","value":"synccheck-secret"}' >/dev/null
sleep 3
stop_app
python3 - "$CLOUD" <<'PY'
import json, sys, datetime
cloud = json.load(open(sys.argv[1]))
at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
for k, v in list(cloud.items()):
    try:
        e = json.loads(v)
    except Exception:
        continue
    if isinstance(e, dict) and e.get("kind") == "profile" and e.get("id") == "synccheck-r/npm":
        cloud[k] = json.dumps({"v": 1, "kind": "profile", "id": "synccheck-r/npm", "at": at, "from": "Other Mac",
                               "deleted": True, "to": "synccheck-r2/npm"}, sort_keys=True)
json.dump(cloud, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
launch
renamed="$(tool synccheck list_profiles '{"server":"npm"}' | python3 -c 'import sys,json
rows=json.load(sys.stdin)
rows=rows if isinstance(rows,list) else rows.get("profiles",[])
print(" ".join(sorted("%s:%s" % (r["name"], ",".join(r.get("secrets_set",[]))) for r in rows)))')"
check "the profile is renamed here, not removed" "$renamed" 'synccheck-r2:'
check "and its credential moved with it" "$renamed" 'synccheck-r2:NPM_TOKEN'
tool synccheck remove_profile '{"name":"synccheck-r2","server":"npm"}' >/dev/null
tool synccheck remove_profile '{"name":"synccheck-r","server":"npm"}' >/dev/null

echo
echo "An epoch this Mac does not know"
stop_app
python3 - "$CLOUD" <<'PY'
import json, sys
cloud = json.load(open(sys.argv[1]))
cloud["epoch"] = "written-after-a-removal"
json.dump(cloud, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
launch
tool synccheck upsert_profile '{"name":"synccheck-epoch","server":"npm","values":{"NPM_REGISTRY":"https://e.example"}}' >/dev/null
sleep 3
absent "sync pauses rather than reading missing keys as deletions" "$(envelope profile synccheck-epoch/npm)" 'synccheck-epoch'
check "and this Mac keeps its profiles" "$(tool synccheck list_profiles '{"server":"npm"}')" 'synccheck-epoch'
tool synccheck remove_profile '{"name":"synccheck-epoch","server":"npm"}' >/dev/null
stop_app
python3 - "$CLOUD" "$EPOCH" <<'PY'
import json, sys
cloud = json.load(open(sys.argv[1]))
cloud["epoch"] = sys.argv[2]
json.dump(cloud, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
# The pause outlives a relaunch, so it is cleared the way a person would:
# by switching sync off, which answers an emptied-cloud question.
python3 - "$SUPPORT/sync-state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
state.pop("pause", None)
json.dump(state, open(sys.argv[1], "w"))
PY
launch

echo
echo "Restraint"
FUTURE_NOW="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print([v for v in d.values() if 'synccheck-future' in v][0])" "$CLOUD")"
if [ "$FUTURE" = "$FUTURE_NOW" ]; then ok "a newer Bastion's value is left byte for byte"; else bad "the v2 value changed: $FUTURE_NOW"; fi
absent "and was not applied" "$(tool synccheck list_servers '{}')" 'synccheck-future'

stop_app
before="$(shasum -a 256 "$CLOUD")"
launch
sleep 2
after="$(shasum -a 256 "$CLOUD")"
if [ "$before" = "$after" ]; then ok "a relaunch with nothing changed writes nothing"; else bad "the cloud changed across an idle relaunch"; fi

stop_app
rm -f "$SUPPORT/workspaces.json"
launch
sleep 2
check "a deleted store file is filled back from the cloud" "$(tool synccheck list_workspaces '{}')" 'synccheck-nowhere'
absent "and nothing was deleted everywhere" "$(envelope workspace synccheck)" '"deleted": true'

stop_app
echo '{}' >"$CLOUD"
launch
sleep 2
check "an emptied cloud deletes nothing here" "$(tool synccheck list_profiles '{"server":"bastion"}')" 'synccheck'
check "and writes nothing back until asked" "$(cat "$CLOUD")" '{}'

echo
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d/%d passed\033[0m\n' "$pass" "$total"
else
  printf '\033[31m%d/%d passed\033[0m\n' "$pass" "$total"
  echo "app log: $LOG (kept until exit)"
  tail -30 "$LOG"
  exit 1
fi
