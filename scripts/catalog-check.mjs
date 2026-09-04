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
//   STRICT  a third-party package is not deprecated on npm, and its `binName`
//           is a key in its own `bin` map. Both are facts only the registry
//           has, and the first is the one that arrives on its own.
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
// ## Two kinds of child, two places the truth lives
//
// A `vendor: "mgcrea"` entry is checked against its TypeScript in `MCP_ROOT`,
// as above. A `vendor: "third-party"` entry has no checkout anywhere and never
// will, so it is checked against the PUBLISHED TARBALL: `npm pack` it, grep the
// built bundle. That is not a lesser check by accident — it is the only place
// the facts exist, and it is checking the exact artefact Bastion installs.
//
// It is weaker in two specific ways, both reported rather than papered over:
// `parseBool(env.X)` and `z.boolean().default(x)` are idioms of the servers
// written here and mean nothing in somebody else's bundle. The generator
// closes the second by refusing `boolean` on a third-party variable, so an
// unverifiable claim cannot be written down in the first place.
//
// ## When there is no checkout
//
// The mgcrea entries skip; the third-party ones still run, because they need no
// checkout. This used to exit 0 for the whole script, which made it a no-op on
// any machine without the sibling repo — and the third-party path needs nothing
// from that repo at all.
//
// A skipped entry is not a passing entry, and `--strict` says so with an exit
// code: use it in any run whose green is meant to mean something.
//
//   node scripts/catalog-check.mjs
//   node scripts/catalog-check.mjs --strict
//   MCP_ROOT=/path/to/mgcrea-ai node scripts/catalog-check.mjs

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const MCP_ROOT = process.env.MCP_ROOT || join(homedir(), "Projects/mgcrea/mgcrea-ai");
const STRICT = process.argv.includes("--strict");
const HAVE_CHECKOUT = existsSync(MCP_ROOT);

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
 * The published package, unpacked.
 *
 * `npm pack` rather than `npm install`: it fetches exactly one tarball and runs
 * no lifecycle script, so nothing in somebody else's package executes here. The
 * cache is keyed by resolved version, so a repeat run costs one `npm view` and
 * a new publish is still noticed — the failure this is meant to catch is an
 * upstream rename, which only ever arrives in a new version.
 *
 * Returns `null` when npm cannot be reached or the package does not exist. That
 * is REPORTED as unverified, never treated as a pass.
 */
const npmRun = (args) =>
  spawnSync("npm", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

const packed = (npmName) => {
  // Unpinned, and the version is read back OFF THE TARBALL rather than asked
  // for first. `npm view <pkg>@latest` and `npm pack <pkg>` do not always agree:
  // a `min-release-age` line in ~/.npmrc quarantines a version for its first
  // day, so `view` names one that `pack` then refuses with ETARGET. Resolving
  // through pack means this measures the version npm would actually hand over —
  // which is also the one Bastion's installer would get.
  const download = join(tmpdir(), "bastion-catalog-check", npmName.replace(/[@/]/g, "_"));
  mkdirSync(download, { recursive: true });
  const pack = npmRun(["pack", npmName, "--silent", "--pack-destination", download]);
  if (pack.status !== 0) return null;
  const tgz = pack.stdout.trim().split("\n").filter(Boolean).pop();
  if (!tgz) return null;

  // `name-1.2.3.tgz`, scope already flattened by npm.
  const version = tgz.replace(/\.tgz$/, "").replace(/^.*?-(?=\d)/, "");
  const cache = join(download, version);
  const root = join(cache, "package");
  if (!existsSync(root)) {
    mkdirSync(cache, { recursive: true });
    const untar = spawnSync("tar", ["-xzf", join(download, tgz), "-C", cache], {
      encoding: "utf8",
    });
    if (untar.status !== 0 || !existsSync(root)) return null;
  }

  // Every text file in the published package, not only the code.
  //
  // The code alone is not enough, and mongodb-mcp-server is why: it hands its
  // schema to a config library with `envPrefix: "MDB_MCP_"` and a camelCase
  // key, so `MDB_MCP_READ_ONLY` is assembled at runtime and appears in no
  // shipped `.js` file at all - only in the README. A variable that exists
  // nowhere in the package is still the failure worth catching, and an upstream
  // rename takes the name out of the schema and the README together.
  // Deprecation, which is registry metadata and not in the tarball.
  //
  // Checked because it is the failure that ARRIVES RATHER THAN BEING MADE: a
  // package is fine on the day it is seeded and dead a year later, with no
  // commit here to notice it. That is not hypothetical — it is the history of
  // `@modelcontextprotocol/server-github`, `-slack`, `-postgres`, `-puppeteer`,
  // `-gitlab` and `-brave-search`, every one of which was widely installed
  // before its repo was archived, and every one of which still takes six-figure
  // monthly downloads from people who have not looked.
  const deprecated = npmRun(["view", `${npmName}@${version}`, "deprecated"]).stdout.trim();

  // The whole bundle, not just `dist`: a package is free to lay itself out
  // however it likes, and the point is to find every read.
  const texts = [];
  const walk = (at) => {
    for (const entry of readdirSync(at)) {
      const path = join(at, entry);
      if (statSync(path).isDirectory()) {
        if (entry !== "node_modules") walk(path);
      } else if (/\.(js|mjs|cjs|ts|mts|cts|json|md|txt|ya?ml)$/.test(entry)) {
        texts.push(readFileSync(path, "utf8"));
      }
    }
  };
  walk(root);

  let bin = {};
  try {
    const meta = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
    bin = typeof meta.bin === "string" ? { [meta.name]: meta.bin } : (meta.bin ?? {});
  } catch {
    bin = {};
  }
  return { texts, bin, version, deprecated };
};

/**
 * Every SCREAMING_SNAKE token that appears anywhere in a bundle.
 *
 * The weaker test, and the one that has to carry a third-party entry. Our own
 * servers all read `env.NAME` literally, which is what makes "declared but
 * never read" safe to fail a build on. Nobody else is obliged to: mongodb-mcp-
 * server hands its whole schema to a config library with `envPrefix:
 * "MDB_MCP_"`, so `MDB_MCP_READ_ONLY` is never read by name anywhere in the
 * shipped code — it is assembled at runtime. A literal-read check would call
 * every one of its variables a typo.
 *
 * Matching the NAME anywhere in the published package still catches the failure
 * this exists to catch. An upstream rename takes the old name out of the schema,
 * the help text and the README together, so a declared variable that appears
 * nowhere in the package is wrong however the package reads it. What it cannot
 * prove is that a name which IS present is wired to anything, and the summary
 * says so rather than letting a green run imply it.
 */
const mentionsOf = (texts) => {
  const found = new Set();
  for (const text of texts) {
    // No underscore required. `@bytebase/dbhub` reads `DSN` and `READONLY`,
    // and a pattern that insisted on one called both of them typos. The cost is
    // that a short generic name matches noise — this is a membership test whose
    // failure direction is a false PASS, and the per-variable report below says
    // which names were confirmed by an actual read and which only by presence.
    for (const m of text.matchAll(/\b[A-Z][A-Z0-9_]{2,}\b/g)) found.add(m[0]);
  }
  return found;
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
const unverified = [];
const byNameEntries = [];
let checked = 0;
let skippedRemote = 0;

for (const server of manifest.servers ?? manifest) {
  if (typeof server !== "object" || !server.id) continue;
  const { transport } = server;
  if (transport?.kind !== "child") {
    // A remote server has no source here to check against. Its claims are
    // checked at runtime instead, by the tool filter in `RemoteInstance`.
    skippedRemote += 1;
    continue;
  }

  // Where this entry's truth lives. `vendor` is the manifest's own statement,
  // and the generator has already refused an entry whose package disagrees
  // with it, so it can be trusted here.
  const ours = transport.vendor !== "third-party";
  let texts;
  let config = "";
  let against;
  // Which test the entry's variables are held to: a literal read of the name in
  // our own source, or the name's presence anywhere in somebody else's bundle.
  let byName = false;

  if (ours) {
    const src = join(MCP_ROOT, transport.localPath ?? "", "src");
    if (!HAVE_CHECKOUT || !existsSync(src)) {
      unverified.push(`${server.id}: no checkout at ${join(MCP_ROOT, transport.localPath ?? "")}`);
      continue;
    }
    texts = sources(src);
    config = existsSync(join(src, "config.ts")) ? readFileSync(join(src, "config.ts"), "utf8") : "";
    against = transport.localPath;
  } else {
    const pkg = packed(transport.npmName);
    if (!pkg) {
      unverified.push(`${server.id}: could not fetch ${transport.npmName} from npm`);
      continue;
    }
    texts = pkg.texts;
    against = `${transport.npmName}@${pkg.version}`;
    byName = true;

    // ── STRICT: the package is not deprecated ───────────────────────────────
    //
    // A hard failure rather than advice, and safe to make one: `catalog-check`
    // is not a CI job, so this cannot turn a build permanently red on somebody
    // else's decision. It fails the person who runs it, which is who can act.
    if (pkg.deprecated) {
      problems.push(
        `${server.id}: ${transport.npmName}@${pkg.version} is DEPRECATED on npm — ` +
          `"${pkg.deprecated.slice(0, 120)}"`,
      );
    }

    // ── STRICT: the bin name is a key in the package's own `bin` map ─────────
    //
    // Nothing else checks this, and the failure is asymmetric:
    // `ServerInstaller.entryScript` falls back to the sole bin, so a wrong name
    // is SILENT on a single-bin package and fatal on a multi-bin one. Free here
    // because the tarball is already open.
    const bins = Object.keys(pkg.bin);
    if (!bins.includes(transport.binName)) {
      problems.push(
        `${server.id}: binName ${transport.binName} is not in ${transport.npmName}'s bin map ` +
          `(${bins.join(", ") || "none"})`,
      );
    }
  }
  checked += 1;

  const reads = readsOf(texts);
  const known = byName ? mentionsOf(texts) : reads;
  const declared = server.env ?? [];
  // Which of this entry's variables the weaker test had to carry. Usually none:
  // most third-party servers do read their environment by name, and saying so
  // per entry keeps "checked by name" from reading as a blanket disclaimer over
  // servers that were in fact checked properly.
  if (byName) {
    const unread = declared.map((e) => e.name).filter((n) => !reads.has(n));
    if (unread.length) byNameEntries.push(`${server.id} (${unread.join(", ")})`);
  }

  // ── STRICT: a declared variable the server has no trace of ────────────────
  for (const variable of declared) {
    if (known.has(variable.name)) continue;
    problems.push(
      `${server.id}: ${variable.name} is offered in the profile editor, but ${against} ` +
        (byName ? "does not mention it" : "never reads it") +
        " — renamed upstream, or a typo",
    );
  }

  // ── STRICT: the write gate is read, and read as a boolean ─────────────────
  //
  // The second half is an idiom of the servers written here — `parseBool` is
  // ours — so for somebody else's bundle only the first half is checkable.
  // Which way the gate POINTS is not checkable from either: it is stated in
  // the manifest as `writeGateSense`, required there for exactly this reason.
  if (server.writeGate) {
    if (!known.has(server.writeGate)) {
      problems.push(
        `${server.id}: writeGate ${server.writeGate} is not ${byName ? "mentioned by" : "read by"} ` +
          `${against}, so the profile toggle sets a variable nothing consults`,
      );
    } else if (ours && !new RegExp(`parseBool\\(env\\.${server.writeGate}\\)`).test(config)) {
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
    if (!variable.boolean || !ours) continue;
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
  //
  // Skipped for a by-name entry: the token set there is every constant in a
  // built bundle, not the variables it reads, so the list would be thousands
  // long and would say nothing about the curation.
  if (!byName) {
    const names = new Set(declared.map((e) => e.name));
    const omitted = [...reads].filter((n) => !names.has(n) && !AMBIENT.has(n)).toSorted();
    if (omitted.length) advice.push(`  ${server.id}: ${omitted.join(", ")}`);
  }
}

console.log(
  `\nChecked ${checked} server${checked === 1 ? "" : "s"}` +
    (skippedRemote ? `, skipped ${skippedRemote} remote` : "") +
    (unverified.length ? `, ${unverified.length} UNVERIFIED` : ""),
);

// Named, and named apart from the remote skips. A remote entry has nothing here
// to check and never will; an unverified CHILD is a claim nobody looked at, and
// reading it as "skipped" is how a green run comes to mean less than it looks.
// Said out loud, because the two tests are not the same promise and a summary
// that prints one number for both is how the weaker one stops being noticed.
if (byNameEntries.length) {
  console.log(
    "\nConfirmed by presence, not by a read — these packages assemble the name at runtime, so\n" +
      "the check is that it appears somewhere in the published package. That catches a rename\n" +
      "and cannot prove the variable is wired:\n" +
      byNameEntries.map((e) => `  – ${e}`).join("\n"),
  );
}

if (unverified.length) {
  console.log("\nNot checked — these entries were verified against nothing:");
  for (const line of unverified) console.log(`  – ${line}`);
  if (!HAVE_CHECKOUT) console.log(`\n  Set MCP_ROOT to point at the mgcrea-ai working copy.`);
}

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

if (STRICT && unverified.length) {
  console.error(
    `\n${unverified.length} child entr${unverified.length === 1 ? "y" : "ies"} could not be ` +
      "checked, and --strict was asked for.",
  );
  process.exit(1);
}

console.log(
  unverified.length
    ? "\nEvery claim that could be checked holds."
    : "\nEvery claim in servers.json holds.",
);
