#!/usr/bin/env node
// Verify what `servers.json` claims about npm build provenance against the registry.
//
// Deliberately NOT part of `make servers`. The generator has to stay offline and
// deterministic, because `pnpm run servers:check` is a CI drift gate: if the
// manifest were rewritten from the network, a third party publishing overnight
// would turn an unrelated pull request red. So `provenance` is a stated claim in
// the manifest, exactly like `vendor`, and this script is what keeps the claim
// honest.
//
// The claim being checked is not "npm has an attestation for this package". It is
// "this package was built by GitHub Actions from the repository this catalog entry
// already names in docsUrl". Provenance pointing at some unrelated repository
// proves close to nothing about the entry a reader is looking at; provenance
// pointing at the linked repo is the form of the signal that survives a
// typosquat.
//
// Two directions of drift, and they are not symmetric:
//
//   claims true, no longer verifies  -> STRICT. Bastion is making a false claim
//                                       to somebody deciding whether to run code
//                                       on their machine.
//   claims false, now verifies       -> ADVICE. Somebody improved their release
//                                       process and the catalog can say so. That
//                                       is good news, and good news must not fail
//                                       a build.
//
// Same split, and the same reasoning, as the STRICT/ADVICE lists in catalog-check.mjs.
//
// Usage:
//   node scripts/provenance-check.mjs           # print the table, exit 0
//   node scripts/provenance-check.mjs --json    # the same, as {id: boolean}
//   node scripts/provenance-check.mjs --check   # verify the manifest's claims
//   node scripts/provenance-check.mjs --check --strict   # advice fails too

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const MANIFEST = join(ROOT, "servers.json");

const REGISTRY = "https://registry.npmjs.org";
const SLSA_PREDICATE = "https://slsa.dev/provenance/v1";
// The hosted-runner id GitHub's OIDC identity signs with. A self-hosted runner
// reports a different id, and that is a different trust story, so it is not
// waved through here.
const GITHUB_BUILDER = "https://github.com/actions/runner/github-hosted";

const args = new Set(process.argv.slice(2));
const CHECK = args.has("--check");
const STRICT = args.has("--strict");
const JSON_OUT = args.has("--json");

/** GET and parse JSON, with the one retry that a flaky registry actually needs. */
async function getJSON(url, accept) {
  let last;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const res = await fetch(url, { headers: accept ? { accept } : {} });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return await res.json();
    } catch (error) {
      last = error;
    }
  }
  throw last;
}

/** `https://github.com/mgcrea/mcp-npm` and friends -> `mgcrea/mcp-npm`. */
function repoSlug(url) {
  if (!url) return null;
  const match = /^https:\/\/github\.com\/([^/]+\/[^/#?]+?)(?:\.git)?\/?$/.exec(url);
  return match ? match[1].toLowerCase() : null;
}

/**
 * Resolve one package to what its latest published version can actually prove.
 *
 * Returns `{ version, attested, repo, ref, builder, reason }`. `attested` is the
 * verdict this script exists to produce: an attestation that is present, from
 * GitHub Actions, and from the expected repository.
 */
async function inspect(npmName, docsUrl) {
  const encoded = npmName.replace("/", "%2f");

  const packument = await getJSON(`${REGISTRY}/${encoded}`, "application/vnd.npm.install-v1+json");
  if (!packument) return { reason: "not published" };

  const version = packument["dist-tags"]?.latest;
  if (!version) return { reason: "no latest tag" };

  const dist = packument.versions?.[version]?.dist ?? {};
  if (!dist.attestations) return { version, attested: false, reason: "no attestation" };

  const bundles = await getJSON(`${REGISTRY}/-/npm/v1/attestations/${encoded}@${version}`);
  const slsa = bundles?.attestations?.find((a) => a.predicateType === SLSA_PREDICATE);
  if (!slsa) return { version, attested: false, reason: "no SLSA statement" };

  const payload = slsa.bundle?.dsseEnvelope?.payload;
  if (!payload) return { version, attested: false, reason: "no DSSE payload" };

  const statement = JSON.parse(Buffer.from(payload, "base64").toString("utf8"));
  const predicate = statement.predicate ?? {};
  const workflow = predicate.buildDefinition?.externalParameters?.workflow ?? {};
  const builder = predicate.runDetails?.builder?.id ?? null;

  const repo = repoSlug(workflow.repository);
  const expected = repoSlug(docsUrl);

  if (builder !== GITHUB_BUILDER) {
    return { version, attested: false, repo, builder, reason: `builder ${builder ?? "unknown"}` };
  }
  if (!expected) {
    return { version, attested: false, repo, builder, reason: "docsUrl is not a GitHub repo" };
  }
  if (repo !== expected) {
    return {
      version,
      attested: false,
      repo,
      builder,
      reason: `built from ${repo}, entry names ${expected}`,
    };
  }

  return { version, attested: true, repo, ref: workflow.ref, builder, path: workflow.path };
}

const manifest = JSON.parse(readFileSync(MANIFEST, "utf8"));
const entries = manifest.servers.filter(
  (s) => s.transport.kind === "child" && s.transport.distribution === "npm",
);

const results = await Promise.all(
  entries.map(async (entry) => {
    try {
      return { entry, result: await inspect(entry.transport.npmName, entry.docsUrl) };
    } catch (error) {
      return { entry, error };
    }
  }),
);

const unreachable = [];
const falseClaims = [];
const nowEarned = [];

for (const { entry, result, error } of results) {
  if (error) {
    unreachable.push(`${entry.id}: ${error.message}`);
    continue;
  }
  const declared = entry.transport.provenance === true;
  if (declared && !result.attested) falseClaims.push({ entry, result });
  if (!declared && result.attested) nowEarned.push({ entry, result });
}

if (JSON_OUT) {
  // The shape `servers.json` wants, so setting the flags is a mechanical step
  // and never a hand-transcribed one. An unreachable package is omitted rather
  // than guessed at.
  const map = {};
  for (const { entry, result, error } of results) {
    if (!error) map[entry.id] = result.attested === true;
  }
  console.log(JSON.stringify(map, null, 2));
} else if (!CHECK) {
  const width = Math.max(...entries.map((e) => e.transport.npmName.length));
  for (const { entry, result, error } of results) {
    const name = entry.transport.npmName.padEnd(width);
    if (error) {
      console.log(`  ??  ${name}  ${error.message}`);
      continue;
    }
    const mark = result.attested ? "ok  " : "--  ";
    const detail = result.attested ? `${result.repo} @ ${result.ref ?? "?"}` : result.reason;
    console.log(`  ${mark}${name}  ${(result.version ?? "-").padEnd(10)}  ${detail}`);
  }
  const yes = results.filter((r) => r.result?.attested).length;
  console.log(
    `\n${yes} of ${entries.length} npm entries build with provenance from the repo they name.`,
  );
}

let failed = false;

if (falseClaims.length) {
  failed = true;
  console.error("\nFALSE CLAIM — servers.json says provenance, npm does not agree:");
  for (const { entry, result } of falseClaims) {
    console.error(
      `  ${entry.id} (${entry.transport.npmName}@${result.version ?? "?"}): ${result.reason}`,
    );
  }
  console.error("  Set transport.provenance to false, or find out why the release changed.");
}

if (nowEarned.length) {
  console.warn(
    "\nADVICE — these now build with provenance and the catalog still says they do not:",
  );
  for (const { entry, result } of nowEarned) {
    console.warn(
      `  ${entry.id} (${entry.transport.npmName}@${result.version}): built from ${result.repo}`,
    );
  }
  console.warn("  Set transport.provenance to true and re-run `make servers`.");
  if (STRICT) failed = true;
}

if (unreachable.length) {
  console.warn(`\nCould not be checked (${unreachable.length}):`);
  for (const line of unreachable) console.warn(`  ${line}`);
  if (STRICT) failed = true;
}

if (CHECK && !failed && !nowEarned.length && !unreachable.length) {
  console.log(`Provenance claims match npm for all ${entries.length} npm entries.`);
}

process.exit(failed ? 1 : 0);
