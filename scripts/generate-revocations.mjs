#!/usr/bin/env node
// Bake the revoked licence IDs into the app.
//
// Revocation lands at BUILD time, not run time, and that is the whole shape of
// it. The app makes no network connections — scripts/audit-listener.sh fails the
// build over it and the README sells it — so there is no list it can consult
// while running. A refunded key therefore keeps working until the next release
// and then stops. That is said to the buyer rather than left to be discovered:
// the EULA in apps/apple/EULA covers it at §5(a) and §6, and the site serves it
// at /terms.
//
// Generated-and-committed rather than fetched by CI. Reading D1 from the release
// job would put a network dependency in the path of shipping, so an outage at
// Cloudflare would become an outage in releases — and it would buy nothing,
// since a revocation cannot take effect before the next build either way. CI
// runs `--check` in the Manifest job to confirm the committed file is current,
// and skips even that when it has no credentials, so forks and pull requests are
// unaffected.
//
//   node scripts/generate-revocations.mjs            # rewrite the Swift file
//   node scripts/generate-revocations.mjs --check    # fail if it is stale
//   node scripts/generate-revocations.mjs --local    # against the local D1

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { renderRevocations, testDatabaseConfigured } from "./lib/revocations.mjs";

// `fileURLToPath`, not `.pathname`: the latter leaves a checkout under a path
// with a space percent-encoded, and every path built from it then misses.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TARGET = join(ROOT, "apps/apple/Bastion/Revocations.swift");
const API = join(ROOT, "apps/api");

const args = process.argv.slice(2);
const check = args.includes("--check");
const local = args.includes("--local");

// The skip is for --check only, and only for CI. A pull request from a fork has
// no secrets and neither does a clean clone; failing there would turn "we cannot
// confirm this" into "the build is broken", which it is not — the committed file
// is what the build uses.
//
// Writing is the opposite case and must never skip. A developer authenticates
// wrangler with `wrangler login`, not a token in the environment, so guarding the
// write path on CLOUDFLARE_API_TOKEN made `make revocations` print "skipped" and
// change nothing — after a refund, silently leaving the refunded key working
// while looking like it had been handled. Let wrangler's own auth decide, and
// let it fail loudly when there is none.
//
// A release tag is not a pull request. The release job needs this one, so a
// skip there — a secret renamed, rotated or dropped — would pass a notarized
// build carrying whatever list happens to be committed, refunded keys included.
// On a tag the missing token is the failure.
if (check && !local && !process.env.CLOUDFLARE_API_TOKEN) {
  if (process.env.GITHUB_REF?.startsWith("refs/tags/")) {
    console.error("FATAL: no CLOUDFLARE_API_TOKEN on a release tag, cannot confirm against D1");
    process.exit(1);
  }
  console.log("skipped: no CLOUDFLARE_API_TOKEN, cannot confirm against D1");
  process.exit(0);
}

// `rows` of one D1 database, or exit 2 naming it. `extra` selects the
// wrangler environment the binding lives in.
const read = (database, query, extra = []) => {
  try {
    const raw = execFileSync(
      "pnpm",
      [
        "exec",
        "wrangler",
        "d1",
        "execute",
        database,
        ...extra,
        local ? "--local" : "--remote",
        "--json",
        "--command",
        query,
      ],
      { cwd: API, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    // wrangler prints a banner before the JSON on some paths, so find the array
    // rather than assuming the whole of stdout is the document.
    const start = raw.indexOf("[");
    return JSON.parse(raw.slice(start))[0].results;
  } catch (error) {
    console.error(`FATAL: could not read ${database}: ${String(error?.message ?? error)}`);
    process.exit(2);
  }
};

const revoked = read(
  "bastion-licenses",
  "SELECT id FROM licenses WHERE revoked_at IS NOT NULL ORDER BY id",
);

// Every licence the test environment ever minted, revoked or not. It signs
// with the production key, so that a test purchase proves the shipped app
// accepts it — which makes each of those keys a real one, from a checkout
// anybody holding a test-mode link can complete with card 4242. Revoking all
// of them leaves the rehearsal working in the build under test and in no
// released one. Read only once wrangler.jsonc gives the database an id: before
// that it does not exist, and once it does, failing to read it is fatal like
// any other read here.
const wrangler = readFileSync(join(API, "wrangler.jsonc"), "utf8");
const rehearsed = testDatabaseConfigured(wrangler)
  ? read("bastion-licenses-test", "SELECT id FROM licenses ORDER BY id", ["--env", "test"])
  : [];

const ids = [...new Set([...revoked, ...rehearsed].map((row) => row.id).filter(Boolean))];

// Rendering, and the escaping it needs, live in scripts/lib/revocations.mjs,
// where a test runs them against the file the app compiles.
const next = renderRevocations(readFileSync(TARGET, "utf8"), ids);

if (check) {
  if (readFileSync(TARGET, "utf8") === next) {
    console.log(`ok: ${ids.length} revoked licence(s), Revocations.swift is current`);
    process.exit(0);
  }
  console.error("FATAL: Revocations.swift is stale. Run `make revocations` and commit the result.");
  process.exit(1);
}

writeFileSync(TARGET, next);
console.log(`wrote ${ids.length} revoked licence(s) to apps/apple/Bastion/Revocations.swift`);
