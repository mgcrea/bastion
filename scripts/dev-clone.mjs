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
// Six things move, by four different routes, because they are different kinds
// of thing:
//
//   servers.json   a plain file copy. Carries catalog rows and the definitions
//                  of any custom server, which a catalog lookup cannot rebuild.
//   workspaces.json
//                  a plain file copy too, or removed from the Debug side when
//                  the Release app has none, so both builds scope the same
//                  profiles to the same folders.
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
//   gateway tokens the installed app's per-client tokens, through the same
//                  file, so every config it wrote is accepted by the Debug
//                  build too — both listen on the same port, one at a time.
//   settings       the Settings window's UserDefaults, key by key through
//                  `defaults`. See `SETTINGS` below for which keys, and why the
//                  rest stay.
//
// And one thing is cut down: the Debug `dev.json`. `make dev-config` writes
// two things there — the node to run servers with, which a Debug build has no
// other way to find, and a checkout that every server built in it runs from
// instead of its installed tree. The clone keeps the node and drops the
// checkout, so the Debug build runs what the Release app runs. The original
// goes into the backup, and `make dev-config` writes it again.
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

import { runtimeOnlyDevConfig } from "./lib/dev-config.mjs";

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
const GATEWAY_SERVICE = "io.mgcrea.bastion.gateway";

/**
 * The account names under one keychain service. Names only.
 *
 * `security dump-keychain` without `-d` prints each item's attributes and never
 * its secret, which is the only way to enumerate a service from the command
 * line — `find-generic-password` needs the account up front. Parsed per item
 * (items begin at a `keychain:` line) because an attribute's neighbours in the
 * output belong to a different item often enough to matter.
 */
const accountsIn = (service) => {
  let dump;
  try {
    dump = execFileSync("security", ["dump-keychain"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch {
    return [];
  }
  const out = new Set();
  for (const item of dump.split(/^keychain: /m)) {
    const svce = item.match(/"svce"<blob>="([^"]*)"/)?.[1];
    const acct = item.match(/"acct"<blob>="([^"]*)"/)?.[1];
    if (svce === service && acct) out.add(acct);
  }
  return [...out].toSorted();
};

/**
 * The installed app's gateway tokens, by client — so the Debug build accepts
 * the tokens every client config already carries.
 *
 * Without this a Debug build is a 401 for every editor the moment it is the one
 * listening on the gateway port: the configs were written by the installed app,
 * and each build checks tokens against its own keychain service. A gateway token
 * never rotates, so unlike an OAuth token set this copy cannot sign anything
 * out.
 *
 * `dev` is the one account left alone. It is the Debug build's own scripting
 * identity: the smoke, builtin and dialect checks read it back from the
 * `dev-token` file beside it, as do `.mcp.json` files `make migrate` repointed,
 * and replacing the Keychain half would leave every one of them holding a token
 * the Debug build no longer accepts.
 */
const gatewayTokens = {};
for (const client of accountsIn(GATEWAY_SERVICE)) {
  if (client === "dev") continue;
  const token = keychain(GATEWAY_SERVICE, client);
  if (token) gatewayTokens[client] = token;
}

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

/**
 * The UserDefaults keys that are setup rather than state: the Settings window's
 * controls, nothing else.
 *
 * Left out on purpose: Sparkle's `SU*` keys and `bastion.launchAtLogin` (a
 * Debug build that updates itself or starts at login fights the Release one),
 * `license` (the Debug build keeps its own), window and pane selection, and
 * the one-shot migration markers — copying one of those tells the Debug build
 * a migration ran against files it has not seen.
 *
 * Also left: `autoWireClients`, `reconcileSkills` and
 * `trustProfilesForStaleEntries`. The Release app never stores them, and a
 * Debug build defaults all three to off so a checkout build does not rewrite
 * your real client configs and skill links. Pass `-autoWireClients YES` to
 * the Debug app to change that for one run.
 */
const SETTINGS = [
  "gatewayPort",
  "callCaptureMode",
  "recentActivityAllProfiles",
  "auditEnabled",
  "auditPayloads",
  "auditMaxDays",
  "auditMaxMegabytes",
  "statsEnabled",
  "statsMaxDays",
  "statsIncludeBuiltin",
  "clientKeyPrefix",
  "detectClaudeConfigDirs",
  "claudeConfigDirs",
  "npmMinReleaseAge",
  "lazyToolsDefault",
];

const RELEASE_DOMAIN = "io.mgcrea.bastion";
const DEBUG_DOMAIN = "io.mgcrea.bastion.debug";

/**
 * A domain's settings, as the XML fragment `defaults write` takes, by key.
 *
 * Through an exported plist and `plutil -extract … xml1` rather than `defaults
 * read`, whose old-style output drops the type: `-1` reads back the same as a
 * string and an integer, and the app reads `npmMinReleaseAge` as an integer.
 */
const settingsOf = (domain) => {
  let plist;
  try {
    plist = execFileSync("defaults", ["export", domain, "-"], {
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    // A domain that was never written, which is a fresh Debug build.
    return new Map();
  }
  const out = new Map();
  for (const key of SETTINGS) {
    try {
      const xml = execFileSync("plutil", ["-extract", key, "xml1", "-o", "-", "-"], {
        input: plist,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "ignore"],
      });
      const value = xml.match(/<plist[^>]*>\s*([\s\S]*?)\s*<\/plist>/)?.[1];
      if (value) out.set(key, value);
    } catch {
      // Not set in this domain, so it reads as the app's default.
    }
  }
  return out;
};

const releaseSettings = settingsOf(RELEASE_DOMAIN);
const debugSettings = settingsOf(DEBUG_DOMAIN);
const settingsToWrite = [...releaseSettings].filter(([k, v]) => debugSettings.get(k) !== v);
// Set in the Debug build only, so deleting it gives both builds the default.
const settingsToClear = [...debugSettings.keys()].filter((k) => !releaseSettings.has(k));

const releaseWorkspaces = join(RELEASE, "workspaces.json");
const debugWorkspaces = join(DEBUG, "workspaces.json");
const devConfig = join(DEBUG, "dev.json");
// The node on PATH, the way `make dev-config` finds it: `/opt/homebrew/bin/node`
// outlives an upgrade, where `process.execPath` names the versioned Cellar
// directory the upgrade deletes.
const pathNode =
  (() => {
    try {
      return execFileSync("/bin/sh", ["-c", "command -v node"], { encoding: "utf8" }).trim();
    } catch {
      return "";
    }
  })() || process.execPath;

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
const adopted = Object.keys(gatewayTokens);
say("");
if (adopted.length > 0) {
  say(`${adopted.length} client gateway token(s) carried across, so clients keep working when`);
  say("the Debug build is the one listening:");
  for (const client of adopted) say(`    ${client}`);
} else {
  say("No client gateway tokens found in the Release keychain; clients wired by the");
  say("installed app will be refused by the Debug build until you press Configure there.");
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
say("");
if (existsSync(releaseWorkspaces)) {
  const count = readJSON(releaseWorkspaces, []).length;
  say(`${count} workspace(s) to copy.`);
} else if (existsSync(debugWorkspaces)) {
  say("No workspaces in the Release app; the Debug build's workspaces.json will be removed.");
} else {
  say("No workspaces on either side.");
}
say("");
if (settingsToWrite.length + settingsToClear.length === 0) {
  say("Settings already match.");
} else {
  if (settingsToWrite.length > 0) {
    say(`${settingsToWrite.length} setting(s) to copy:`);
    for (const [key] of settingsToWrite) say(`    ${key}`);
  }
  if (settingsToClear.length > 0) {
    say(`${settingsToClear.length} Debug-only setting(s) to clear back to the default:`);
    for (const key of settingsToClear) say(`    ${key}`);
  }
}
if (existsSync(devConfig)) {
  say("");
  say("dev.json will keep its node and lose its checkout, so every server runs from");
  say("its installed tree. The original goes into the backup; `make dev-config`");
  say("writes it again.");
} else {
  say("");
  say(`dev.json will name ${pathNode}, the node on PATH: a Debug build embeds`);
  say("none, and without one it cannot start any server.");
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
for (const name of ["servers.json", "profiles.json", "workspaces.json"]) {
  const from = join(DEBUG, name);
  if (existsSync(from)) {
    writeFileSync(join(backup, name), readFileSync(from), { mode: 0o600 });
  }
}
// The whole domain, not only the keys about to change: `defaults import
// io.mgcrea.bastion.debug defaults.plist` puts it back as it was.
if (debugSettings.size > 0 || settingsToWrite.length > 0) {
  try {
    execFileSync("defaults", ["export", DEBUG_DOMAIN, join(backup, "defaults.plist")], {
      stdio: "ignore",
    });
  } catch {
    // Never written, so there is nothing to keep.
  }
}
say("");
say(`Backed up the Debug servers.json, profiles.json, workspaces.json and settings to ${backup}`);

// Rewritten rather than moved away. Moving it took the node with it, and a
// Debug build with no dev.json fails every child with "no embedded node
// runtime" — see lib/dev-config.mjs.
const devConfigBefore = existsSync(devConfig) ? readFileSync(devConfig, "utf8") : null;
if (devConfigBefore !== null) {
  writeFileSync(join(backup, "dev.json"), devConfigBefore, { mode: 0o600 });
}
writeFileSync(devConfig, runtimeOnlyDevConfig(devConfigBefore, pathNode), {
  mode: 0o600,
});
say("Wrote dev.json with its node and no checkout, so every server runs from its installed tree");

// The server list, definitions included.
writeFileSync(join(DEBUG, "servers.json"), readFileSync(join(RELEASE, "servers.json")), {
  mode: 0o600,
});
say("Copied servers.json");

if (existsSync(releaseWorkspaces)) {
  writeFileSync(debugWorkspaces, readFileSync(releaseWorkspaces), { mode: 0o600 });
  say("Copied workspaces.json");
} else if (existsSync(debugWorkspaces)) {
  rmSync(debugWorkspaces);
  say("Removed the Debug workspaces.json (the Release app has none)");
}

for (const [key, value] of settingsToWrite) {
  execFileSync("defaults", ["write", DEBUG_DOMAIN, key, value], { stdio: "ignore" });
}
for (const key of settingsToClear) {
  execFileSync("defaults", ["delete", DEBUG_DOMAIN, key], { stdio: "ignore" });
}
if (settingsToWrite.length + settingsToClear.length > 0) {
  say(`Copied ${settingsToWrite.length} setting(s), cleared ${settingsToClear.length}`);
}

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
const document = { gatewayTokens, profiles: rows };
const out = join(DEBUG, "import.json");
writeFileSync(out, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
say(
  `Wrote ${rows.length} profile(s) and ${adopted.length} gateway token(s) to import.json (mode 600)`,
);

say("");
say("Next: launch the Debug build. It consumes import.json on startup, moves every");
say("secret and token into the Debug keychain, and leaves imported.json with the values");
say("stripped. Both builds listen on the same port, so the installed app has to be quit");
say("first — which `make run` does, since `make stop` matches both.");
say("");
say("    make run");
