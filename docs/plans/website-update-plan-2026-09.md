# bastion.mgcrea.io — update plan from the September 2026 competitive brief

**Verdict first:** the site does not need a redesign. Every sentence the brief says Bastion should own is already written somewhere in `apps/website/src` — the problem is _where_. The "no Docker" claim is the fifth card on the pricing section; the Keychain claim is a clause in the hero paragraph; the audit design lives on `/checked`, which nothing in the nav points to. The work is emphasis, two new page types, and closing one product gap before a comparison table makes it visible. Roughly three small PRs and one medium one.

Current section order in `src/pages/index.astro`: Nav · Hero · Marquee · ServerPane · Problem · HowItWorks · Context · Audit · Screens · Rules · Servers · Gaps · Pricing · SiblingApp · Cta · Footer. Nav links: How it works · Security · Servers · The app · Price.

Everything below respects the site's own rules from `apps/website/CLAUDE.md`: facts come from `src/config.ts`, counts are derived from `servers.json`, anything purchasable sits behind `SHIPPED`, drawings never disagree with captures, and `pnpm icons` has to be re-run if `SOCIAL_CARD` changes.

---

## Phase 1 — Move the two undefended claims above the fold (one PR, ~half a day)

**1a. Hero paragraph (`Hero.astro`).** Today: _"Bastion is a menu-bar app that supervises your MCP servers instead of letting each editor spawn its own. One process per profile, credentials in the Keychain, and every tool call recorded."_ Keep the h1 — "One MCP server, running once, for every client" is the best headline in the category. Add one sentence to the paragraph that no competitor can copy and that answers the Docker/ToolHive objection before it is raised:

> "No container runtime, no account. Each credential is its own Keychain item, per profile — and no tool can return one."

That is 25 words and both halves are already proven on the page (`Pricing.astro` "Nothing else to install", README "No tool returns a secret"). Keep the `max-w-[50ch]`; if it wraps to five lines, drop "per profile" from the sentence rather than the first clause.

**1b. Hero badge line.** `"${APP_VERSION} · signed, notarized, and sold direct"` → consider `"${APP_VERSION} · signed, notarized · no Docker, no account"`. Optional; the paragraph does the work. If the badge changes, it is a `SHIPPED`-branch string, so it stays gated.

**1c. Pricing card promotion.** Do _not_ remove "Nothing else to install, and no account" from `Pricing.astro` — the buyer reads it again at the moment of decision, and the copy there ("no container runtime, no Docker Desktop, no sign-up… ships with no entitlements file at all") is stronger than anything the hero can hold. Just stop relying on it being the _only_ place.

**1d. Meta description and JSON-LD.** `index.astro`'s `description` (and `config.ts` if it is sourced there) currently reads "…credentials in the Keychain, and every tool call recorded — instead of letting every editor spawn its own copy." Append ", with no container runtime." Search results are where a Docker user comparing options first sees Bastion.

**1e. Social card.** `SOCIAL_CARD.headline` is "One supervised process per profile, not one per editor". Leave it — it is a distinct, true claim and changing it means `pnpm icons` and a checkout image re-fetch via Stripe. Not worth it for Phase 1.

**Acceptance:** `pnpm lint`, `pnpm format:check`, a build, and a read of the hero on a phone width — the drawing beside it must still be the menu-bar popover that answers the text.

## Phase 2 — Make the Problem section name the alternatives it is arguing with (same PR or the next one, ~2 hours)

`Problem.astro` already links four public issues that are not Bastion's (6 processes on restart, 3.5 GB idle, 5.7 GiB across 60 subprocesses, Keychain request "not planned"). The brief found four more of the same shape, this time from the competitors' _own_ trackers, and they belong in the same list because they prove the same point from the other side:

- OrbStack users asking for Docker MCP Toolkit support, open since July 2025 — github.com/orbstack/orbstack/issues/2056
- Docker MCP Gateway panicking when Docker Desktop is unresponsive and taking the Claude session with it — docker/mcp-gateway#312
- mcp-proxy users asking for a tamper-evident audit layer — sparfenyuk/mcp-proxy#224
- mcp-proxy users asking for per-key, per-server permissions — sparfenyuk/mcp-proxy#201

Add them as a second group under a one-line lead such as _"And the gateways that exist have the same complaints filed against them."_ Keep the component's own rule (a comment in the file says it): these are links, not cards, because they are somebody else's numbers. Do not name Docker or Stacklok in prose on the homepage — the link text does it, and it keeps the page from reading as an attack.

**Acceptance:** each link opens to a still-open or clearly-dated issue; re-check the four in a quarter, because the whole section's credibility is that they are checkable.

## Phase 3 — Give the audit story a front door (one PR, ~half a day)

`Audit.astro` ("A record of requests, not a sandbox") is honest and short; the real design — hash chain, manifest, 0600, what it does _not_ prove — is on `/checked` and in the README. Docker is selling "prove what they did" behind a sales call and mcp-proxy users are filing issues asking for exactly this, so it deserves a nav entry and a paragraph that names the mechanism.

- Add a second paragraph to `Audit.astro`: each record hashes the one before, export ships a manifest with counts and digests, nothing is written to disk unless you turn it on, and a credential is never recorded. Then the sentence the competitors will not write: _"It catches tampering by something that does not know it is a chain. It is not proof against anyone who can write the file, and the checked page says so."_ Link to `/checked`.
- Add "Audit" to `NAV` between "Security" and "Servers", pointing at the existing `#audit` anchor (add the id if the section lacks one).

**Acceptance:** the paragraph says nothing the README does not already say; nothing new is claimed.

## Phase 4 — Comparison pages (one medium PR, 1–2 days; blocked on Phase 5)

Three static pages, in the site's existing "what Bastion checks, and what everyone else asserts" voice, each with a **gaps column for Bastion too** — the site already does this for itself in `Gaps.astro`, and it is the only thing that will make these pages read as honest rather than as marketing.

- `/compare/docker-mcp-toolkit` — the objection is "I already have Docker Desktop". Rows: container runtime required, where secrets live (Desktop-only store vs Keychain items), what happens when the runtime sleeps, catalog size (theirs is 300+; say so), isolation (they have it, Bastion does not — say so), audit (interceptor flag vs chained file), price and who you talk to.
- `/compare/toolhive-studio` — the objection is "it's free and built by the Kubernetes people". Rows: Docker/Podman/Colima prerequisite, Electron vs native, keyring-encrypted file vs per-item Keychain, network egress filtering (they have it, Bastion does not), OTel (theirs), write gate that removes tools from `tools/list` (Bastion's), Kubernetes path (theirs, and a reason to pick them if you have one).
- `/compare/mcp-router` — the objection is "it looks the same and it's free". This is the page that matters most. Rows: one process shared vs per-client, Keychain vs "stored locally", write gate, hash-chained audit vs request log, licence (MIT + sold build vs Sustainable Use), Windows (theirs).

Mechanics: a `src/data/compare.ts` with one object per competitor so the rows are data, not prose, and a single `[slug].astro` route rendering them; a "last checked" date on each page pulled from that file; every competitor claim links to their own docs or issue, never to a third-party roundup. Add the three pages to the sitemap and a small "Compared with…" link row in the Footer, not the nav — these are landing pages for search, not for someone already on the site.

Keep `Gaps.astro`'s discipline: the Bastion column must include "macOS only", "no isolation between clients of the same profile", "no sandbox", "login item not yet" (until Phase 5 lands), and "remote write gate is a filter".

**Acceptance:** someone who prefers Docker should be able to read the Docker page and agree it is fair. That is the whole test.

## Phase 5 — Close the one gap a feature table exposes (app work, not website)

The site's own `Gaps.astro` lists "Login item: nothing starts it at login yet". Both free desktop competitors start at login. Ship it before Phase 4 goes live, then delete that row from `GAPS`. Everything else in the gaps list is a design choice that the comparison pages can defend; this one is just missing.

## Phase 6 — Changelog and FAQ on the site (small, whenever)

- Surface `CHANGELOG.md` at `/changelog` (Astro can import the markdown from the repo root at build time, so it stays single-sourced). ToolHive's weekly updates page does quiet search work; Bastion's is already written and currently only on GitHub.
- A short FAQ, either as a section above Pricing or at `/faq`, answering the three questions the roundups keep marking as missing features: _Why macOS only?_ (Keychain, signed build, notarisation — a choice), _Why no containers?_ (the trade is stated in the README's cupertino table — reuse it), _Why not free?_ (the pricing paragraph already answers it: "charging rent for a background process that holds your own credentials is not a business this wants to be in" — quote it).

## What not to change

- The h1. It is the strongest line in the category and the brief's matrix shows nobody else has one that concrete.
- The Rules section and `make audit` transcript — nothing in the competitor set has an equivalent, leave it exactly as it is.
- The tone. Every competitor's 2026 copy has drifted toward "governance" and "control plane"; the site's refusal to use those words is a positioning asset, and the comparison pages must not pick them up either.
- `SOCIAL_CARD`, the screenshots pipeline, and anything that requires `pnpm icons` — no Phase 1–4 change needs them.

## Order and effort

Phase 1 and 2 together in one PR this week (copy only, no new components). Phase 3 next. Phase 5 in the app whenever it fits, and Phase 4 lands the week after it ships. Phase 6 is filler for a quiet afternoon. Total website effort is in the region of three to four days; the app work for the login item is separate.

Off-site, in parallel and free: get Bastion listed in the heyitworks Q1-2026 gateway survey, mcp.directory, zimaspace's "top 10 MCP gateways", and awesomeclaude.ai's aggregator list — all of which list MCP Router today and not Bastion. Phase 4's pages are what those lists will link to.
