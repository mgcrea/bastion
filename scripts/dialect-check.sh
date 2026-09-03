#!/usr/bin/env bash
# Launch the Debug build and run the dual-era conformance checks against it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion"
PORT="${BASTION_PORT:-8720}"

[ -x "$BIN" ] || { echo "no build — run \`make app\` first"; exit 2; }
pkill -f "$BIN" 2>/dev/null || true
sleep 1
# `--trial` arms the same thirty-minute window the button does. The licence
# gate refuses every request without one, and faking a key here would test a
# path no user has.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bastion-dialect.XXXXXX")"
"$BIN" --trial >"$TMP/bastion-dialect.log" 2>&1 &
APP=$!
trap 'kill "$APP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
sleep 1
node "$ROOT/scripts/dialect-check.mjs"
