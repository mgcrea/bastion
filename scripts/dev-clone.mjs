#!/usr/bin/env node
// Put the installed Release app's setup into the Debug build, so development
// happens against the servers and profiles you actually use.
//
// The two builds are deliberately isolated: a Debug build has its own bundle
// identifier, which gives it its own Application Support directory AND its own
// Keychain services. That isolation is load-bearing — it is what keeps a check
// script from writing over the real app's state — so this does not remove it.
// It copies across it, once, when you ask.
//
// Three things move, by three different routes, because they are three
// different kinds of thing:
//
//   servers.json   a plain file copy. Carries catalog rows and the definitions
//                  of any custom server, which a catalog lookup cannot rebuild.
//   servers/       the downloaded npm trees, copied with `/bin/cp -Rc`, which
//                  uses clonefile(2) — on APFS the two copies share blocks, so
//                  300MB of trees costs almost nothing. It falls back to a real
//                  copy where cloning is unsupported. Skipped with
//                  --no-installs, in which case the Debug app downloads them.
//   profiles       an `import.json` document, which is the mechanism the Debug
//                  build already has for exactly this (see `DevSeed`). Secret
//                  values are read out of the Release Keychain and written into
//                  that file; the app moves them into the DEBUG Keychain on
//                  next launch and strips the file to `imported.json`.
//
// What deliberately does NOT move: OAuth token sets. See `oauthProfiles` below
// — copying one risks signing the real app out, and re-authorizing in the Debug
// build is one button.
//
// No secret value is ever printed. Names only.

import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const SUPPORT = join(homedir(), "Library/Application Support");
const RELEASE = join(SUPPORT, "io.mgcrea.bastion");
const DEBUG = join(SUPPORT, "io.mgcrea.bastion.debug");

const DRY = process.argv.includes("--dry-run");
const NO_INSTALLS = process.argv.includes("--no-installs");

const say = (line = "") => console.log(line);
const die = (line) => {
  console.error(line);
  process.exit(1);
};

// ─── refuse to run into a moving target ──────────────────────────────────────

/** The pid in a `bastion.lock`, if that process is still alive. */
const runningPid = (dir) => {
  const lock = join(dir, "bastion.lock");
  if (!existsSync(lock)) return null;
  const pid = Number.parseInt(readFileSync(lock, "utf8").split(/\s+/)[0], 10);
  if (!Number.isInteger(pid)) return null;
  try {
    // Signal 0 tests for existence without delivering anything.
    process.kill(pid, 0);
    return pid;
  } catch {
    // ESRCH: the lock outlived the process it named, which is the ordinary
    // case after a crash or a force quit.
    return null;
  }
};

if (!existsSync(RELEASE)) {
  die(
    `No Release setup at ${RELEASE}.\n` +
      "This copies the installed app's state into the Debug build; there is nothing to copy yet.",
  );
}

const debugPid = runningPid(DEBUG);
if (debugPid !== null) {
  die(
    `The Debug build is running (pid ${debugPid}).\n` +
      "It holds servers.json and profiles.json in memory and writes them back on the next edit, " +
      "so anything written now would be overwritten.\n" +
      "Quit it from its menu bar item, then run this again. (`make stop` matches on the " +
      "executable name, so it would quit the installed Release app too.)",
  );
}

// The Release app may go on running. Nothing here writes to its directory, and
// its Keychain items are only read.

// ─── what the manifest says is a secret ──────────────────────────────────────

const manifest = JSON.parse(readFileSync(join(ROOT, "servers.json"), "utf8"));
const catalog = new Map(manifest.servers.map((s) => [s.id, s]));

/**
 * The variables a server treats as secret, by name.
 *
 * From the repo manifest for a catalog server, and from the stored definition
 * for a custom one — a custom server is not in the catalog by construction, and
 * reading its own `env` is the only way to know which of its variables are
 * secret rather than ordinary configuration.
 */
const secretNames = (serverId, stored) => {
  const env = catalog.get(serverId)?.env ?? stored?.definition?.env ?? [];
  return new Set(env.filter((v) => v.secret || v.isSecret).map((v) => v.name));
};

// ─── read ────────────────────────────────────────────────────────────────────

const readJSON = (path, fallback) =>
  existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : fallback;

const releaseServers = readJSON(join(RELEASE, "servers.json"), []);
const releaseProfiles = readJSON(join(RELEASE, "profiles.json"), []);
const storedById = new Map(releaseServers.map((s) => [s.id, s]));

if (releaseProfiles.length === 0) {
  die(`No profiles in ${join(RELEASE, "profiles.json")}. Nothing to copy.`);
}

/** One generic password out of the Release keychain, or null if it is not there. */
const keychain = (service, account) => {
  try {
    const out = execFileSync(
      "security",
      ["find-generic-password", "-s", service, "-a", account, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    );
    // Exactly one trailing newline, which `security` adds. Stripping all
    // trailing whitespace would corrupt a PEM private key, which is one of the
    // shapes stored here.
    return out.endsWith("\n") ? out.slice(0, -1) : out;
  } catch {
    return null;
  }
};

const PROFILE_SERVICE = "io.mgcrea.bastion.profile";
const OAUTH_SERVICE = "io.mgcrea.bastion.oauth";

/**
 * Profiles whose credential is an OAuth token set rather than a typed secret.
 *
 * Not copied, and that is a decision rather than an omission. A refresh token
 * is frequently single-use: the first build to refresh it rotates it, and the
 * copy the other build holds stops working. Copying would therefore risk
 * signing the REAL app out of Stripe or Cloudflare to save one button press in
 * the Debug one. Named in the summary instead, so it is a known next step
 * rather than a profile that silently does not answer.
 */
const oauthProfiles = releaseProfiles
  .filter((p) => keychain(OAUTH_SERVICE, `${p.name}/${p.server}/oauth`) !== null)
  .map((p) => `${p.name}/${p.server}`);

// ─── plan ────────────────────────────────────────────────────────────────────

const rows = [];
const found = [];
const absent = [];
/**
 * Profiles the import will refuse, because their server is neither installed
 * nor in the catalog.
 *
 * A profile outlives the server it names: `ProfileStore` keeps an orphan in the
 * file rather than destroying its configuration over a temporary uninstall. So
 * the Release file can hold profiles for servers that are not in its own
 * servers.json, and `DevSeed` installs the ones the catalog knows and logs
 * `unknown server` for the rest. Named here so that skip is expected rather
 * than discovered in the log.
 */
const unresolvable = [];

for (const profile of releaseProfiles) {
  const stored = storedById.get(profile.server);
  if (!stored && !catalog.has(profile.server)) {
    unresolvable.push(`${profile.name}/${profile.server}`);
  }
  const secrets = secretNames(profile.server, stored);
  const values = { ...profile.values };

  for (const name of [...secrets].toSorted()) {
    const account = `${profile.name}/${profile.server}/${name}`;
    const value = keychain(PROFILE_SERVICE, account);
    if (value === null) {
      absent.push(account);
      continue;
    }
    values[name] = value;
    found.push(account);
  }

  rows.push({
    name: profile.name,
    server: profile.server,
    allowWrites: profile.allowWrites ?? false,
    values,
  });
}

// ─── report ──────────────────────────────────────────────────────────────────

say(`Release  ${RELEASE}`);
say(`Debug    ${DEBUG}`);
say("");
say(`${releaseServers.length} server(s), ${releaseProfiles.length} profile(s) to copy.`);
const custom = releaseServers.filter((s) => s.definition).map((s) => s.id);
if (custom.length > 0) say(`  custom server definitions: ${custom.join(", ")}`);
say("");
say(`${found.length} secret(s) read from the Release keychain:`);
for (const account of found) say(`    ${account}`);
if (absent.length > 0) {
  say("");
  say(`${absent.length} secret(s) the manifest expects but the keychain does not hold:`);
  for (const account of absent) say(`    ${account}`);
  say("  (set them in the Debug app, or they were never set in the Release one)");
}
if (unresolvable.length > 0) {
  say("");
  say(`${unresolvable.length} profile(s) name a server that is neither installed nor in the`);
  say("catalog, so the import will skip them:");
  for (const id of unresolvable) say(`    ${id}`);
  say("  (they are orphans in the Release app too — add the server to bring them back)");
}
if (oauthProfiles.length > 0) {
  say("");
  say(`${oauthProfiles.length} profile(s) authorize over OAuth and are NOT copied:`);
  for (const id of oauthProfiles) say(`    ${id}`);
  say("  Press Authorize on each in the Debug app. Copying a refresh token risks");
  say("  rotating it out from under the Release app.");
}

if (DRY) {
  say("");
  say("--dry-run: nothing written.");
  process.exit(0);
}

// ─── write ───────────────────────────────────────────────────────────────────

mkdirSync(DEBUG, { recursive: true, mode: 0o700 });

// Kept, not overwritten. The previous Debug setup is somebody's work too, and
// this is the only copy of it once the write below lands.
const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
const backup = join(DEBUG, "clone-backup", stamp);
mkdirSync(backup, { recursive: true, mode: 0o700 });
for (const name of ["servers.json", "profiles.json"]) {
  const from = join(DEBUG, name);
  if (existsSync(from)) {
    writeFileSync(join(backup, name), readFileSync(from), { mode: 0o600 });
  }
}
say("");
say(`Backed up the Debug servers.json and profiles.json to ${backup}`);

// The server list, definitions included.
writeFileSync(join(DEBUG, "servers.json"), readFileSync(join(RELEASE, "servers.json")), {
  mode: 0o600,
});
say("Copied servers.json");

// profiles.json is deliberately NOT copied. The import below rebuilds it
// through `ProfileStore.upsert`, which is what routes each secret into the
// Debug keychain — a file copy would carry the profiles across with every
// secret still pointing at a keychain the Debug build cannot read.
if (existsSync(join(DEBUG, "profiles.json"))) rmSync(join(DEBUG, "profiles.json"));

// The downloaded npm trees. `/bin/cp` by absolute path deliberately: `-c` is
// BSD cp's clonefile flag, and a GNU coreutils cp earlier on PATH — which is the
// normal arrangement on a Homebrew Mac — has no such flag and would fail.
if (!NO_INSTALLS && existsSync(join(RELEASE, "servers"))) {
  const target = join(DEBUG, "servers");
  const moved = existsSync(target) ? `${target}.replaced-${stamp}` : null;
  if (moved) renameSync(target, moved);
  try {
    execFileSync("/bin/cp", ["-Rc", join(RELEASE, "servers"), target], { stdio: "ignore" });
    if (moved) rmSync(moved, { recursive: true, force: true });
    const count = readdirSync(target).filter((n) => !n.startsWith(".")).length;
    say(`Copied ${count} installed server tree(s) (cloned on APFS, so near-zero disk)`);
  } catch (error) {
    if (moved) renameSync(moved, target);
    say(`Could not clone the server trees (${error.message.trim()}).`);
    say("The Debug app will download what it needs instead.");
  }
} else if (NO_INSTALLS) {
  say("Skipped the installed server trees (--no-installs)");
}

// The profiles, as the document `DevSeed` already knows how to consume.
const document = { profiles: rows };
const out = join(DEBUG, "import.json");
writeFileSync(out, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
say(`Wrote ${rows.length} profile(s) to import.json (mode 600)`);

say("");
say("Next: launch the Debug build. It consumes import.json on startup, moves every");
say("secret into the Debug keychain, and leaves imported.json with the values stripped.");
say("");
say("    make run");
