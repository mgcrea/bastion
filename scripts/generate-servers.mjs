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

    for (const key of ["displayName", "summary", "dialect"]) {
      if (typeof s[key] !== "string" || !s[key]) p(`${key} is required`);
    }

    // ── the transport, and the fields it makes meaningful
    //
    // Checked before anything reads them, because every rule below this point
    // asks a different question of a child than of a remote endpoint: a child
    // has a package to install and an environment to set, and a remote server
    // has neither.
    const t = s.transport ?? {};
    const isChild = t.kind === "child";
    const isRemote = t.kind === "remote";
    if (!isChild && !isRemote) p('transport.kind must be "child" or "remote"');

    if (isChild) {
      for (const key of ["npmName", "binName", "localPath"]) {
        if (typeof t[key] !== "string" || !t[key]) p(`transport.${key} is required`);
      }
      if (!["npm", "local"].includes(t.distribution)) {
        p('transport.distribution must be "npm" or "local"');
      }
    }

    if (isRemote) {
      // https only, and said here as well as in Swift. The Swift check is the
      // one that protects a running gateway; this one stops a bad URL reaching
      // a generated file and nine other copies of it in the first place.
      if (typeof t.url !== "string" || !t.url.startsWith("https://")) {
        p("transport.url must be an https URL");
      }
      // A remote server has no environment, so the env-var-shaped fields are
      // not merely unused - carrying one would be a promise Bastion cannot
      // keep, and it would read in every UI as if it were in force.
      if (s.writeGate !== null) p("a remote server has no environment: writeGate must be null");
      if ((s.stateEnv ?? []).length)
        p("a remote server has no on-disk state: stateEnv must be empty");
      if ((s.callbackEnv ?? []).length)
        p("a remote server has no child to redirect: callbackEnv must be empty");
    } else if (s.writeTools !== undefined) {
      p("writeTools is remote-only — a child server gates writes with writeGate");
    }
    if (s.writeTools !== undefined && !Array.isArray(s.writeTools))
      p("writeTools must be an array");
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
    // Nothing to derive for a remote entry: the endpoint belongs to whoever
    // operates it, and `mcp.stripe.com` is not Bastion's to name.
    if (isChild) {
      if (t.npmName !== `@mgcrea/mcp-${s.id}`) p(`transport.npmName must be @mgcrea/mcp-${s.id}`);
      if (t.binName !== `${s.id}-mcp`) p(`transport.binName must be ${s.id}-mcp`);
      if (t.localPath !== `mcp-${s.id}`) p(`transport.localPath must be mcp-${s.id}`);
    }

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

      // A variable's SINK. On a child it is an environment variable and there
      // is nothing to say; on a remote server there is no environment, so a
      // variable with no header is a variable that goes nowhere - collected
      // from the user, stored in the Keychain, and silently never sent.
      if (isRemote && !e.header) {
        problems.push(`${eat}: a remote server's variable needs a header, or it goes nowhere`);
      }
      if (!isRemote && e.header) {
        problems.push(
          `${eat}: header is remote-only — a child's variables are environment variables`,
        );
      }
      if (e.header) {
        if (!/^[A-Za-z][A-Za-z0-9-]*$/.test(e.header.name ?? "")) {
          problems.push(`${eat}: header.name must be a header name`);
        }
        // The template is what keeps the word "Bearer" out of the profile, so
        // a value that never interpolates is a header sent with a literal
        // template in it - which fails upstream as an auth error, the least
        // debuggable possible symptom.
        if (typeof e.header.format !== "string" || !e.header.format.includes("{value}")) {
          problems.push(`${eat}: header.format must be a template containing {value}`);
        }
      }
    }
    if (envNames.size !== (s.env ?? []).length) p("duplicate env name");

    // A gate the server never reads gates nothing. Every one of these is a
    // switch on a destructive tool, so a typo here is a switch that is wired to
    // no wire and reads, in every UI, as if it were off.
    if (s.writeGate !== null && !envNames.has(s.writeGate)) {
      p(`writeGate ${s.writeGate} is not in env`);
    }

    for (const name of s.stateEnv ?? []) {
      if (!envNames.has(name)) p(`stateEnv names ${name}, which is not in env`);
    }
    // A callback entry carries a template as well as a name, because the URL is
    // built rather than typed. `{port}` is the whole point of the field: a
    // format without it is a constant, which is the collision the field exists
    // to remove.
    for (const c of s.callbackEnv ?? []) {
      const name = c?.name;
      if (!envNames.has(name)) p(`callbackEnv names ${name}, which is not in env`);
      if (typeof c?.format !== "string" || !c.format.includes("{port}")) {
        p(`callbackEnv ${name}: format must be a template containing {port}`);
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

    // A remote gate names TOOLS rather than a variable, so the coherence check
    // that catches a typo is a different one: there is no env list to check a
    // name against, and the list is a denylist, so a typo here reads as a tool
    // that is simply not gated. Only shape and duplicates are checkable
    // offline; `make dialect` is where a name meets a real tools/list.
    const toolNames = new Set();
    for (const name of s.writeTools ?? []) {
      if (typeof name !== "string" || !/^[a-zA-Z][a-zA-Z0-9_.-]*$/.test(name)) {
        p(`writeTools names ${JSON.stringify(name)}, which is not a tool name`);
      }
      if (toolNames.has(name)) p(`writeTools names ${name} twice`);
      toolNames.add(name);
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
      // Neither OAuth kind names variables, because there are none to name.
      // What differs is custody, and each kind is refused on the transport that
      // cannot honour it: `oauth` needs an endpoint to discover against, which a
      // child has not got, and `childOAuth` needs a child to call tools on,
      // which a remote server is not. Getting this wrong is not a cosmetic
      // mistake - it renders a button that opens a browser and can never
      // complete.
      const kind = m.kind ?? "env";
      const TOOLS = ["loginTool", "statusTool", "logoutTool"];
      if (!["env", "oauth", "childOAuth"].includes(kind)) {
        problems.push(`${mat}: kind must be "env", "oauth" or "childOAuth"`);
      }
      if (kind !== "childOAuth") {
        for (const key of TOOLS) {
          if (m[key] !== undefined) problems.push(`${mat}: ${key} is childOAuth-only`);
        }
      }
      if (kind === "oauth") {
        if (!isRemote) problems.push(`${mat}: an OAuth mode only makes sense on a remote server`);
        if ((m.env ?? []).length) problems.push(`${mat}: an OAuth mode names no variables`);
        continue;
      }
      if (kind === "childOAuth") {
        if (isRemote) {
          problems.push(
            `${mat}: a childOAuth mode is driven through the child's own tools, so it needs a child`,
          );
        }
        if ((m.env ?? []).length) problems.push(`${mat}: a childOAuth mode names no variables`);
        // Named, not inferred from the id. Bastion calls these by name on a
        // real child, so a wrong one is a button that fails at -32601 - and a
        // convention like `<id>_auth_login` would be a guess this file is in
        // no position to make about somebody else's tool names.
        for (const key of TOOLS) {
          if (typeof m[key] !== "string" || !m[key]) {
            problems.push(`${mat}: ${key} is required on a childOAuth mode`);
          }
        }
        continue;
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
    `          kind: .${m.kind ?? "env"},`,
    `          env: ${swiftStringList(m.env)},`,
    `          loginTool: ${swiftOptionalString(m.loginTool ?? null)},`,
    `          statusTool: ${swiftOptionalString(m.statusTool ?? null)},`,
    `          logoutTool: ${swiftOptionalString(m.logoutTool ?? null)}),`,
  ].join("\n");

const swiftCallbackVar = (c) =>
  `.init(name: ${swiftString(c.name)}, format: ${swiftString(c.format)})`;

const swiftCallbackList = (cs) =>
  cs.length === 0 ? "[]" : `[${cs.map(swiftCallbackVar).join(", ")}]`;

const swiftEnvVar = (e) =>
  [
    `        .init(`,
    `          name: ${swiftString(e.name)},`,
    `          isRequired: ${e.required},`,
    `          isSecret: ${e.secret},`,
    e.header
      ? `          summary: ${swiftString(e.description)},\n` +
        `          header: .init(name: ${swiftString(e.header.name)}, format: ${swiftString(e.header.format)})),`
      : `          summary: ${swiftString(e.description)}),`,
  ].join("\n");

/** The transport, as the enum payload that makes the other shape unrepresentable. */
const swiftTransport = (t) =>
  t.kind === "child"
    ? [
        `      transport: .child(`,
        `        .init(`,
        `          npmName: ${swiftString(t.npmName)},`,
        `          binName: ${swiftString(t.binName)},`,
        `          distribution: .${t.distribution},`,
        `          localPath: ${swiftString(t.localPath)})),`,
      ].join("\n")
    : `      transport: .remote(endpoint: URL(string: ${swiftString(t.url)})!),`;

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
    swiftTransport(s.transport),
    `      docsURL: ${swiftOptionalURL(s.docsUrl)},`,
    `      dialect: ${swiftDialect(s.dialect)},`,
    `      writeGate: ${swiftOptionalString(s.writeGate)},`,
    `      writeTools: ${swiftStringList(s.writeTools ?? [])},`,
    `      gateBypass: ${swiftStringList(s.gateBypass)},`,
    s.authModes.length === 0
      ? `      authModes: [],`
      : `      authModes: [\n${s.authModes.map(swiftAuthMode).join("\n")}\n      ],`,
    `      stateEnv: ${swiftStringList(s.stateEnv)},`,
    `      callbackEnv: ${swiftCallbackList(s.callbackEnv)},`,
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
    s.transport.kind === "child" ? mdCode(s.transport.binName) : "—",
    s.transport.kind === "remote"
      ? `${mdCode(s.transport.url)} (remote)`
      : s.transport.distribution === "npm"
        ? `${mdCode(s.transport.npmName)} (npm)`
        : `${mdCode(s.transport.localPath)} (local)`,
    s.writeGate !== null
      ? mdCode(s.writeGate)
      : (s.writeTools ?? []).length
        ? `${s.writeTools.map(mdCode).join(", ")} (by name)`
        : "read-only",
    s.env.filter((e) => e.secret).length || "—",
  ].join(" | ");

const mdDetail = (s) => {
  const out = [`### ${s.displayName}`, "", s.summary, ""];
  if (s.notes.length) out.push(s.notes.join("\n"), "");
  const remote = s.transport.kind === "remote";
  out.push(
    remote
      ? "| Variable | Required | Secret | Sent as | Meaning |"
      : "| Variable | Required | Secret | Meaning |",
    remote ? "| --- | --- | --- | --- | --- |" : "| --- | --- | --- | --- |",
  );
  for (const e of s.env) {
    const cells = [
      mdCode(e.name),
      e.required ? "yes" : "—",
      e.secret ? "yes" : "—",
      ...(remote ? [mdCode(`${e.header.name}: ${e.header.format}`)] : []),
      mdEscape(e.description),
    ];
    out.push(`| ${cells.join(" | ")} |`);
  }
  out.push("");
  if ((s.writeTools ?? []).length) {
    out.push(
      `Hidden with writes off: ${s.writeTools.map(mdCode).join(", ")} — and any tool the ` +
        "server annotates as not read-only. This filters what Bastion forwards; it does not " +
        "bind the server, so the credential's own scopes remain the real boundary.",
      "",
    );
  }
  if (s.authModes.length) {
    // Every kind gets its own sentence, because the parenthesis is the only
    // thing telling a reader where the credential ends up - and an OAuth mode
    // has no variables to list, so the env branch renders it as a name and a
    // dangling dash.
    const modeText = (m) => {
      switch (m.kind) {
        case "oauth":
          return `**${m.displayName}** (no variables — Bastion holds the token)`;
        case "childOAuth":
          return `**${m.displayName}** (no variables — the server holds its own token)`;
        default:
          return `**${m.displayName}** (${m.env.map(mdCode).join(" + ")})`;
      }
    };
    out.push("Satisfy exactly one of: " + s.authModes.map(modeText).join(", "), "");
  }
  if (s.stateEnv.length) {
    out.push(`Per-profile state: ${s.stateEnv.map(mdCode).join(", ")}`, "");
  }
  if (s.callbackEnv.length) {
    out.push(
      "Per-profile OAuth callback: " +
        s.callbackEnv.map((c) => `${mdCode(c.name)} as ${mdCode(c.format)}`).join(", "),
      "",
    );
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
    `    transport: ${tsString(s.transport.kind)},`,
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
