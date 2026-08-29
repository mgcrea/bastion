#!/usr/bin/env bash
# Assert that the built Bastion listens only on loopback, and refuses a request
# from a web page or a rebound name.
#
# This replaces cupertino's `scripts/audit-network.sh`, and the replacement was
# forced: that script asserted the app made no network calls at all, and Bastion
# has to open a listening socket, so the claim is gone. It could not simply be
# dropped — "a marketing claim CI can check" is the property worth keeping, not
# the particular claim — so this asserts the security rules in Gateway.swift
# instead:
#
#   1. bind 127.0.0.1 explicitly, never 0.0.0.0
#   2. validate Origin
#   3. validate Host (anti-DNS-rebinding)
#   4. per-client bearer token
#   5. no secret in any file a client reads
#
# Rules 2 and 3 are why this exists at all. CVE-2025-49596 was Anthropic's own
# MCP Inspector: a listener, no CSRF protection, and a visited web page could
# reach it and execute code. The rust-sdk and FastMCP DNS-rebinding advisories
# share the root cause — no rebinding protection by default on localhost.
# Bastion holds every credential the user owns, so these are asserted rather
# than intended.
#
#   scripts/audit-listener.sh [path/to/Bastion.app]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/apps/apple/.build/Build/Products/Debug/Bastion.app}"
BINARY="$APP/Contents/MacOS/Bastion"
PORT="${BASTION_PORT:-8720}"

fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
pass() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
FAILURES=0

[ -x "$BINARY" ] || { echo "no build at $APP — run \`make app\` first"; exit 2; }

echo ""
echo "Source rules"

# ── Rule 1, statically. The runtime check below proves what this build does;
# this proves the code cannot be talked into doing otherwise by a setting.
if grep -rn "INADDR_ANY\|\"0\.0\.0\.0\"" "$ROOT/apps/apple/Bastion" >/dev/null 2>&1; then
  fail "the source mentions INADDR_ANY or 0.0.0.0"
else
  pass "no INADDR_ANY or 0.0.0.0 anywhere in the app source"
fi

if grep -qn "INADDR_LOOPBACK" "$ROOT/apps/apple/Bastion/Gateway.swift"; then
  pass "the listener binds INADDR_LOOPBACK"
else
  fail "Gateway.swift does not bind INADDR_LOOPBACK"
fi

# ── Rule 5, statically. An entitlements file that is empty by construction is a
# checkable claim; one arrived at by deletion is not.
if grep -qn "CODE_SIGN_ENTITLEMENTS" "$ROOT/apps/apple/Bastion.xcodeproj/project.pbxproj"; then
  fail "the app target has a CODE_SIGN_ENTITLEMENTS setting"
else
  pass "no entitlements file on the app target"
fi

echo ""
echo "Runtime"

# Only ever the build under test, never a copy in /Applications: this script
# must not be able to take down the session someone is working in.
pkill -f "$BINARY" 2>/dev/null || true
sleep 1

"$BINARY" >/tmp/bastion-audit.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 0.25
done

if ! kill -0 "$PID" 2>/dev/null; then
  fail "the app exited during startup — see /tmp/bastion-audit.log"
  echo ""
  exit 1
fi

# ── Rule 1, at runtime. `lsof` on this pid alone: what any other process is
# listening on is not this app's claim to make.
LISTENING="$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$PID" 2>/dev/null | tail -n +2 || true)"
if [ -z "$LISTENING" ]; then
  fail "the app is not listening at all (expected 127.0.0.1:$PORT)"
elif printf '%s\n' "$LISTENING" | grep -qE '(\*|0\.0\.0\.0):'; then
  fail "listening on a wildcard address:"
  printf '%s\n' "$LISTENING" | sed 's/^/          /'
else
  pass "listening only on loopback"
  printf '%s\n' "$LISTENING" | sed 's/^/          /'
fi

status() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
URL="http://127.0.0.1:$PORT/health"

# ── Rule 3. A page on evil.example can point its own name at 127.0.0.1, and the
# browser will then send that name as Host. That is the one thing it cannot
# forge, which is what makes this check the one that closes rebinding.
CODE="$(status -H 'Host: evil.example' "$URL")"
if [ "$CODE" = "403" ]; then
  pass "a foreign Host is refused (403)"
else
  fail "a foreign Host returned $CODE, expected 403"
fi

# ── Rule 2. A browser always sends Origin and a page cannot suppress it.
CODE="$(status -H 'Origin: https://evil.example' "$URL")"
if [ "$CODE" = "403" ]; then
  pass "a foreign Origin is refused (403)"
else
  fail "a foreign Origin returned $CODE, expected 403"
fi

# ── The order matters as much as the checks. A rebinding attempt must get the
# same answer whether or not it also guessed a token, so the Host and Origin
# refusals have to come BEFORE authentication — otherwise a 401 tells an
# attacker their Host was accepted.
CODE="$(status -H 'Host: evil.example' -H 'Authorization: Bearer definitely-not-a-token' "$URL")"
if [ "$CODE" = "403" ]; then
  pass "a foreign Host is refused before the token is looked at"
else
  fail "a foreign Host with a bad token returned $CODE, expected 403"
fi

# ── Rule 4.
CODE="$(status "$URL")"
if [ "$CODE" = "401" ]; then
  pass "no token is refused (401)"
else
  fail "an unauthenticated request returned $CODE, expected 401"
fi

CODE="$(status -H 'Authorization: Bearer definitely-not-a-token' "$URL")"
if [ "$CODE" = "401" ]; then
  pass "a wrong token is refused (401)"
else
  fail "a wrong token returned $CODE, expected 401"
fi

# ── Rule 5, at runtime. profiles.json is the file that replaces the plaintext
# `.mcp.json` files in mgcrea-ai, so it is the one that must never hold a value
# for a variable the manifest marks secret.
SUPPORT="$HOME/Library/Application Support/io.mgcrea.bastion.debug"
PROFILES="$SUPPORT/profiles.json"
if [ -f "$PROFILES" ]; then
  LEAKED="$(node -e '
    const fs = require("node:fs");
    const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const secret = new Set(
      manifest.servers.flatMap((s) => s.env.filter((e) => e.secret).map((e) => e.name)),
    );
    const rows = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const found = [];
    for (const row of rows) {
      for (const key of Object.keys(row.values ?? {})) {
        if (secret.has(key)) found.push(`${row.name}/${row.server}: ${key}`);
      }
    }
    process.stdout.write(found.join("\n"));
  ' "$ROOT/servers.json" "$PROFILES")"
  if [ -n "$LEAKED" ]; then
    fail "profiles.json holds values for variables the manifest marks secret:"
    printf '%s\n' "$LEAKED" | sed 's/^/          /'
  else
    pass "profiles.json holds no secret values"
  fi
else
  pass "no profiles.json yet (nothing to leak)"
fi

# ── Rule 5, where it actually mattered. The `.mcp.json` files in mgcrea-ai held
# real credentials in plaintext, which is the problem Bastion was built to end,
# so "no secret in a file a client reads" is asserted against those files and
# not only against Bastion's own. Skipped when the tree is absent, which is the
# normal case in CI — this is a dogfooding check, not a build gate.
MCP_ROOT="${MCP_ROOT:-$HOME/Projects/mgcrea/mgcrea-ai}"
if [ -d "$MCP_ROOT" ]; then
  LEAKED="$(node -e '
    const fs = require("node:fs");
    const { join } = require("node:path");
    const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const secret = new Set(
      manifest.servers.flatMap((s) => s.env.filter((e) => e.secret).map((e) => e.name)),
    );
    const root = process.argv[2];
    const found = [];
    for (const dir of fs.readdirSync(root)) {
      const file = join(root, dir, ".mcp.json");
      if (!fs.existsSync(file)) continue;
      const document = JSON.parse(fs.readFileSync(file, "utf8"));
      const servers = document.mcpServers ?? document.servers ?? {};
      for (const [key, entry] of Object.entries(servers)) {
        for (const name of Object.keys(entry.env ?? {})) {
          if (secret.has(name)) found.push(`${dir}/.mcp.json ${key}: ${name}`);
        }
      }
    }
    process.stdout.write(found.join("\n"));
  ' "$ROOT/servers.json" "$MCP_ROOT")"
  if [ -n "$LEAKED" ]; then
    fail "a manifest-secret value is still in plaintext in an .mcp.json:"
    printf '%s\n' "$LEAKED" | sed 's/^/          /'
  else
    pass "no manifest-secret value in any .mcp.json under $MCP_ROOT"
  fi
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed."
  exit 1
fi
echo "All checks passed."
