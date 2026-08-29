#!/usr/bin/env bash
# Prove the gateway end to end against a real supervised server.
#
# What this asserts, and why each one is here rather than assumed:
#
#   handshake      tools/list comes back, so the spawn, the one-time initialize
#                  and the response routing all work.
#   no cross-talk  two clients send the SAME request id at the same time and
#                  each gets its own answer. Without id remapping in the
#                  supervisor this passes by luck and fails under load.
#   one child      the whole claim of the project. Four concurrent first
#                  requests must produce one process, not four — which is
#                  exactly what the first version of this did produce, and it
#                  answered every request correctly while doing it.
#   recovery       kill -9 the child mid-life; the next request must succeed
#                  and there must still be exactly one process.
#
# Needs a profile to run against. `make smoke PROFILE=prod SERVER=shopify`.
# The bridge half of this — asserting an identical tool set through
# `bastion-bridge` — arrives with the bridge.
#
# The Debug build only. This must never be able to disturb an installed copy
# that somebody is working in.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion"
SUPPORT="$HOME/Library/Application Support/io.mgcrea.bastion.debug"
PORT="${BASTION_PORT:-8720}"
PROFILE="${PROFILE:-prod}"
SERVER="${SERVER:-shopify}"
URL="http://127.0.0.1:$PORT/s/$PROFILE/$SERVER"

fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
pass() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
FAILURES=0

[ -x "$BIN" ] || { echo "no build — run \`make app\` first"; exit 2; }
[ -f "$SUPPORT/dev-token" ] || {
  echo "no gateway token at $SUPPORT/dev-token."
  echo "Drop an import.json beside it and launch the Debug app once — see DevSeed.swift."
  exit 2
}

LOG=/tmp/bastion-smoke.log
pkill -f "$BIN" 2>/dev/null || true
sleep 1
"$BIN" >"$LOG" 2>&1 &
APP=$!
trap 'kill "$APP" 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 1
TOKEN="$(cat "$SUPPORT/dev-token")"

post() {
  curl -s --max-time 90 -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$2" "$URL" >"$1"
}

# `id` and shape, read back out of the reply. Reading the id is the point of the
# cross-talk check: a reply carrying the wrong one is the exact failure that id
# remapping exists to prevent.
summarise() {
  node -e '
    let d = "";
    process.stdin.on("data", (c) => (d += c)).on("end", () => {
      try {
        const j = JSON.parse(d);
        if (j.error) return console.log(`id=${j.id} error ${j.error.message}`);
        const kind = j.result?.tools ? `tools=${j.result.tools.length}` : "call";
        console.log(`id=${j.id} ${kind}`);
      } catch {
        console.log("unparseable: " + d.slice(0, 120));
      }
    });
  ' <"$1"
}

echo ""
echo "Handshake"
post /tmp/smoke-list.json '{"jsonrpc":"2.0","id":42,"method":"tools/list"}'
RESULT="$(summarise /tmp/smoke-list.json)"
case "$RESULT" in
  "id=42 tools="*) pass "tools/list → ${RESULT#id=42 }" ;;
  *) fail "tools/list returned: $RESULT" ;;
esac

echo ""
echo "Two clients, colliding ids"
# Two DIFFERENT shapes under the same id, so a swapped reply is visible rather
# than merely suspected. The first attempt paired tools/list with resources/list
# and prompts/list, which this server does not implement — the relay was fine
# and the test was measuring the server's "Method not found".
CALL_TOOL="${CALL_TOOL:-shopify_get_shop}"
post /tmp/smoke-a.json '{"jsonrpc":"2.0","id":7,"method":"tools/list"}' & A=$!
post /tmp/smoke-b.json '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"'"$CALL_TOOL"'","arguments":{}}}' & B=$!
post /tmp/smoke-c.json '{"jsonrpc":"2.0","id":8,"method":"tools/list"}' & C=$!
post /tmp/smoke-d.json '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"'"$CALL_TOOL"'","arguments":{}}}' & D=$!
wait $A $B $C $D

# The id AND a non-error result. Matching the id alone passed vacuously the
# first time this ran: every request had failed with the same error, and each
# error dutifully carried the right id back.
for pair in "smoke-a 7" "smoke-b 7" "smoke-c 8" "smoke-d 8"; do
  set -- $pair
  GOT="$(summarise "/tmp/$1.json")"
  case "$GOT" in
    "id=$2 error"*) fail "$1: $GOT" ;;
    "id=$2 "*) pass "$1 kept its own id ($GOT)" ;;
    *) fail "$1 expected id=$2, got: $GOT" ;;
  esac
done

CHILDREN="$(pgrep -P "$APP" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$CHILDREN" = "1" ]; then
  pass "exactly one child process for four concurrent clients"
else
  fail "expected 1 child process, found $CHILDREN"
fi

SPAWNS="$(grep -c 'started (pid' "$LOG" || true)"
if [ "$SPAWNS" = "1" ]; then
  pass "exactly one spawn logged"
else
  fail "expected 1 spawn, the log shows $SPAWNS"
fi

echo ""
echo "Crash recovery"
CHILD="$(pgrep -P "$APP" | head -1)"
if [ -z "$CHILD" ]; then
  fail "no child to kill"
else
  kill -9 "$CHILD"
  sleep 1
  post /tmp/smoke-after.json '{"jsonrpc":"2.0","id":99,"method":"tools/list"}'
  GOT="$(summarise /tmp/smoke-after.json)"
  case "$GOT" in
    "id=99 tools="*) pass "recovered after kill -9 ($GOT)" ;;
    *) fail "after kill -9: $GOT" ;;
  esac
  AGAIN="$(pgrep -P "$APP" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$AGAIN" = "1" ]; then
    pass "still exactly one child process"
  else
    fail "after recovery, expected 1 child process, found $AGAIN"
  fi
  if grep -q 'server exited' "$LOG"; then
    pass "the exit was recorded"
  else
    fail "the crash was not recorded in the log"
  fi
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed."
  exit 1
fi
echo "All checks passed."
