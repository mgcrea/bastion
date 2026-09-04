#!/usr/bin/env node
// What ELSE is out there, ranked by how many people install it.
//
// The catalog is a starting point rather than a closed list, which only stays
// true if somebody occasionally looks. This is that look, made repeatable:
// enumerate the MCP servers published to npm, drop the ones already seeded and
// the ones nobody should install, and sort what is left by monthly downloads.
//
// ## Why downloads, and why nothing else
//
// Every directory that ranks MCP servers ranks them badly or not at all. The
// npm registry's own `popularity` score put `yahoo-finance2` and `neo.mjs` in
// the top twenty for `keywords:mcp-server`. The official registry at
// registry.modelcontextprotocol.io is a firehose rather than a curation: of
// 1,200 latest entries only 166 ship an npm package at all, the rest being
// vendor-published remote endpoints. Glama's API needs a key and its licence
// demands a visible backlink on every page that displays the data. PulseMCP's
// v0beta is being deliberately sunset - it already fails a tenth of requests on
// purpose. So: enumerate widely, rank by the one number that is a fact.
//
// ## What the number does and does not say
//
// It says how many machines ran `npm install`. It does not say the package is
// maintained, safe, or even alive: `@modelcontextprotocol/server-github` takes
// half a million downloads a month and has carried `deprecated` since the repo
// was archived. Deprecated packages are dropped here for exactly that reason,
// and everything surviving that filter is still a candidate to READ, not a
// candidate to add. `add-catalog-server` is what turns one into an entry.
//
//   node scripts/discover-servers.mjs
//   node scripts/discover-servers.mjs --limit 60 --json

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const args = process.argv.slice(2);
const JSON_OUT = args.includes("--json");
const LIMIT = Number(args[args.indexOf("--limit") + 1]) || 40;

// Both spellings, because a package is free to pick either and plenty pick one.
// `keywords:mcp` alone returns seventy thousand packages, most of them clients,
// frameworks and abandoned experiments — too wide to be a starting point.
const KEYWORDS = ["mcp-server", "modelcontextprotocol"];
const PAGE = 250;

const seeded = new Set(
  (JSON.parse(readFileSync(join(ROOT, "servers.json"), "utf8")).servers ?? [])
    .map((s) => s.transport?.npmName)
    .filter(Boolean),
);

const getJSON = async (url) => {
  const response = await fetch(url, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`${response.status} ${url}`);
  return response.json();
};

/** Every package carrying one of the keywords, deduplicated by name. */
const enumerate = async () => {
  const found = new Map();
  for (const keyword of KEYWORDS) {
    for (let from = 0; from < 1000; from += PAGE) {
      const url =
        "https://registry.npmjs.org/-/v1/search?text=" +
        encodeURIComponent(`keywords:${keyword}`) +
        `&size=${PAGE}&from=${from}`;
      let page;
      try {
        page = await getJSON(url);
      } catch {
        break;
      }
      for (const { package: p } of page.objects ?? []) {
        if (!found.has(p.name)) found.set(p.name, p);
      }
      if ((page.objects ?? []).length < PAGE) break;
    }
  }
  return found;
};

/** Monthly downloads, in bulk where npm allows it and one by one where it does not. */
const downloadsFor = async (names) => {
  const out = new Map();
  // The bulk endpoint refuses scoped names, so those go one at a time. Batched
  // rather than fired all at once: this is somebody else's registry.
  const plain = names.filter((n) => !n.startsWith("@"));
  const scoped = names.filter((n) => n.startsWith("@"));

  for (let i = 0; i < plain.length; i += 100) {
    const batch = plain.slice(i, i + 100);
    try {
      const data = await getJSON(
        `https://api.npmjs.org/downloads/point/last-month/${batch.join(",")}`,
      );
      // A single-name request answers with the record itself, not a map of them.
      if (batch.length === 1) out.set(batch[0], data?.downloads ?? 0);
      else for (const [name, record] of Object.entries(data)) out.set(name, record?.downloads ?? 0);
    } catch {
      /* a batch that fails is a batch of unknowns, not a reason to stop */
    }
  }
  for (let i = 0; i < scoped.length; i += 20) {
    await Promise.all(
      scoped.slice(i, i + 20).map(async (name) => {
        try {
          const data = await getJSON(
            `https://api.npmjs.org/downloads/point/last-month/${encodeURIComponent(name)}`,
          );
          out.set(name, data?.downloads ?? 0);
        } catch {
          /* same */
        }
      }),
    );
  }
  return out;
};

/** Deprecated, and therefore not a candidate however many people still install it. */
const deprecations = async (names) => {
  const out = new Set();
  for (let i = 0; i < names.length; i += 20) {
    await Promise.all(
      names.slice(i, i + 20).map(async (name) => {
        try {
          const meta = await getJSON(
            `https://registry.npmjs.org/${encodeURIComponent(name).replace("%40", "@")}/latest`,
          );
          if (meta?.deprecated) out.add(name);
        } catch {
          /* unreachable is not deprecated */
        }
      }),
    );
  }
  return out;
};

const found = await enumerate();
console.error(`enumerated ${found.size} packages from npm`);

const ranked = [...found.keys()].filter((n) => !seeded.has(n));
const downloads = await downloadsFor(ranked);
const top = ranked
  .filter((n) => (downloads.get(n) ?? 0) > 0)
  .toSorted((a, b) => (downloads.get(b) ?? 0) - (downloads.get(a) ?? 0))
  .slice(0, LIMIT * 2);

const dead = await deprecations(top);
const rows = top
  .filter((n) => !dead.has(n))
  .slice(0, LIMIT)
  .map((name) => ({
    name,
    downloads: downloads.get(name) ?? 0,
    description: found.get(name)?.description ?? "",
    updated: (found.get(name)?.date ?? "").slice(0, 10),
  }));

if (JSON_OUT) {
  console.log(JSON.stringify(rows, null, 2));
} else {
  console.log(
    `\nTop ${rows.length} MCP packages on npm not already in the catalog, by downloads in the ` +
      `last month.\n${dead.size} deprecated package(s) dropped from the ranking.\n`,
  );
  for (const r of rows) {
    console.log(
      `${String(r.downloads).padStart(10)}  ${r.name.padEnd(42)} ${r.updated}  ` +
        r.description.slice(0, 60),
    );
  }
  console.log(
    "\nA number here is a reason to READ a package, never a reason to add one. " +
      "`add-catalog-server`\nis what turns one into an entry, and it starts by reading the " +
      "server's own source.",
  );
}
