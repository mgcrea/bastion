#!/usr/bin/env node
// Check a dotenv file, then hand it to `wrangler secret bulk`.
//
// The push itself is wrangler's: `secret bulk` takes a KEY=VALUE file directly
// and applies the whole set in a single request, which is both fewer round trips
// and less to go wrong halfway than a loop of `secret put`. This script exists
// for the one thing it does not do.
//
// That thing is refusing an incomplete set. `.prod.vars` carries the live webhook
// signing secret, which Stripe shows exactly once at creation — so the realistic
// mistake is running this before it has been pasted in, pushing an empty string,
// and getting a Worker that fails every real payment until someone reads the log.
//
// The production set is two values: LICENSE_SIGNING_KEY and
// STRIPE_WEBHOOK_SECRET. STRIPE_SECRET_KEY is optional and production runs
// without it. All it enables is asking Stripe for the price of a session that
// arrives without `price_id` metadata, so the sale records its price and the
// product guard can check it. If it is set, it has to be the same Stripe mode as
// the webhook secret: a test key against live sessions fails every lookup, and
// the Worker then answers those sales 500 until the key is fixed.
//
// `.dev.vars` needs none of this — wrangler reads it automatically for local dev
// and it never reaches the deployed Worker.
//
// The other thing it does is refuse to push TEST-mode credentials at the
// production Worker. `.test.vars.example` documents a rehearsal against a
// test-mode deployment, but wrangler applies secrets to the default environment
// unless told otherwise — so following those instructions replaced the LIVE
// webhook signing secret with a test-mode one, and every real payment was then
// refused as an invalid signature with nothing anywhere saying why.
//
// The guard is the FILE NAME, not the values. A webhook signing secret is
// `whsec_` plus random characters in both Stripe modes, so nothing in a
// test-mode `.test.vars` looks like test mode: the signing key is the production
// one by design, and the webhook secret carries no marker. Only an API key
// (`sk_test_`, `rk_test_`) does, and `.test.vars` normally has none. So without
// `--env`, anything but `.prod.vars` is refused, and the marker check survives
// only as a second line for test credentials pasted into `.prod.vars` itself.
//
//   node scripts/push-worker-secrets.mjs .prod.vars
//   node scripts/push-worker-secrets.mjs .test.vars --env test

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const envAt = args.indexOf("--env");
const targetEnv = envAt === -1 ? null : args[envAt + 1];
if (envAt !== -1 && !targetEnv) {
  console.error("FATAL: --env needs a name, e.g. --env test");
  process.exit(2);
}
const file = args.find((argument, index) => {
  if (argument === "--env") return false;
  if (envAt !== -1 && index === envAt + 1) return false;
  return !argument.startsWith("--");
});
if (!file) {
  console.error("FATAL: name a dotenv file, e.g. .prod.vars");
  process.exit(2);
}

const API = join(dirname(fileURLToPath(import.meta.url)), "..", "apps/api");
const path = resolve(API, file);

/**
 * The file as `wrangler secret bulk` will read it, which is dotenv's `parse`.
 *
 * Copied from dotenv 16.3.1, the version bundled in wrangler 4, rather than
 * approximated. The earlier reader split on `=` and kept everything after it,
 * so it judged a different file from the one wrangler pushes: `KEY=""` passed
 * the empty check here and went up as an empty secret, a quoted value kept its
 * quotes for the mode check, `KEY=value # note` kept the note, and an
 * `export KEY=` line was not seen at all. Checks are only worth what they check.
 * Wrangler tries JSON first; a JSON file matches no line here and is refused as
 * defining nothing, which is a refusal, not a wrong push.
 */
const LINE =
  /(?:^|^)\s*(?:export\s+)?([\w.-]+)(?:\s*=\s*?|:\s+?)(\s*'(?:\\'|[^'])*'|\s*"(?:\\"|[^"])*"|\s*`(?:\\`|[^`])*`|[^#\r\n]+)?\s*(?:#.*)?(?:$|$)/gm;
const parseDotenv = (source) => {
  const parsed = new Map();
  const lines = source.replace(/\r\n?/gm, "\n");
  for (const match of lines.matchAll(LINE)) {
    let value = (match[2] || "").trim();
    const quote = value[0];
    value = value.replace(/^(['"`])([\s\S]*)\1$/gm, "$2");
    if (quote === '"') value = value.replace(/\\n/g, "\n").replace(/\\r/g, "\r");
    parsed.set(match[1], value);
  }
  return [...parsed];
};

let entries;
try {
  entries = parseDotenv(readFileSync(path, "utf8"));
} catch (error) {
  console.error(`FATAL: cannot read ${path}: ${String(error?.message ?? error)}`);
  process.exit(2);
}

if (entries.length === 0) {
  console.error(`FATAL: ${file} defines no KEY=VALUE pairs`);
  process.exit(2);
}

const blank = entries.filter(([, value]) => value === "").map(([name]) => name);
if (blank.length > 0) {
  console.error(
    `FATAL: ${blank.join(", ")} ${blank.length === 1 ? "is" : "are"} empty in ${file}.`,
  );
  console.error("A half-applied secret set fails in ways that read as a code bug.");
  process.exit(2);
}

// Warn rather than refuse: naming is a convention, not a guarantee, and a
// legitimate mix is imaginable. Getting it wrong is not, so it should be loud.
// Only API keys carry a mode marker; a webhook secret always reads as "live"
// here, whichever mode it belongs to.
const modes = new Set(
  entries
    .filter(([name]) => name.startsWith("STRIPE_"))
    .map(([, value]) => (/_test_|^whsec_test/.test(value) ? "test" : "live")),
);
if (modes.size > 1) {
  console.error(`WARNING: ${file} mixes test and live Stripe credentials.`);
}

// Not a warning. `wrangler secret bulk` with no `--env` writes to the DEFAULT
// environment, which is the Worker taking real money at api.bastion.mgcrea.io.
// Pushing a test-mode webhook secret there refuses every genuine payment, and
// the failure surfaces as a signature error rather than as anything pointing
// back here.
if (modes.has("test") && !targetEnv) {
  console.error(`FATAL: ${file} carries TEST-mode Stripe credentials and no --env was given.`);
  console.error("Without --env these go to the production Worker, which would then refuse");
  console.error("every real payment as an invalid signature. Did you mean:");
  console.error(`  node scripts/push-worker-secrets.mjs ${file} --env test`);
  process.exit(2);
}

// The real guard, for the reason in the header: a test-mode file usually looks
// exactly like a live one, so the name is the only thing that says which it is.
if (!targetEnv && basename(path) !== ".prod.vars") {
  console.error(`FATAL: no --env was given, and ${file} is not .prod.vars.`);
  console.error("Without --env these go to the production Worker. Only .prod.vars may do that;");
  console.error("a test-mode webhook secret looks exactly like a live one, so nothing else can");
  console.error("be told apart. For the test deployment:");
  console.error(`  node scripts/push-worker-secrets.mjs ${file} --env test`);
  process.exit(2);
}

const target = targetEnv ? `the "${targetEnv}" environment` : "the production Worker";
console.log(`pushing ${entries.map(([name]) => name).join(", ")} from ${file} to ${target}`);
try {
  execFileSync(
    "pnpm",
    ["exec", "wrangler", "secret", "bulk", file, ...(targetEnv ? ["--env", targetEnv] : [])],
    { cwd: API, stdio: "inherit" },
  );
} catch (error) {
  // Every other failure in this script is a sentence. A raw Node stack trace
  // over a wrangler error that already printed its own is noise on top of the
  // useful part.
  console.error(`FATAL: wrangler did not apply the secrets (${String(error?.message ?? error)})`);
  process.exit(1);
}
