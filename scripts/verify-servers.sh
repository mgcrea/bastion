#!/usr/bin/env bash
# Assert that a built bundle's servers actually start.
#
# Ported from cupertino, where the comment on the call site reads: "a signature
# over a bundle whose servers cannot start is precisely what shipped three
# times, and it is worth nothing." This runs BEFORE signing, at the first point
# where the staged servers and the runtime they will be spawned under sit side
# by side.
#
# Functional, not structural. Checking that `Resources/servers/<id>/dist/cli.js`
# exists only catches the shapes of breakage somebody thought to look for.
# Starting each one under the bundled node and reading its `initialize` reply
# catches a bundle that cannot serve, whatever the reason — a missing
# dependency, an ABI mismatch, a truncated ditto.
#
# ## What counts as passing
#
# Two outcomes are fine and one is not, and the difference is the whole value of
# running this at all:
#
#   answered initialize   the server loaded and is ready. Best case.
#   printed its banner    the server loaded, ran, and then exited on its own
#                         config validation because no credentials were set.
#                         Module resolution worked, which is what a BUNDLE can
#                         get wrong. Not published-version-of-mcp-shopify's
#                         finest hour, but not a packaging fault.
#   neither               the bundle is broken. ERR_MODULE_NOT_FOUND, a missing
#                         dist, an ABI mismatch — the code never ran.
#
# The banner is the signal because every one of these servers prints
# `[<name>-mcp] @mgcrea/... (git ...)` to stderr before it validates anything.
#
#   scripts/verify-servers.sh path/to/Bastion.app

set -uo pipefail

APP="${1:?usage: verify-servers.sh path/to/Bastion.app}"
NODE="$APP/Contents/Resources/node"
SERVERS="$APP/Contents/Resources/servers"

[ -x "$NODE" ] || { echo "  no embedded node at $NODE"; exit 1; }
[ -d "$SERVERS" ] || { echo "  no staged servers at $SERVERS"; exit 1; }

FAILURES=0
FOUND=0
for dir in "$SERVERS"/*/; do
  [ -d "$dir" ] || continue
  id="$(basename "$dir")"
  FOUND=$((FOUND + 1))
  script="$dir/dist/cli.js"
  if [ ! -f "$script" ]; then
    echo "  $id: no dist/cli.js"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  # The bundled node, not the developer's. Which node runs these is the whole
  # reason one is embedded, and a check that used $PATH would prove nothing
  # about what ships.
  err="$(mktemp)"
  reply="$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}' \
    | "$NODE" "$script" 2>"$err" | head -1)"
  if printf '%s' "$reply" | grep -q '"serverInfo"'; then
    echo "  $id: starts"
  elif grep -q "^\[$id-mcp\]" "$err"; then
    # It ran far enough to introduce itself and then refused for its own
    # reasons. The bundle is sound; the server wants configuration.
    echo "  $id: loads, exits unconfigured — $(grep -m1 'fatal' "$err" | cut -c1-70)"
  else
    echo "  $id: FAILED — the code never ran"
    sed 's/^/      /' "$err" | head -3
    FAILURES=$((FAILURES + 1))
  fi
  rm -f "$err"
done

if [ "$FOUND" -eq 0 ]; then
  echo "  no servers staged — nothing to verify"
  exit 1
fi
if [ "$FAILURES" -gt 0 ]; then
  echo "  $FAILURES of $FOUND staged server(s) cannot start; refusing to sign"
  exit 1
fi
echo "  all $FOUND staged server(s) start under the embedded runtime"
