#!/usr/bin/env node
// Assert that what `servers.json` claims about a server is true of the server.
//
// The catalog is a CURATED SUBSET, and deliberately so: Bastion declares 10 of
// mcp-x's 26 variables and 7 of mcp-appstore-connect's 16, because a
// profile editor listing every `*_MAX_RETRIES` and `*_DEBUG` would be worse,
// not better. That curation is Bastion's decision and belongs in this repo.
//
// But every FACT inside the curation is the server's, and nothing checked them.
// `UNIFI_PROTECT_VERIFY_TLS` defaults to true and the other four booleans
// default to false; that was established by opening `src/config.ts` and reading
// it. Getting one wrong is not a cosmetic error — the profile editor renders
// the default as a choice, so a wrong `true` presents "Default (on)" for a
// setting the server has off, and a wrong `false` on VERIFY_TLS offers a
// certificate check as already-on when it is not.
//
// So: three assertions that must hold, and one report that is only ever
// advice.
//
//   STRICT  every declared variable is one the server actually reads.
//           Catches an upstream rename, whose symptom is a field in the editor
//           that collects a value nothing will ever look at.
//
//   STRICT  every `boolean.default` matches the server's own zod default.
//
//   STRICT  the `writeGate` is read, and read AS A BOOLEAN. The generator only
//           checks the gate is one of the declared variables — a gate that is
//           spelled right and read by nobody still reads as off in every UI
//           while the server does whatever it likes.
//
//   ADVICE  variables the server reads that the catalog omits. Never a
//           failure: that list IS the curation, and it is supposed to be long.
//
// ## Why regexes and not an import
//
// These are eleven independent packages with no shared runtime, and the facts
// wanted here are in the SHAPE of the config module, not in its exports:
// `loadConfig` returns resolved values, so importing it would answer "what is
// this config" and never "what does an unset variable fall through to". The
// patterns matched are the two lines every one of these servers writes the same
// way, and an unrecognised shape is reported as undeterminable rather than
// silently passing — see `UNDETERMINABLE` below.
//
// ## When there is no checkout
//
// Skips, exit 0, like `make dialect` without an installed server. This checks
// Bastion against source that lives in another repo on the developer's machine;
// it cannot run in a CI job that has only this one, and pretending otherwise
// would make a green build mean less than it does now.
//
//   node scripts/catalog-check.mjs
//   MCP_ROOT=/path/to/mgcrea-ai node scripts/catalog-check.mjs

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const MCP_ROOT = process.env.MCP_ROOT || join(homedir(), "Projects/mgcrea/mgcrea-ai");

if (!existsSync(MCP_ROOT)) {
  console.log(`skipped: no server checkout at ${MCP_ROOT}`);
  console.log("Set MCP_ROOT to point at the mgcrea-ai working copy.");
  process.exit(0);
}

const manifest = JSON.parse(readFileSync(join(ROOT, "servers.json"), "utf8"));

/** Every .ts file under a directory, so a read in `client/` counts as a read. */
const sources = (dir) => {
  const out = [];
  const walk = (at) => {
    for (const entry of readdirSync(at)) {
      const path = join(at, entry);
      if (statSync(path).isDirectory()) {
        // `dist` is the build of the same source and would double-count; the
        // test tree names variables it is deliberately setting, not reading.
        if (entry !== "dist" && entry !== "node_modules") walk(path);
      } else if (entry.endsWith(".ts") && !entry.endsWith(".test.ts")) {
        out.push(readFileSync(path, "utf8"));
      }
    }
  };
  walk(dir);
  return out;
};

/**
 * Every environment variable a server reads.
 *
 * Both forms are matched, but only one is used in practice: every read across
 * the eleven repos is a literal `env.NAME` or `process.env.NAME`, with no
 * computed access anywhere. That is what makes the "declared but never read"
 * assertion safe to fail a build on — a dynamic read would make it a guess.
 */
const readsOf = (texts) => {
  const found = new Set();
  for (const text of texts) {
    for (const m of text.matchAll(/\benv\.([A-Z][A-Z0-9_]*)/g)) found.add(m[1]);
    for (const m of text.matchAll(/\bprocess\.env\[\s*["']([A-Z][A-Z0-9_]*)/g)) found.add(m[1]);
  }
  return found;
};

// Set by Bastion itself rather than by a profile, so a server reading one is
// not evidence of anything missing from the catalog. XDG_* is how three of
// these servers are redirected into their per-profile directory; the display
// variables are the OS telling a browser-opening flow where to go.
const AMBIENT = new Set([
  "XDG_CONFIG_HOME",
  "XDG_CACHE_HOME",
  "HOME",
  "PATH",
  "DISPLAY",
  "WAYLAND_DISPLAY",
]);

const UNDETERMINABLE = "could not be determined from the server's source";

const problems = [];
const advice = [];
let checked = 0;
let skipped = 0;

for (const server of manifest.servers ?? manifest) {
  if (typeof server !== "object" || !server.id) continue;
  const { transport } = server;
  if (transport?.kind !== "child") {
    // A remote server has no source here to check against. Its claims are
    // checked at runtime instead, by the tool filter in `RemoteInstance`.
    skipped += 1;
    continue;
  }
  const repo = join(MCP_ROOT, transport.localPath ?? "");
  const src = join(repo, "src");
  if (!existsSync(src)) {
    console.log(`  – ${server.id}: no checkout at ${transport.localPath}`);
    skipped += 1;
    continue;
  }
  checked += 1;

  const texts = sources(src);
  const reads = readsOf(texts);
  const config = existsSync(join(src, "config.ts"))
    ? readFileSync(join(src, "config.ts"), "utf8")
    : "";
  const declared = server.env ?? [];

  // ── STRICT: a declared variable nothing reads ─────────────────────────────
  for (const variable of declared) {
    if (!reads.has(variable.name)) {
      problems.push(
        `${server.id}: ${variable.name} is offered in the profile editor, but the server ` +
          "never reads it — renamed upstream, or a typo",
      );
    }
  }

  // ── STRICT: the write gate is read, and read as a boolean ─────────────────
  if (server.writeGate) {
    if (!reads.has(server.writeGate)) {
      problems.push(
        `${server.id}: writeGate ${server.writeGate} is not read by the server, so the ` +
          "profile toggle sets a variable nothing consults",
      );
    } else if (!new RegExp(`parseBool\\(env\\.${server.writeGate}\\)`).test(config)) {
      problems.push(
        `${server.id}: writeGate ${server.writeGate} is read, but not as a boolean — ` +
          'Bastion writes "1" and "0", so a different parser may read "0" as on',
      );
    }
  }

  // ── STRICT: a stated boolean default matches the server's own ─────────────
  //
  // `field: parseBool(env.THE_VAR) ?? file.field` gives the variable-to-field
  // mapping, and `field: z.boolean().default(x)` gives what unset resolves to.
  const fieldOf = new Map();
  for (const m of config.matchAll(/(\w+):\s*parseBool\(env\.([A-Z][A-Z0-9_]*)\)/g)) {
    fieldOf.set(m[2], m[1]);
  }
  for (const variable of declared) {
    if (!variable.boolean) continue;
    const field = fieldOf.get(variable.name);
    if (!field) {
      problems.push(
        `${server.id}: ${variable.name} is typed a boolean, but its config field ${UNDETERMINABLE}`,
      );
      continue;
    }
    const m = config.match(
      new RegExp(`\\b${field}:\\s*z\\.boolean\\(\\)\\.default\\((true|false)\\)`),
    );
    if (!m) {
      problems.push(
        `${server.id}: ${variable.name} is typed a boolean, but the default for '${field}' ` +
          UNDETERMINABLE,
      );
      continue;
    }
    const actual = m[1] === "true";
    if (actual !== variable.boolean.default) {
      problems.push(
        `${server.id}: ${variable.name} says unset means ${variable.boolean.default}, but the ` +
          `server's schema defaults '${field}' to ${actual} — the editor is offering the ` +
          "wrong state as the safe one",
      );
    }
  }

  // ── ADVICE: read, but not offered ─────────────────────────────────────────
  const names = new Set(declared.map((e) => e.name));
  const omitted = [...reads].filter((n) => !names.has(n) && !AMBIENT.has(n)).toSorted();
  if (omitted.length) advice.push(`  ${server.id}: ${omitted.join(", ")}`);
}

console.log(
  `\nChecked ${checked} server${checked === 1 ? "" : "s"} against ${MCP_ROOT}` +
    (skipped ? `, skipped ${skipped}` : ""),
);

if (advice.length) {
  console.log(
    "\nRead by the server, not offered in the profile editor. This is the curation, " +
      "not a fault —\nreview it when adding a variable, ignore it otherwise.",
  );
  for (const line of advice) console.log(line);
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s):`);
  for (const p of problems) console.error(`  - ${p}`);
  console.error("\nservers.json disagrees with the servers it describes.");
  process.exit(1);
}

console.log("\nEvery claim in servers.json holds.");
