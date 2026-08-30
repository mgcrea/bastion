#!/usr/bin/env bash
# Assert that a built bundle can install and start a server.
#
# Ported from cupertino, where the comment on the call site reads: "a signature
# over a bundle whose servers cannot start is precisely what shipped three
# times, and it is worth nothing." This runs BEFORE signing, at the first point
# where the runtime and the package manager it installs with sit side by side.
#
# ## What changed, and why this is still the same check
#
# It used to walk `Contents/Resources/servers` and start each staged server.
# Nothing is staged any more — the bundle carries node and npm, and a server
# arrives when a user asks for one — so the thing that can be broken at build
# time moved. It is now the INSTALL PATH: an npm that cannot resolve a package
# under the embedded node produces an app where every server is one spinner and
# one error message, and no structural check of the bundle would notice.
#
# So this does end to end what `ServerInstaller` does at runtime, with the same
# two binaries, into a throwaway prefix:
#
#   1. the embedded node runs                    (an ABI or lipo fault)
#   2. the embedded npm runs under it            (a truncated ditto, a bad pair)
#   3. npm installs a real catalog server        (the install path itself)
#   4. the server's declared bin starts          (module resolution)
#
# Functional, not structural. Checking that `Resources/npm/bin/npm-cli.js`
# exists only catches the shapes of breakage somebody thought to look for.
#
# ## What counts as passing, at step 4
#
# Two outcomes are fine and one is not, and the difference is the whole value of
# running this at all:
#
#   answered initialize   the server loaded and is ready. Best case.
#   printed its banner    the server loaded, ran, and then exited on its own
#                         config validation because no credentials were set.
#                         Module resolution worked, which is what an INSTALL can
#                         get wrong. Not a packaging fault.
#   neither               broken. ERR_MODULE_NOT_FOUND, a missing dist, an ABI
#                         mismatch — the code never ran.
#
# The banner is the signal because every one of these servers prints
# `[<name>-mcp] @mgcrea/... (git ...)` to stderr before it validates anything.
#
#   scripts/verify-servers.sh path/to/Bastion.app
#
# `VERIFY_OFFLINE=1` keeps steps 1 and 2 and skips the two that need the
# registry. For building on a plane, not for building a release: a bundle whose
# install path was never exercised is the bundle this script exists to catch.

set -uo pipefail

APP="${1:?usage: verify-servers.sh path/to/Bastion.app}"
NODE="$APP/Contents/Resources/node"
NPM="$APP/Contents/Resources/npm/bin/npm-cli.js"
# Read-only, published, and the first server the build order takes end to end —
# so a failure here is the bundle's fault rather than the probe's.
PROBE="${VERIFY_PROBE:-@mgcrea/mcp-shopify}"

[ -x "$NODE" ] || { echo "  no embedded node at $NODE"; exit 1; }
[ -f "$NPM" ] || { echo "  no embedded npm at $NPM"; exit 1; }

# 1 — the runtime runs. Under `arch -x86_64` too when the slice is there, because
# a lipo that produced a bundle missing an architecture passes every check that
# only runs the native one.
node_version="$("$NODE" --version 2>&1)" || {
  echo "  the embedded node does not run: $node_version"; exit 1; }
echo "  node $node_version"

for arch in $(lipo -archs "$NODE" 2>/dev/null); do
  case "$arch" in
    arm64|x86_64) ;;
    *) continue ;;
  esac
  if ! arch -"$arch" "$NODE" --version >/dev/null 2>&1; then
    # Rosetta absent is not a bundle fault, and on an arm64 host without it the
    # x86_64 slice cannot be executed at all. Say so rather than failing.
    echo "  $arch: present, not executable here (Rosetta?)"
  else
    echo "  $arch: runs"
  fi
done

# 2 — npm runs under it.
npm_version="$("$NODE" "$NPM" --version 2>&1)" || {
  echo "  the embedded npm does not run: $npm_version"; exit 1; }
echo "  npm $npm_version"

if [ "${VERIFY_OFFLINE:-0}" = "1" ]; then
  echo "  VERIFY_OFFLINE=1 — skipping the install probe"
  exit 0
fi

# 3 — an install, exactly as ServerInstaller does one.
PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/bastion-verify.XXXXXX")" || exit 1
trap 'rm -rf "$PREFIX"' EXIT INT TERM
printf '{"name":"bastion-verify","version":"0.0.0","private":true}\n' > "$PREFIX/package.json"

if ! out="$(cd "$PREFIX" && "$NODE" "$NPM" install "$PROBE@latest" \
    --prefix "$PREFIX" --omit=dev --no-package-lock --no-audit --no-fund \
    --ignore-scripts --loglevel=error 2>&1)"; then
  echo "  $PROBE: the embedded npm could not install it"
  printf '%s\n' "$out" | sed 's/^/      /' | head -5
  exit 1
fi

# 4 — the bin the package declares, resolved the way the app resolves it rather
# than guessed at, and started under the bundled node.
script="$("$NODE" -e '
  const { join } = require("node:path");
  const dir = join(process.argv[1], "node_modules", process.argv[2]);
  const bin = require(join(dir, "package.json")).bin;
  const rel = typeof bin === "string" ? bin : Object.values(bin ?? {})[0];
  if (!rel) { process.exit(1); }
  process.stdout.write(join(dir, rel));
' "$PREFIX" "$PROBE" 2>/dev/null)" || {
  echo "  $PROBE: installed, but declares no runnable bin"; exit 1; }

err="$(mktemp)"
reply="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}' \
  | "$NODE" "$script" 2>"$err" | head -1)"

if printf '%s' "$reply" | grep -q '"serverInfo"'; then
  echo "  $PROBE: installs and starts"
elif grep -q '^\[.*-mcp\]' "$err"; then
  echo "  $PROBE: installs, loads, exits unconfigured — $(grep -m1 'fatal' "$err" | cut -c1-70)"
else
  echo "  $PROBE: FAILED — installed, but the code never ran"
  sed 's/^/      /' "$err" | head -3
  rm -f "$err"
  exit 1
fi
rm -f "$err"
echo "  the install path works under the embedded runtime"
