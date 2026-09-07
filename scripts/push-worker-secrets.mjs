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
// and getting a Worker that rejects every real payment with a 400 that reads like
// a signature bug. The three values also have to be the same Stripe mode: a live
// webhook secret with a test API key fulfils and silently records no price.
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
//   node scripts/push-worker-secrets.mjs .prod.vars
//   node scripts/push-worker-secrets.mjs .test.vars --env test

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
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

let entries;
try {
  entries = readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => /^[A-Z][A-Z0-9_]*=/.test(line))
    .map((line) => {
      const at = line.indexOf("=");
      return [line.slice(0, at), line.slice(at + 1).trim()];
    });
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
const modes = new Set(
  entries
    .filter(([name]) => name.startsWith("STRIPE_"))
    .map(([, value]) => (/_test_|^whsec_test/.test(value) ? "test" : "live")),
);
if (modes.size > 1) {
  console.error(`WARNING: ${file} mixes test and live Stripe credentials.`);
}

// The one that is not a warning. `wrangler secret bulk` with no `--env` writes
// to the DEFAULT environment, which is the Worker taking real money at
// api.bastion.mgcrea.io. Pushing a test-mode webhook secret there refuses every
// genuine payment, and the failure surfaces as a signature error rather than as
// anything pointing back here.
if (modes.has("test") && !targetEnv) {
  console.error(`FATAL: ${file} carries TEST-mode Stripe credentials and no --env was given.`);
  console.error("Without --env these go to the production Worker, which would then refuse");
  console.error("every real payment as an invalid signature. Did you mean:");
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
