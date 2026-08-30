#!/usr/bin/env node
// Generate every copy of the server list from `servers.json`.
//
// The `generate-surfaces.mjs` pattern from cupertino, applied on day one rather
// than after the list had been hand-copied into ten files. There is nothing to
// un-learn here yet — that is the point of writing it before the Gateway.
//
// ## How it writes
//
// Not whole files. Each target carries a MARKED REGION and only the region is
// replaced, because the prose around the list is worth more than the list is:
// ServerCatalog.swift opens with what the catalog is and is not, and generating
// that away to save a few lines of repetition would be a bad trade.
//
// ## --check
//
// The point of the whole exercise. `--check` regenerates into memory and exits
// non-zero if any target differs, so CI fails on drift rather than trusting
// anyone to remember. A generator without it is a convenience; with it, the
// manifest is actually the source of truth.
//
//   node scripts/generate-servers.mjs            # write
//   node scripts/generate-servers.mjs --check    # verify, write nothing

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CHECK = process.argv.includes("--check");

const read = (rel) => readFileSync(join(ROOT, rel), "utf8");

// ─── the manifest ────────────────────────────────────────────────────────────

const manifest = JSON.parse(read("servers.json"));

/**
 * Validate before writing anything.
 *
 * A generator that happily writes a malformed id into every target at once is
 * worse than the same number of hand-edits, because the blast radius is the
 * whole repo. Two classes of rule live here:
 *
 *   SHAPE     — mirrors scripts/servers.schema.json, so the manifest is checked
 *               even when nothing has opened it in an editor. Deliberately
 *               duplicated rather than pulling in a JSON Schema validator: this
 *               script has no runtime dependencies and that is worth keeping.
 *
 *   COHERENCE — what a schema cannot say. A write gate that names an env var
 *               the server does not read is a gate that gates nothing, and it
 *               would look completely fine in every editor.
 */
/** Every revision the manifest may name, oldest first. */
const DIALECTS = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"];

const validate = (servers) => {
  const problems = [];
  const seen = new Set();
  const ENV_NAME = /^[A-Z][A-Z0-9_]*$/;

  for (const [i, s] of servers.entries()) {
    const at = `servers[${i}]${s.id ? ` (${s.id})` : ""}`;
    const p = (msg) => problems.push(`${at}: ${msg}`);

    // ── shape
    if (!/^[a-z][a-z0-9-]*$/.test(s.id ?? "")) p("id must be kebab-case");
    if (seen.has(s.id)) p("duplicate id");
    seen.add(s.id);

    for (const key of ["displayName", "summary", "npmName", "binName", "localPath", "dialect"]) {
      if (typeof s[key] !== "string" || !s[key]) p(`${key} is required`);
    }
    if (!["npm", "local"].includes(s.distribution)) p('distribution must be "npm" or "local"');
    if (!DIALECTS.includes(s.dialect)) p(`dialect must be one of ${DIALECTS.join(", ")}`);
    if (s.docsUrl !== null && !(s.docsUrl ?? "").startsWith("https://")) {
      p("docsUrl must be an https URL or null");
    }
    if (s.writeGate !== null && !ENV_NAME.test(s.writeGate ?? "")) {
      p("writeGate must be an env var name or null");
    }
    for (const key of ["gateBypass", "authModes", "stateEnv", "callbackEnv", "env", "notes"]) {
      if (!Array.isArray(s[key])) p(`${key} must be an array`);
    }
    if (Array.isArray(s.env) && s.env.length === 0) p("env must not be empty");

    // ── the naming rule
    //
    // All three of these are mechanically derived from the id. They are written
    // out in the manifest anyway so a reader never has to reconstruct them, and
    // checked here so the two can never disagree — which is the failure that
    // makes a "helpfully" redundant field worse than no field.
    //
    // Catalog entries only. A CUSTOM server added in the app is not held to
    // this: it names somebody else's package, and `@acme/mcp-foo` shipping a
    // `foo` binary is nobody's mistake. `ServerStore` validates those instead,
    // which is why that check lives in Swift and this one does not move.
    if (s.npmName !== `@mgcrea/mcp-${s.id}`) p(`npmName must be @mgcrea/mcp-${s.id}`);
    if (s.binName !== `${s.id}-mcp`) p(`binName must be ${s.id}-mcp`);
    if (s.localPath !== `mcp-${s.id}`) p(`localPath must be mcp-${s.id}`);

    // ── coherence
    const envNames = new Set((s.env ?? []).map((e) => e.name));
    const byName = new Map((s.env ?? []).map((e) => [e.name, e]));

    for (const [j, e] of (s.env ?? []).entries()) {
      const eat = `${at}.env[${j}]${e.name ? ` (${e.name})` : ""}`;
      if (!ENV_NAME.test(e.name ?? "")) problems.push(`${eat}: name must be SCREAMING_SNAKE_CASE`);
      if (typeof e.required !== "boolean") problems.push(`${eat}: required must be a boolean`);
      if (typeof e.secret !== "boolean") problems.push(`${eat}: secret must be a boolean`);
      if (typeof e.description !== "string" || !e.description) {
        problems.push(`${eat}: description is required`);
      }
    }
    if (envNames.size !== (s.env ?? []).length) p("duplicate env name");

    // A gate the server never reads gates nothing. Every one of these is a
    // switch on a destructive tool, so a typo here is a switch that is wired to
    // no wire and reads, in every UI, as if it were off.
    if (s.writeGate !== null && !envNames.has(s.writeGate)) {
      p(`writeGate ${s.writeGate} is not in env`);
    }

    for (const key of ["stateEnv", "callbackEnv"]) {
      for (const name of s[key] ?? []) {
        if (!envNames.has(name)) p(`${key} names ${name}, which is not in env`);
      }
    }

    // The opposite rule to the one above, and for the opposite reason. A bypass
    // that appeared in `env` would be settable by a profile — which is exactly
    // the hole it exists to close, since setting it would enable writes while
    // the profile's own gate read as off.
    for (const name of s.gateBypass ?? []) {
      if (!ENV_NAME.test(name)) p(`gateBypass ${name} is not an env var name`);
      if (envNames.has(name)) {
        p(`gateBypass ${name} must not also be in env — a bypass is neutralised, never set`);
      }
    }
    if (s.writeGate === null && (s.gateBypass ?? []).length) {
      p("gateBypass has no meaning without a writeGate");
    }

    const modeIds = new Set();
    for (const [j, m] of (s.authModes ?? []).entries()) {
      const mat = `${at}.authModes[${j}]${m.id ? ` (${m.id})` : ""}`;
      if (!/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(m.id ?? "")) problems.push(`${mat}: bad id`);
      if (modeIds.has(m.id)) problems.push(`${mat}: duplicate id`);
      modeIds.add(m.id);
      if (typeof m.displayName !== "string" || !m.displayName) {
        problems.push(`${mat}: displayName is required`);
      }
      if (!Array.isArray(m.env) || m.env.length === 0) {
        problems.push(`${mat}: env must be a non-empty array`);
        continue;
      }
      for (const name of m.env) {
        if (!envNames.has(name)) {
          problems.push(`${mat}: names ${name}, which is not in env`);
          continue;
        }
        // An auth mode exists precisely because the credential is optional
        // until you have chosen a mode. Marking one of its vars required would
        // make every other mode unfillable, and the profile editor would show
        // a form that cannot be satisfied.
        if (byName.get(name).required) {
          problems.push(`${mat}: ${name} is in an auth mode, so it cannot be required:true`);
        }
      }
    }
  }

  if (problems.length) {
    console.error("servers.json is invalid:\n" + problems.map((p) => `  - ${p}`).join("\n"));
    process.exit(2);
  }
};

const servers = manifest.servers;
validate(servers);

// ─── marked regions ──────────────────────────────────────────────────────────

const BANNER = "generated from servers.json by `make servers` — do not edit by hand";

/**
 * Replace the content between the markers, preserving everything outside them.
 *
 * The markers stay in the file so the boundary is visible to a reader who has
 * never heard of this script, and so a merge conflict lands inside a region
 * rather than silently reordering it.
 */
const region = (source, open, close, body, label) => {
  const start = source.indexOf(open);
  const end = source.indexOf(close);
  if (start === -1 || end === -1 || end < start) {
    console.error(`${label}: could not find the generated region (${open.trim()})`);
    process.exit(3);
  }
  return source.slice(0, start + open.length) + body + source.slice(end);
};

const targets = [];
const target = (path, next) => targets.push({ path, next });

// ─── 1. ServerCatalog.swift ──────────────────────────────────────────────────

const swiftString = (v) => JSON.stringify(v);
const swiftOptionalURL = (v) => (v === null ? "nil" : `URL(string: ${swiftString(v)})`);
const swiftOptionalString = (v) => (v === null ? "nil" : swiftString(v));
const swiftStringList = (xs) => (xs.length === 0 ? "[]" : `[${xs.map(swiftString).join(", ")}]`);

const swiftAuthMode = (m) =>
  [
    `        .init(`,
    `          id: ${swiftString(m.id)},`,
    `          displayName: ${swiftString(m.displayName)},`,
    `          env: ${swiftStringList(m.env)}),`,
  ].join("\n");

const swiftEnvVar = (e) =>
  [
    `        .init(`,
    `          name: ${swiftString(e.name)},`,
    `          isRequired: ${e.required},`,
    `          isSecret: ${e.secret},`,
    `          summary: ${swiftString(e.description)}),`,
  ].join("\n");

/** `2025-11-25` → `.v2025_11_25`. Derived, so a new revision needs no edit here. */
const swiftDialect = (dialect) => `.v${dialect.replaceAll("-", "_")}`;

const swiftServer = (s) => {
  const lines = [];
  for (const note of s.notes) lines.push(note ? `    // ${note}` : "    //");
  return [
    ...lines,
    `    BastionServer(`,
    `      id: ${swiftString(s.id)},`,
    `      displayName: ${swiftString(s.displayName)},`,
    `      summary: ${swiftString(s.summary)},`,
    `      npmName: ${swiftString(s.npmName)},`,
    `      binName: ${swiftString(s.binName)},`,
    `      distribution: .${s.distribution},`,
    `      localPath: ${swiftString(s.localPath)},`,
    `      docsURL: ${swiftOptionalURL(s.docsUrl)},`,
    `      dialect: ${swiftDialect(s.dialect)},`,
    `      writeGate: ${swiftOptionalString(s.writeGate)},`,
    `      gateBypass: ${swiftStringList(s.gateBypass)},`,
    s.authModes.length === 0
      ? `      authModes: [],`
      : `      authModes: [\n${s.authModes.map(swiftAuthMode).join("\n")}\n      ],`,
    `      stateEnv: ${swiftStringList(s.stateEnv)},`,
    `      callbackEnv: ${swiftStringList(s.callbackEnv)},`,
    `      env: [\n${s.env.map(swiftEnvVar).join("\n")}\n      ]),`,
  ].join("\n");
};

target("apps/apple/Bastion/ServerCatalog.swift", (src) =>
  region(
    src,
    `  // <generated:servers> ${BANNER}\n`,
    `  // </generated:servers>`,
    `  static let all: [BastionServer] = [\n${servers.map(swiftServer).join("\n")}\n  ]\n`,
    "ServerCatalog.swift",
  ),
);

// ─── 2. docs/servers.md ──────────────────────────────────────────────────────
//
// The reference table. It is generated because a docs table is exactly the copy
// of a list that rots first: nothing breaks when it is wrong, so nothing tells
// anyone that it is.

const mdEscape = (v) => String(v).replaceAll("|", "\\|");
const mdCode = (v) => `\`${mdEscape(v)}\``;

const mdRow = (s) =>
  [
    s.docsUrl === null ? mdEscape(s.displayName) : `[${mdEscape(s.displayName)}](${s.docsUrl})`,
    mdCode(s.id),
    mdCode(s.binName),
    s.distribution === "npm" ? `${mdCode(s.npmName)} (npm)` : `${mdCode(s.localPath)} (local)`,
    s.writeGate === null ? "read-only" : mdCode(s.writeGate),
    s.env.filter((e) => e.secret).length || "—",
  ].join(" | ");

const mdDetail = (s) => {
  const out = [`### ${s.displayName}`, "", s.summary, ""];
  if (s.notes.length) out.push(s.notes.join("\n"), "");
  out.push("| Variable | Required | Secret | Meaning |", "| --- | --- | --- | --- |");
  for (const e of s.env) {
    out.push(
      `| ${mdCode(e.name)} | ${e.required ? "yes" : "—"} | ${e.secret ? "yes" : "—"} | ${mdEscape(e.description)} |`,
    );
  }
  out.push("");
  if (s.authModes.length) {
    out.push(
      "Fill exactly one of: " +
        s.authModes
          .map((m) => `**${m.displayName}** (${m.env.map(mdCode).join(" + ")})`)
          .join(", "),
      "",
    );
  }
  if (s.stateEnv.length) {
    out.push(`Per-profile state: ${s.stateEnv.map(mdCode).join(", ")}`, "");
  }
  if (s.callbackEnv.length) {
    out.push(`Per-profile OAuth callback: ${s.callbackEnv.map(mdCode).join(", ")}`, "");
  }
  if (s.gateBypass.length) {
    out.push(
      `Forced off by Bastion so the write gate is the only switch: ${s.gateBypass.map(mdCode).join(", ")}`,
      "",
    );
  }
  return out.join("\n");
};

target("docs/servers.md", (src) =>
  region(
    src,
    `<!-- <generated:servers> ${BANNER} -->\n`,
    `<!-- </generated:servers> -->`,
    [
      "",
      "| Server | Id | Binary | Source | Write gate | Secrets |",
      "| --- | --- | --- | --- | --- | --- |",
      ...servers.map(mdRow).map((r) => `| ${r} |`),
      "",
      ...servers.map(mdDetail),
    ].join("\n"),
    "docs/servers.md",
  ),
);

// ─── 3. apps/website/src/data/servers.ts ─────────────────────────────────────
//
// The marketing site names the catalog and prints every id with its gate. That
// is a claim about this manifest, so the site reads a generated copy rather
// than a typed one — a page that counts differently from the app it describes
// is the drift this generator exists to make impossible, and it is the copy
// nobody would notice was wrong.
//
// Only the fields the page renders are emitted. The env matrix and the auth
// modes are the app's business and would put every secret's NAME on a public
// page for no reader's benefit.

const tsString = (v) => JSON.stringify(v);
const tsOptionalString = (v) => (v === null ? "null" : tsString(v));

const tsServer = (s) =>
  [
    "  {",
    `    id: ${tsString(s.id)},`,
    `    displayName: ${tsString(s.displayName)},`,
    `    summary: ${tsString(s.summary)},`,
    `    writeGate: ${tsOptionalString(s.writeGate)},`,
    `    dialect: ${tsString(s.dialect)},`,
    "  },",
  ].join("\n");

target("apps/website/src/data/servers.ts", (src) =>
  region(
    src,
    `// <generated:servers> ${BANNER}\n`,
    `// </generated:servers>`,
    `export const SERVERS: Server[] = [\n${servers.map(tsServer).join("\n")}\n];\n`,
    "apps/website/src/data/servers.ts",
  ),
);

// ─── write or check ──────────────────────────────────────────────────────────

let drifted = 0;
for (const { path, next } of targets) {
  const before = read(path);
  const after = next(before);
  if (before === after) continue;
  if (CHECK) {
    console.error(`drift: ${path}`);
    drifted += 1;
  } else {
    writeFileSync(join(ROOT, path), after);
    console.log(`updated ${path}`);
  }
}

if (CHECK) {
  if (drifted) {
    console.error(`\n${drifted} file(s) out of date — run \`make servers\` and commit the result.`);
    process.exit(1);
  }
  console.log(`servers.json: ${servers.length} servers, ${targets.length} targets up to date`);
} else if (!targets.length) {
  console.log("nothing to generate");
}
