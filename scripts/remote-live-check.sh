#!/usr/bin/env bash
# Assert the remote transport end to end, against a running Debug build.
#
# The awkward part of testing this is that the security rules and the test want
# opposite things: a local fake server would live on 127.0.0.1, which
# `RemoteEndpoint` refuses BY DESIGN and must go on refusing. Adding a bypass so
# the test can pass would delete the property under test — so nothing here has
# one, and the coverage is split instead:
#
#   scripts/remote-check.swift   the rules and the SSE collapse, as pure
#                                functions, with no network and no app
#   this script                  the whole path against a REAL remote server
#
# It needs no credential. `mcp.stripe.com` answers an unauthenticated
# `initialize` with 401 and a WWW-Authenticate naming its protected-resource
# metadata, and that is a perfectly good end of the wire to test against: it
# proves DNS pre-flight, https, the POST, the profile's headers, the upstream
# status mapping and the sentence a client is left holding. What it cannot
# prove is a successful call, which needs somebody's restricted key.
#
# Network-dependent by nature, so it is not in `make audit`. Run it deliberately.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion"
PORT="${BASTION_PORT:-8720}"
SUPPORT="$HOME/Library/Application Support/io.mgcrea.bastion.debug"
[ -x "$BIN" ] || { echo "no build — run \`make app\` first"; exit 2; }

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected '$3' in: $2" ;; esac; }
absent() { case "$2" in *"$3"*) bad "$1 — '$3' should not be there" ;; *) ok "$1" ;; esac; }

# Stop any running instance BEFORE snapshotting, and wait for it to actually be
# gone. Order is load-bearing: a live Bastion writes profiles.json from memory as
# it quits, so killing it after the scratch profile was written silently restores
# the old file over it -- and the check then fails with "no profile", which reads
# as a transport bug and is not one.
pkill -f "$BIN" 2>/dev/null || true
for _ in $(seq 1 40); do pgrep -f "$BIN" >/dev/null || break; sleep 0.25; done

mkdir -p "$SUPPORT"
for f in servers.json profiles.json; do
  [ -f "$SUPPORT/$f" ] && cp "$SUPPORT/$f" "$SUPPORT/$f.remote-check-backup"
done
restore() {
  kill "${APP:-0}" 2>/dev/null || true
  wait "${APP:-0}" 2>/dev/null || true
  rm -f "$SUPPORT/import.json" "$SUPPORT/imported.json"
  security delete-generic-password \
    -s "io.mgcrea.bastion.debug.profile" \
    -a "remotecheckro/stripe/STRIPE_SECRET_KEY" >/dev/null 2>&1 || true
  for f in servers.json profiles.json; do
    if [ -f "$SUPPORT/$f.remote-check-backup" ]; then
      mv "$SUPPORT/$f.remote-check-backup" "$SUPPORT/$f"
    else
      rm -f "$SUPPORT/$f"
    fi
  done
}
trap restore EXIT

# The catalog's stripe entry, plus one scratch profile holding a key that is
# the right SHAPE and certainly not a real one.
SUPPORT="$SUPPORT" python3 <<'PY'
import json, os
support = os.environ["SUPPORT"]
def load(name, default):
    try: return json.load(open(os.path.join(support, name)))
    except Exception: return default

servers = [r for r in load("servers.json", []) if r.get("id") != "stripe"]
servers.insert(0, {"id": "stripe", "enabled": True})
json.dump(servers, open(os.path.join(support, "servers.json"), "w"), indent=2)

profiles = [p for p in load("profiles.json", [])
            if not (p.get("server") == "stripe" and p.get("name").startswith("remotecheck"))]
# Writes off, so the tool filter is under test too.
profiles.append({"name": "remotecheckro", "server": "stripe", "values": {}, "allowWrites": False})
json.dump(profiles, open(os.path.join(support, "profiles.json"), "w"), indent=2)
PY

"$BIN" --trial >/tmp/bastion-remote.log 2>&1 &
APP=$!
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 1

TOKEN="$(cat "$SUPPORT/dev-token" 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "no dev-token in $SUPPORT"; exit 2; }

rpc() {
  curl -s --max-time 30 \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$2" "http://127.0.0.1:$PORT/s/$1/stripe"
}

echo
echo "The server resolves as remote"
HEALTH=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")
check "stripe is in /health" "$HEALTH" '"stripe"'

echo
echo "A profile with no credential is told so, before anything leaves the machine"
# STRIPE_SECRET_KEY is required, so this must not reach the network at all.
OUT=$(rpc remotecheckro '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}')
check "the missing variable is named" "$OUT" "STRIPE_SECRET_KEY"
absent "and no HTTP status is quoted, because there was no request" "$OUT" "HTTP 401"

echo
echo "With a credential set, the request reaches Stripe and the refusal is legible"
# Seeded through import.json rather than the `security` CLI, and that is not a
# style preference. A Keychain item added from the command line carries no ACL
# entry for the Bastion binary, so the first read of it blocks in securityd
# waiting for a consent click nobody is there to give — and because the bearer
# token is a Keychain read too, that wedges every request the gateway has. The
# app writing its own item is the only way it ends up trusting it.
cat > "$SUPPORT/import.json" <<JSON
{
  "profiles": [
    {
      "name": "remotecheckro",
      "server": "stripe",
      "allowWrites": false,
      "values": { "STRIPE_SECRET_KEY": "rk_test_notarealkey" }
    }
  ]
}
JSON
kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
"$BIN" --trial >>/tmp/bastion-remote.log 2>&1 &
APP=$!
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 2

OUT=$(rpc remotecheckro '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}')
check "the upstream refusal comes back as a JSON-RPC error" "$OUT" '"error"'
check "it names the profile" "$OUT" "remotecheckro"
check "it says what to do about it" "$OUT" "Check it in Bastion"
absent "and it never echoes the credential" "$OUT" "rk_test_notarealkey"

echo
echo "The gateway is still answering afterwards"
# The one that would have caught the securityd wedge above: a request that
# fails upstream must not take the listener down with it.
HEALTH=$(curl -s --max-time 8 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")
check "/health still answers after a failed remote call" "$HEALTH" '"ok":true'

echo
echo "The credential stays out of everything on disk"
absent "profiles.json holds no key" "$(cat "$SUPPORT/profiles.json")" "rk_test_notarealkey"
absent "the log holds no key" "$(cat /tmp/bastion-remote.log)" "rk_test_notarealkey"
absent "import.json was consumed" "$(ls "$SUPPORT")" "import.json"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d/%d passed\033[0m\n' "$pass" "$((pass + fail))"
else
  printf '\033[31m%d/%d passed, %d failed\033[0m\n' "$pass" "$((pass + fail))" "$fail"
  exit 1
fi
