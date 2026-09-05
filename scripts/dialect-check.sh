#!/usr/bin/env bash
# Launch the Debug build and run the dual-era conformance checks against it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion"
PORT="${BASTION_PORT:-8720}"

[ -x "$BIN" ] || { echo "no build — run \`make app\` first"; exit 2; }
# Only ever the build under test, never a copy in /Applications: this script
# must not be able to take down the session someone is working in.
pkill -f "$BIN" 2>/dev/null || true
sleep 1
# `--trial` arms the same thirty-minute window the button does. The licence
# gate refuses every request without one, and faking a key here would test a
# path no user has.
#
# `-gatewayPort` goes in as a launch argument, the same as `audit-listener.sh`
# passes it. Without it BASTION_PORT moved only the probe and the URL the
# checks fetch, never the app — so a non-default port could never work at all,
# and on the default the build under test failed to bind against a Bastion
# someone is working in on 8720 and every check below quietly landed on THAT
# copy, reporting on its dialect instead of this one's.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bastion-dialect.XXXXXX")"
LOG="$TMP/bastion-dialect.log"
"$BIN" --trial -gatewayPort "$PORT" >"$LOG" 2>&1 &
APP=$!
trap 'kill "$APP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done

if ! kill -0 "$APP" 2>/dev/null; then
  echo "the app exited during startup:"
  sed 's/^/  /' "$LOG"
  exit 1
fi

# The listener on this port must belong to the pid we just started. `lsof` on
# that pid alone, because a port answering is not the same as OUR app
# answering, and a check that silently grades another build is worse than one
# that does not run.
if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -a -p "$APP" >/dev/null 2>&1; then
  echo "127.0.0.1:$PORT is not held by the build under test — refusing to check another copy."
  echo "Something else is on it (a Bastion in /Applications holds 8720 by default);"
  echo "give this run its own with BASTION_PORT=8799."
  exit 1
fi

sleep 1
node "$ROOT/scripts/dialect-check.mjs"
