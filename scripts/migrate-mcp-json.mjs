#!/usr/bin/env node
// Move the credentials in `mgcrea-ai/*/.mcp.json` into Bastion.
//
// Two phases, deliberately separated by a verification you do yourself:
//
//   --plan       read the configs, report exactly what would move, and write an
//                import document for the Debug build. Touches no source file.
//   --repoint    rewrite each `.mcp.json` to call Bastion over loopback, after
//                backing the original up outside the repo.
//
// They are separate because the second is the irreversible half and the first
// is how you find out whether the second is safe. Between them, launch Bastion
// and check that every profile answers — a repointed config whose profile does
// not work is a repo that has lost its MCP server.
//
// What actually moves: a value the manifest marks `secret` goes into the
// Keychain and is then absent from every file. Everything else is ordinary
// configuration and stays legible in `profiles.json`.
//
// No secret value is ever printed. Names only.

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { chmodSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const SOURCE = process.env.MCP_ROOT ?? join(homedir(), "Projects/mgcrea/mgcrea-ai");
const SUPPORT = join(homedir(), "Library/Application Support/io.mgcrea.bastion.debug");
const BACKUPS = join(SUPPORT, "migration-backup");
const PORT = process.env.BASTION_PORT ?? "8720";
const PROFILE = process.env.PROFILE ?? "prod";

const REPOINT = process.argv.includes("--repoint");
if (!REPOINT && !process.argv.includes("--plan")) {
  console.error("usage: migrate-mcp-json.mjs --plan | --repoint");
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(join(ROOT, "servers.json"), "utf8"));
const byId = new Map(manifest.servers.map((s) => [s.id, s]));

const expand = (p) => (p?.startsWith("~") ? join(homedir(), p.slice(1)) : p);

/** Every `.mcp.json` under the source tree, with its entries resolved to manifest ids. */
const discover = () => {
  const found = [];
  for (const dir of readdirSync(SOURCE).filter((d) => d.startsWith("mcp-"))) {
    const file = join(SOURCE, dir, ".mcp.json");
    if (!existsSync(file)) continue;
    const document = JSON.parse(readFileSync(file, "utf8"));
    const servers = document.mcpServers ?? document.servers ?? {};
    for (const [key, entry] of Object.entries(servers)) {
      if (!entry.env || Object.keys(entry.env).length === 0) continue;
      // The config key is not always the manifest id: mcp-x calls its
      // entry `x-dev`. Longest matching id wins, so `x` is not
      // shadowed by a shorter one.
      const id = [...byId.keys()]
        .filter((candidate) => key === candidate || key.startsWith(`${candidate}-`))
        .toSorted((a, b) => b.length - a.length)[0];
      found.push({ dir, file, key, id, entry, document });
    }
  }
  return found;
};

/**
 * Split one entry's env into what the Keychain takes and what stays legible.
 *
 * The `.p8` case is the interesting one. mcp-appstore-connect points at a key
 * file on disk, and the manifest's own note calls the inline form preferred
 * because Bastion then holds the key and nothing writes it anywhere. So the
 * file is READ here and migrated as the inline variable — which is the only
 * transformation in this script that changes the shape of a config rather than
 * its location.
 */
const classify = ({ id, entry }) => {
  const server = byId.get(id);
  const known = new Map(server.env.map((e) => [e.name, e]));
  const secrets = {};
  const values = {};
  const dropped = [];
  const notes = [];

  for (const [name, value] of Object.entries(entry.env)) {
    if (!value) continue;
    if (name === "APP_STORE_CONNECT_P8_PATH") {
      const path = expand(value);
      if (existsSync(path)) {
        secrets.APP_STORE_CONNECT_P8 = readFileSync(path, "utf8");
        const mode = (statSync(path).mode & 0o777).toString(8);
        notes.push(
          `read the private key from ${path} (mode ${mode}) and migrated it as the inline ` +
            `APP_STORE_CONNECT_P8, which the manifest prefers` +
            (mode === "644" ? " — the file itself is world-readable, worth chmod 600" : ""),
        );
        continue;
      }
      notes.push(`APP_STORE_CONNECT_P8_PATH points at ${path}, which does not exist`);
      continue;
    }
    const spec = known.get(name);
    if (!spec) {
      // A gate bypass is not settable by design, so it is neutralised rather
      // than dropped — calling it "dropped" would read as data loss when it is
      // the opposite.
      if (!server.gateBypass.includes(name)) dropped.push(name);
      continue;
    }
    if (spec.secret) secrets[name] = value;
    else values[name] = value;
  }

  // The gate is a property of the profile, not a variable, so it is read out of
  // the env and set as a flag. Preserved exactly as found: turning somebody's
  // write access off during a migration is not a migration.
  let allowWrites = false;
  if (server.writeGate && entry.env[server.writeGate]) {
    allowWrites = /^(1|true|yes|on)$/i.test(entry.env[server.writeGate]);
    delete values[server.writeGate];
  }
  for (const bypass of server.gateBypass) {
    if (entry.env[bypass]) {
      allowWrites ||= /^(1|true|yes|on)$/i.test(entry.env[bypass]);
      notes.push(
        `${bypass} was set — it ORs into the write flag, so the profile's gate is on to preserve ` +
          `current behaviour. Bastion forces the variable itself to "0" so the gate is the only switch.`,
      );
    }
  }

  return { server, secrets, values, dropped, notes, allowWrites };
};

/**
 * Servers this migration deliberately leaves alone, and why.
 *
 * mcp-x keeps its client id and secret in the file named by `X_CONFIG`,
 * not in `.mcp.json`, and that variable is `stateEnv` — Bastion points it at
 * the profile's own directory so two profiles cannot share one login. Moving
 * the entry without moving the file would migrate no secret at all AND leave
 * every profile reading one absolute path, which is the isolation failure the
 * whole profile model exists to prevent. Doing it properly means migrating the
 * config file and its token file together, and re-authenticating.
 */
const SKIP = {
  x:
    "its credentials live in the file named by X_CONFIG, not in .mcp.json — migrating it " +
    "means moving that file and its OAuth token file together, and logging in again",
};

const found = discover();
const skipped = found.filter((f) => f.id && SKIP[f.id]);
const plans = found
  .filter((f) => f.id && !SKIP[f.id])
  .map((f) => ({ ...f, ...classify(f) }))
  .filter((p) => Object.keys(p.secrets).length || Object.keys(p.values).length);

const unmatched = found.filter((f) => !f.id);

// ─── plan ────────────────────────────────────────────────────────────────────

if (!REPOINT) {
  console.log("");
  for (const p of plans) {
    const gate = p.server.writeGate
      ? `${p.allowWrites ? "ON" : "off"} (${p.server.writeGate})`
      : "read-only server";
    console.log(`${p.dir}  →  ${PROFILE}/${p.id}`);
    console.log(`  to the Keychain : ${Object.keys(p.secrets).join(", ") || "(nothing)"}`);
    console.log(`  stays in config : ${Object.keys(p.values).join(", ") || "(nothing)"}`);
    console.log(`  write gate      : ${gate}`);
    if (p.dropped.length)
      console.log(`  dropped         : ${p.dropped.join(", ")} (not in the manifest)`);
    for (const note of p.notes) console.log(`  note            : ${note}`);
    console.log("");
  }
  for (const u of unmatched) {
    console.log(`${u.dir}: "${u.key}" matches no manifest server — left alone`);
  }
  for (const k of skipped) {
    console.log(`${k.dir}: skipped — ${SKIP[k.id]}`);
    console.log("");
  }

  mkdirSync(SUPPORT, { recursive: true });
  // No `token` key: issuing one would replace the token the existing entries
  // already authenticate with.
  const document = {
    profiles: plans.map((p) => ({
      name: PROFILE,
      server: p.id,
      allowWrites: p.allowWrites,
      values: { ...p.values, ...p.secrets },
    })),
  };
  const out = join(SUPPORT, "import.json");
  writeFileSync(out, JSON.stringify(document, null, 2), { mode: 0o600 });
  console.log(`Wrote ${plans.length} profile(s) to ${out} (mode 600).`);
  console.log("");
  console.log("Next: launch the Debug build so it imports them, check each profile answers,");
  console.log("then run this again with --repoint.");
  process.exit(0);
}

// ─── repoint ─────────────────────────────────────────────────────────────────

const tokenPath = join(SUPPORT, "dev-token");
if (!existsSync(tokenPath)) {
  console.error(`no gateway token at ${tokenPath} — launch the Debug build once first`);
  process.exit(2);
}
const token = readFileSync(tokenPath, "utf8").trim();

mkdirSync(BACKUPS, { recursive: true });
chmodSync(BACKUPS, 0o700);

// One backup per repo, not per entry: the file is the unit being rewritten.
const files = new Map();
for (const p of plans) {
  if (!files.has(p.file)) files.set(p.file, { document: p.document, dir: p.dir, entries: [] });
  files.get(p.file).entries.push(p);
}

console.log("");
for (const [file, { document, dir, entries }] of files) {
  const backup = join(BACKUPS, `${dir}.mcp.json`);
  copyFileSync(file, backup);
  chmodSync(backup, 0o600);

  const servers = document.mcpServers ?? document.servers;
  for (const entry of entries) {
    servers[entry.key] = {
      type: "http",
      url: `http://127.0.0.1:${PORT}/s/${PROFILE}/${entry.id}`,
      // The token travels; the credential does not. That split is the whole
      // point: this file leaking now costs a revocable loopback token instead
      // of a brokerage refresh token.
      headers: { Authorization: `Bearer ${token}` },
    };
  }
  writeFileSync(file, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
  console.log(`${dir}: repointed ${entries.map((e) => e.key).join(", ")}`);
  console.log(`  backup → ${backup}`);
}
console.log("");
console.log(
  "Done. The originals are the only remaining copy of those secrets outside the Keychain;",
);
console.log("delete the backup directory once you are satisfied everything works.");
