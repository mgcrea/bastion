# Bastion: Competitive Brief, 9 October 2026

**Research date:** 9 October 2026 (desk research, web and GitHub API as of that day).
**Scope:** local MCP gateways, supervisors and managers a Mac developer would weigh against Bastion: Docker MCP Toolkit / Gateway, ToolHive (Stacklok), MetaMCP, 1MCP, the two mcp-proxies, MCP Router, and new entrants since the 20 September brief (KyttoMCP, Fentaris, mcp-bastion, SkillHub Local, Portus). Refresh of [competitive-brief-2026-09.md](competitive-brief-2026-09.md) (20 Sep), itself a refresh of [competitive-brief.md](competitive-brief.md) (7 Sep).
**Baseline used for Bastion:** v1.27.0, shipped 9 Oct 2026 (`app-v1.27.0`, GitHub release, Developer ID signed and notarized, Sparkle updates). macOS 26 or later. $14.99 / €14.99 once per major version, every 1.x release on every Mac you own, 30-minute whole-app trial, 30-day refund, no account. Source-available app, MIT website/scripts/docs. 37 servers in `servers.json`. `mgcrea/bastion` has 0 stars and 0 forks. Sources: README, CHANGELOG 1.22.0 to 1.27.0, `apps/website/src` (Hero, Gaps, Pricing, `config.ts`), `docs/marketing/*`, `docs/plans/website-update-plan-2026-09.md`. Bastion has no App Store listing and no market-intel ledger.
**Not available:** no SEO or traffic tool was connected (Ahrefs and Similarweb are unauthorized in this session), so this brief contains no traffic, ranking or keyword-volume numbers. The web-search budget for this run ran out partway through the new-entrant sweep; new entrants were found through Hacker News (Algolia) and GitHub, and a broader search for native Mac managers was not completed.

**Evidence grades:** (P) primary: vendor page, GitHub release or README, docs. (T) trade press. (S) secondary: aggregator, directory, third-party listing. _Unverified_ marks anything not confirmed. "They have" means "they say they have"; nothing here was tested hands-on.

---

## 1. Executive summary

The free native desktop rival the last two briefs called the biggest threat is gone: MCP Router ended development, support and security updates on 18 September 2026, two days before the previous brief was written, and tells its users that "new adoption is not recommended" (P). Its place as the free Mac look-alike is being taken by KyttoMCP, a native Swift app (MIT, free, unsigned beta, 8 stars) that the 20 Sep brief missed, while 1MCP shipped two things on 6 to 9 Oct that erode Bastion's protocol and Keychain sentences: opt-in macOS Keychain storage for OAuth credentials and cross-era delivery of `subscriptions/listen` and elicitation through one shared runtime (P). Docker and Stacklok kept moving up-market (Sandboxes, CNCF spec, "multi-model architecture") and shipped nothing for the individual Mac developer.

**Biggest opportunity:** MCP Router's 2.1k-star user base on macOS has to move somewhere, and its own migration guide warns that its export "may contain credentials" in environment variables (P). A dated, honest "Moving off MCP Router" page that ends with those credentials as Keychain items is the clearest acquisition hook Bastion has had, provided it says plainly which servers do not transfer (command-line servers, Windows).

**Biggest threat:** KyttoMCP. It is free, native, open source, also on Windows, runs on macOS 15 (Bastion needs macOS 26), and leads Bastion on diagnostics: MCP Doctor, a tool-description safety scanner, "Contract Guard" alerts when a server changes its tool contract, a context-cost estimator, and undo/backups for every config write (P). Bastion's defence is the enforcement layer Kytto only offers as an optional beta Gateway mode (one supervised process, write gate removing tools from `tools/list`, hash-chained audit with arguments, OAuth for remote servers) plus being a signed, notarized product rather than an unsigned beta.

### What changed since 20 September

**Bastion (1.22.0 to 1.27.0).** Five releases. Workspaces scope profiles to folders (1.23.0, 22 Sep, Claude Code only). Xcode 26.3's own `xcrun mcpbridge` server in the catalog, so one Xcode approval covers every client and the project-editing and code-running tools are hidden with writes off (1.24.0, 26 Sep). Agent Skills linked from chosen folders into `~/.agents/skills` and every Claude Code config folder, per workspace too (1.25.0, 4 Oct), plus a long reliability pass on wiring, supervision and the audit chain. Yahoo Finance in the catalog and behind the writes switch (1.25 to 1.27). Another app on the Mac can hand Bastion its MCP endpoint and bearer token via a `bastion://add-server` link, confirmed in a sheet, loopback only, token into the Keychain (1.27.0, 9 Oct). Website: a changelog with a page and social card per release, and a twenty-second tour under the hero (both 4 Oct). These close two content gaps from the earlier briefs (changelog as content, video).

**Bastion, not done.** "No container runtime, no Docker Desktop, no sign-up" is still only on the pricing card (`Pricing.astro`), not under the hero: recommended on 7 Sep and again on 20 Sep. No comparison pages. No measurement post. The punkpeye/awesome-mcp-servers PR is blocked by its Glama requirement and the mcp.directory and heyitworks mails were left as drafts on 21 Sep (`roundup-outreach-kit-2026-09.md`). The Show HN re-run planned for 6 Oct does not appear on HN: the only submission of bastion.mgcrea.io is the 14 Sep one (2 points) (P, HN Algolia).

**Competitors.**

- **MCP Router: end of support.** v0.6.4 (18 Sep) is the final release; cloud sign-in, sync and billing are shut, update checks and analytics are disabled, binaries stay downloadable without security fixes (P). The 20 Sep brief said "no release since v0.6.3 (24 Jun)"; that was wrong.
- **Docker.** mcp-gateway v0.44.1 (23 Sep, pre-release, 35 commits since v0.43.3): OAuth discovery hardening, a community OAuth token redirect replay fix, a Windows browser command-injection fix, exact-case tool allowlists, profile authorization, schema dialect translation to JSON Schema 2020-12 (P). Docker Desktop 4.92 to 4.94 (21 Sep to 5 Oct) carry no MCP line items (P). The blog went to Sandboxes: Cloud Sandboxes, a Sandbox Kit Spec to be donated to the CNCF as an "open spec for agent permissions" (24 Sep), "Trust Docker for the agents you don't" (1 Oct) (P).
- **ToolHive.** v0.51.0 to v0.51.4 (22 to 27 Sep): SPIFFE JWT-SVID client authentication, SSE responses routed to the originating session, encrypted-store migration fixes, workflow audit-log writer fixes (P). Studio v0.40.1 (21 Sep) is dependency and CVE patches only (P). Stacklok's homepage now reads "The open architecture for a multi-model world" and lists ToolHive, Mecatl and an LLM gateway; no mention of a desktop app or individual developers (P). One new post since Mecatl: "Why organizations need a kill switch for their MCP servers" (1 Oct) (P).
- **1MCP.** The cadence question the 20 Sep brief left open is settled: stable releases v0.35.0 (18 Aug), v0.36.0 (23 Aug), v0.37.0 (31 Aug), v0.38.0 (13 Sep), v0.38.1/2 (19 Sep), v0.38.3 and v0.39.0 (both 9 Oct) (P). v0.39.0 is substantive (see §2.4).
- **Unchanged.** MetaMCP: last release 2.4.22 (19 Dec 2025), last push 22 Jun 2026 (P); treat as dormant. sparfenyuk/mcp-proxy: last release v0.12.0 (14 May). TBXark/mcp-proxy: v1.1.0 (15 Sep) still latest.
- **New entrants.** KyttoMCP (repo created 2 Aug, Show HN 11 Sep, beta 1.0.7.1 on 9 Oct) is a native Mac and Windows manager; the 20 Sep brief's "no new native Mac manager appeared" was wrong. mcp-bastion (npm, Apache-2.0, v1.1.0 on 30 Sep) is a security proxy whose name collides with Bastion's. Fentaris added a Telegram approval package and `local`/`team` boilerplates (cli 1.7.0, 5 Oct). SkillHub Local (Show HN 6 Oct) manages skills and MCP configs across agents in a localhost dashboard. Portus (Show HN 2 Oct) and APIblaze (9 Oct) are server-side gateways and do not compete.

**What the previous brief got wrong, in one list:** MCP Router's status (EOL, not quiet); KyttoMCP missed; 1MCP cadence (weekly and stable, not beta-only); the roundups' MCP Router claim (already corrected by the outreach kit on 21 Sep); Stacklok's homepage line (changed). The 20 Sep brief also said ToolHive keeps a weekly "ToolHive Updates" page; on 9 Oct its newest visible entry is dated 18 May 2026 (_unverified_: older entries may sit on other pages).

---

## 2. Competitor profiles

Ordered by how likely a Mac developer is to weigh each against Bastion this month.

### 2.1 KyttoMCP (new, most important)

**Overview.** Solo developer (Jakub Hecht, "jakub studio"), Slovakia-hosted site kytto.jakubhecht.sk. Repo `heyitsjakub/KyttoMCP` created 2 Aug 2026, 8 stars, MIT. Native macOS app in Swift 6 with a SwiftUI/AppKit shell around a WKWebView, and a .NET 10 / WPF + WebView2 app for Windows, both in one repo (P). Releases roughly weekly: 1.0.6 (30 Aug), 1.0.6.1 (14 Sep), 1.0.6.2/3 (19 to 20 Sep), 1.0.7 (29 Sep), 1.0.7.1 (9 Oct), all marked pre-release (P). Show HN 11 Sep, 2 points (P); Product Hunt launch with 7 upvotes, rank #58 that day (S, date _unverified_). Third-party listings disagree on whether the source is open; the repo itself says MIT and holds both apps' source (P), so the "proprietary" listing (S) is out of date.

**Messaging.** Tagline: "See every MCP server in every AI client." README: "A local control panel for MCP servers across the AI clients you already use." Problem framing is configuration sprawl: five clients, five file formats, "what is actually enabled, where?" Themes: one matrix of servers by client; explain-before-write, undo and timestamped backups; MCP Doctor diagnostics; a Tool Safety Scanner and Contract Guard ("an MCP server can give instructions without ever being called"); "local by design", no telemetry. Tone: careful, honest about its own gaps (it links its open issues in the README), close to Bastion's own voice.

**Positioning and product.** Category: "control panel" / manager. It reads and writes each client's own config (Claude Desktop, Claude Code, Cursor, VS Code, Codex), so by default every client still spawns its own processes. An **optional Gateway mode** for "supported stdio servers" moves the definition and credentials into native storage and routes through a local gateway, with Live Activity showing sessions, calls, latency and failures as metadata only (P). Secrets: masked by default, rotate a value everywhere it appears, "an optional Keychain copy", tighten file permissions (P). Context: estimates each server's tool-schema footprint and warns near VS Code's 128-tool limit. Free, no account. macOS 15+, universal. **Unsigned**: Gatekeeper warns on first launch and "none is planned for now" (issue #4) (P).

**Content.** README with a 72-second unnarrated demo video, screenshots of findings, a changelog, a privacy page listing every network request. No blog found.

**Strengths.** Free and open source; native Mac UI; Windows too; runs on macOS 15; more diagnostic surface than Bastion (Doctor, safety scan, contract drift, context estimate); undo and backups; the same evidence-first tone as Bastion, so it will appeal to the same sceptical reader.

**Weaknesses.** Unsigned beta with a Gatekeeper bypass in the install steps; solo, 8 stars; Gateway mode is optional and limited to "supported stdio servers"; activity is metadata only (no arguments, so no record of what a call actually did); no write gate, no remote-server OAuth broker mentioned, no audit chain. Its advisories are "advice": "Nothing is switched off."

**Positioning statement (reverse-engineered).** For developers juggling MCP servers across several AI clients, KyttoMCP is the free local control panel that shows and edits what is enabled where, and explains why a server fails or changed, because it reads every client's own config and never needs a cloud.

### 2.2 Docker MCP Toolkit / MCP Gateway / Catalog

**Overview.** Docker Inc. Toolkit is "a management interface integrated into Docker Desktop" and needs Desktop 4.62 or later (P). OSS gateway `docker/mcp-gateway` 1,590 stars, latest v0.44.1 (23 Sep 2026, pre-release) (P). The sales-led **MCP Enterprise Gateway** is unchanged in shape: no price, "Talk to sales" (P). The product page no longer uses the "invite-only" phrase the 7 Sep brief quoted from the docs (_unverified_ whether the docs still do). Docker pricing per user per month: Personal $0, Pro $11 ($9 annual), Team $16 ($15), Business $24 (P).

**Messaging.** Enterprise gateway hero: "One secure gateway for all your tools." Subhead: "Connect your agents to the MCP servers you approve. Policy governs every call, credentials stay in your secret store, and every decision is recorded." Claims: unvetted servers denied by default; scoped tool access per group; policy evaluated "before anything runs"; credentials "never distributed through client config files"; "a structured event per evaluation … streamed to your SIEM" (P). Note how close those three promises now are to Bastion's hero sentence (one process, credentials in the Keychain, every call recorded). Company messaging since 24 Sep is about Sandboxes and agent permissions: "Manufacturing Trust for AI Agents" (WeAreDevelopers keynote), Cloud Sandboxes ("Start on your laptop, finish in the cloud"), and a Sandbox Kit Spec packaging "network rules, credentials, and volumes" as an OCI image, headed to the CNCF (P).

**Product.** Containerised servers (1 CPU / 2 GB each, no host filesystem by default, signed `mcp/` images with SBOMs), profiles a client connects to, browser OAuth with revoke, Dynamic MCP, secret-blocking on requests and responses (P). v0.44.1's work is security hardening and policy correctness, not desktop UX (P).

**Content.** No MCP post on the blog's first page since at least 2 Sep; all agent/Sandbox/governance (P).

**Strengths.** Distribution (Desktop is already installed), largest signed catalog, real isolation, enterprise trust, a steady security-fix cadence.

**Weaknesses.** Still needs Docker Desktop on a Mac; the individual developer is not who the copy addresses; enterprise audit and policy are behind sales. The open issues cited in the 7 Sep brief (Desktop sleeping, OrbStack, Claude Code timeouts) were not re-checked this round (_unverified_ whether fixed).

**Positioning statement.** For platform and security teams governing agents, Docker is the containerised gateway and catalog that approves, isolates and records every tool call, because Docker already is the runtime.

### 2.3 ToolHive / ToolHive Studio (Stacklok)

**Overview.** Stacklok (Craig McLuckie, Luke Hinds; Joe Beda CTO since April 2026). Core repo 2,261 stars, v0.51.4 (27 Sep); Studio (Electron) 171 stars, v0.40.1 (21 Sep) (P). Homepage hero: "The open architecture for a multi-model world" / "Stacklok is the alternative to vertically-integrated agent stacks from frontier labs and hyperscalers." Calls to action: "Let's talk", "Book my demo" (P).

**Messaging.** Studio README: run "any MCP server in a locked-down container with just a few clicks. No manual setup, no security headaches, no runtime hassles"; "Every server runs in an isolated container" (P). The company now sells three gateways (MCP, agent harness via Mecatl, LLM) to enterprises; the 1 Oct post argues for an MCP "kill switch" for organisations (P).

**Product.** Unchanged since 20 Sep for a Mac user: Studio still needs Docker, Podman or Colima (P). Core work in late September was identity (SPIFFE JWT-SVIDs), session routing and encrypted-store migration (P). Free, Apache-2.0; enterprise by demo.

**Strengths.** Credibility, breadth (desktop to Kubernetes), egress filtering, OTel, a free cross-platform desktop app with client auto-config.

**Weaknesses.** Container runtime prerequisite, Electron shell, and a desktop app that receives dependency bumps while the roadmap goes to the enterprise. The Mac individual is not the buyer.

**Positioning statement.** For engineering leaders adopting agents, ToolHive is the open, Kubernetes-native MCP platform that runs every server isolated and governed, because it is built by the team behind Kubernetes.

### 2.4 1MCP

**Overview.** `1mcp-app/agent`, Apache-2.0, 514 stars, one main maintainer (xizhibei), npm, binaries for macOS/Linux/Windows and Docker images (P). Shipping weekly; v0.39.0 on 9 Oct (P).

**Messaging.** "1MCP is the unified MCP runtime." Two sprawls: "Configuration sprawl" and "Agent sprawl"; `1mcp serve` gives "one aggregated runtime in front of many MCP servers", CLI mode lets agents "discover tools progressively" (P). Tone: engineering, ADR-driven.

**What v0.39.0 changed (P, PRs #536, #555, #589, #600).**

- **Native credential storage, opt-in.** `--credential-store` puts upstream and inbound OAuth records into the macOS Keychain (or Windows Credential Manager / Secret Service), "fails closed", migrates plaintext out. File storage stays the default; it needs Docker credential helpers on PATH (not Docker Engine); it covers OAuth records, not the env-var API keys most servers take. The PR itself says it "does not claim protection from arbitrary same-user code".
- **Subscriptions and list_changed across eras.** Modern `subscriptions/listen` delivered with per-listener isolation and authorization re-checks, legacy watches bridged.
- **Elicitation across eras.** A legacy server asking for caller input becomes an `input_required` handle to the modern caller, and the answer resumes the original call.
- Also: visible tool search, scheduled runtime recovery, "stabilize macOS restart".

**Strengths.** The closest architecture to Bastion (one runtime shared by all clients), very fast cadence, cross-platform, free, now ahead of Bastion on server-initiated features.

**Weaknesses.** CLI and Admin web console, no native app; Keychain is opt-in and OAuth-only; no write gate equivalent beyond presets/filters; logs, not a chained audit.

**Positioning statement.** For developers running several agent CLIs, 1MCP is the single runtime that consolidates every client's MCP wiring and keeps agent context thin.

### 2.5 MCP Router (end of support)

2,142 stars, macOS and Windows Electron app, "Sustainable Use License". Development, support and security updates ended 18 Sep 2026; v0.6.4 shows an end-of-support notice at startup, keeps local features, removes sign-in, billing, cloud sync and feedback, disables update checks and analytics (P). Migration guide: export per local workspace from the Servers screen; the export is "a server configuration export, not a complete application backup" (no workflows, logs, skills, app tokens); "Keep exports private because environment variables can contain credentials"; "OS-encrypted secrets may only be readable on the original machine/account" (P). No successor product is named. It is no longer a competitor; it is a source of users.

### 2.6 MetaMCP, mcp-proxy (both), and the rest

- **MetaMCP** (2,699 stars): no release since 2.4.22 (19 Dec 2025), no push since 22 Jun 2026 (P). Dormant; drop from monthly monitoring.
- **sparfenyuk/mcp-proxy** (2,776 stars): transport bridge, v0.12.0 (14 May) still latest (P).
- **TBXark/mcp-proxy** (734 stars): v1.1.0 (15 Sep) still latest (P).
- **Fentaris** (8 stars, MIT, TypeScript): CLI proxy with policies, identity, rate limiting; now a Telegram approval package and `local`/`team` boilerplates with "fail-closed team governance" (cli 1.7.0, 5 Oct) (P). Still no GUI.
- **mcp-bastion** (`Gowthaman90/mcp-bastion`, 7 stars, Apache-2.0, npm `mcp-bastion`): "A reliability & security proxy for the Model Context Protocol (MCP)", tool-definition pinning, tool-poisoning and exfiltration detection, secret redaction, "compliance-mapped audit trail"; v1.0.0 (8 Sep) to v1.1.0 (30 Sep); listed in punkpeye/awesome-mcp-servers and the MCP Registry (P). Not a real competitor on product, but a name collision in Bastion's exact category (see Threats).
- **SkillHub Local** (19 stars, MIT, Node, localhost:3742): "One local dashboard for all your AI coding agents": skills, memories, instructions, plugins and MCP servers across Claude Code, Codex, Cursor and others, copy or symlink a skill between agents (P). Overlaps Bastion 1.25's Skills feature, not its gateway.
- **IBM ContextForge** (4,592 stars, v1.0.11 on 28 Sep) and **MCPJungle** (1,293 stars, 0.4.6 on 2 Aug): server-side, unchanged in relevance (P).

---

## 3. Messaging comparison matrix

|                          | **Bastion**                                                                                                                                   | KyttoMCP                                                                   | Docker MCP Toolkit / Gateway                           | ToolHive Studio                                                          | 1MCP                                                        |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------ | ----------------------------------------------------------- |
| Tagline                  | "One MCP server, running once, for every client."                                                                                             | "See every MCP server in every AI client."                                 | "One secure gateway for all your tools"                | "Run any MCP server … in a locked-down container with just a few clicks" | "The unified MCP runtime"                                   |
| Target buyer             | Individual Mac developer running several MCP clients                                                                                          | Individual developer, Mac or Windows                                       | Platform and security teams                            | Engineering leaders; developers via Studio                               | Developers running several agent CLIs                       |
| Key differentiator       | One supervised process per profile; Keychain items; write gate that removes tools from `tools/list`; hash-chained audit; no container runtime | Config matrix, MCP Doctor, tool-safety scan, Contract Guard, undo          | Signed container catalog, isolation, enterprise policy | Kubernetes pedigree, isolation, identity                                 | One shared runtime, cross-era protocol bridging             |
| Secrets                  | Each credential its own Keychain item, per profile, by default                                                                                | Masked in config; "optional Keychain copy"; native storage in Gateway mode | Desktop secret store; enterprise "your secret store"   | Keyring-protected encrypted file, 1Password, Vault                       | Files by default; opt-in Keychain for OAuth records (v0.39) |
| Audit / activity         | Every call; opt-in durable hash-chained JSONL with arguments; counts on disk by default                                                       | Metadata only, no arguments                                                | `--log-calls`; SIEM streaming enterprise-only          | Audit logs + OTel                                                        | Logs, telemetry events                                      |
| Container runtime on Mac | No                                                                                                                                            | No                                                                         | Yes (Docker Desktop 4.62+)                             | Yes (Docker/Podman/Colima)                                               | No                                                          |
| Signed build             | Developer ID, notarized                                                                                                                       | Unsigned, none planned                                                     | Docker Desktop signed                                  | Signed (_unverified_)                                                    | npm / unsigned binaries (_unverified_)                      |
| Price                    | $14.99 / €14.99 once per major; 30-min trial                                                                                                  | Free (MIT)                                                                 | Free with Desktop; enterprise by sales                 | Free (Apache-2.0); enterprise by demo                                    | Free (Apache-2.0)                                           |
| Platforms                | macOS 26+                                                                                                                                     | macOS 15+, Windows                                                         | Mac, Windows, Linux                                    | Mac, Windows, Linux                                                      | Mac, Windows, Linux                                         |
| Tone                     | Exact, self-auditing                                                                                                                          | Careful, self-auditing                                                     | Confident, CISO-facing                                 | Authoritative platform                                                   | Engineering, ADR-driven                                     |
| Core value prop          | One process, one grant of trust, read the source                                                                                              | Know what is enabled where, and why it broke                               | Approve, isolate, record                               | Govern agents on infra you run                                           | Fewer configs, thinner context                              |

---

## 4. Value proposition and narrative comparison

|              | Promise                                                                            | Evidence offered                                                     | Mechanism                                               | Unique?                                                         | Villain / hero / transformation                                                              |
| ------------ | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **Bastion**  | Each server once, for every client; secrets out of files; every call on the record | `make smoke`, `make audit`, `/checked`, other projects' bug trackers | Loopback HTTP gateway supervising one child per profile | Yes at desktop scale: no one else enforces in the path natively | A refresh token in `.mcp.json` and duplicate processes / the developer / trust you can audit |
| **KyttoMCP** | See and fix what is enabled where                                                  | Screenshots of findings, open issues linked                          | Reads and rewrites each client's config                 | The diagnostics, not the architecture                           | Config sprawl and silent tool changes / the developer / clarity                              |
| **Docker**   | Approve, isolate, record                                                           | Enterprise customers, signed images                                  | Containers and a policy gateway                         | Isolation and catalog                                           | Ungoverned agents / the platform team / "trust for agents"                                   |
| **ToolHive** | Govern agents on your own infrastructure                                           | Kubernetes pedigree                                                  | Containers, operator, identity                          | Pedigree                                                        | Shadow MCP / the engineering leader / control                                                |
| **1MCP**     | One runtime, thinner context                                                       | Conformance suites in PRs                                            | Shared Node runtime, presets                            | Cross-era bridging                                              | Sprawl / the agent user / tidiness                                                           |

Bastion still has the sharpest and most checkable story. The change since September is that one free native rival (Kytto) now tells a story of nearly the same honesty, from the config-file side rather than the gateway side.

---

## 5. Positioning map

Axes: **where enforcement happens** (edits client configs, each client still spawns servers ↔ sits in the call path as one shared runtime) and **what the Mac user has to run** (container runtime or server stack ↔ native app, nothing else).

```
                        Sits in the call path (shared runtime, enforces)
                                          ^
          Docker Toolkit/Gateway          |   BASTION
          ToolHive Studio                 |   (1MCP: shared runtime, but CLI/web, no app)
          MetaMCP (dormant)               |   (Kytto in optional Gateway mode, beta)
                                          |
  Container / server stack <--------------+--------------> Native app, nothing else
                                          |
          (no one)                        |   KyttoMCP (default mode)
                                          |   SkillHub Local (localhost dashboard)
                                          |   MCP Router (EOL 18 Sep)
                                          v
                        Edits client configs (each client still spawns)
```

The upper-right quadrant, a native app that is itself the enforcement point, is still Bastion's alone among supported products. It is underserved in a second sense: the only other native contender is unsigned and beta, and the only other shared runtime is a CLI. The risk is from below and from the left: Kytto moving up (its Gateway mode) and 1MCP moving right (it has an Admin console and macOS restart handling already).

---

## 6. Content gap analysis

**Topics**

| Topic                                    | Bastion                                                           | KyttoMCP                            | Docker                                | ToolHive                  | 1MCP             | Gap                                                                  |
| ---------------------------------------- | ----------------------------------------------------------------- | ----------------------------------- | ------------------------------------- | ------------------------- | ---------------- | -------------------------------------------------------------------- |
| Moving off MCP Router                    | none                                                              | none found                          | none                                  | none                      | none             | **Open, dated, time-limited**                                        |
| Secrets out of client config files       | Hero diff, Problem section                                        | Secrets section                     | Enterprise page now says it           | 2025 post                 | Keychain PR text | Crowding; Bastion's per-item, default-on Keychain is the distinction |
| Tool poisoning / tool contract changes   | nothing                                                           | Tool Safety Scanner, Contract Guard | Exact-case allowlists (release notes) | Kill-switch post          | none             | Open for Bastion, but no feature to back it (see §9)                 |
| Per-client process duplication, measured | Evidence links only                                               | none                                | none                                  | none                      | "sprawl"         | Still open; the measurement post never shipped                       |
| Context cost of tool listings            | Measured on the site (26.2k to 0.4k tokens, index off by default) | Estimator, 128-tool warning         | Dynamic MCP                           | "85%" optimizer claim     | Tool search      | Parity; Bastion's number is measured, say so                         |
| Xcode's MCP server for every agent       | Built (1.24) and in the changelog only                            | none                                | none                                  | none                      | none             | **Open, Mac-only, Bastion-only**                                     |
| Agent Skills across clients              | Built (1.25), changelog only                                      | none                                | none                                  | "MCP Skills" Cedar policy | none             | SkillHub Local is the only other voice                               |
| Comparison pages                         | none                                                              | none                                | none                                  | none                      | none             | Open, high intent                                                    |
| Audit-log design                         | `/checked`, README                                                | metadata-only stance                | SIEM                                  | OTel                      | none             | Bastion leads; under-promoted                                        |

**Formats**

| Format             | Bastion                                                         | KyttoMCP                              | Docker           | ToolHive   | 1MCP                    |
| ------------------ | --------------------------------------------------------------- | ------------------------------------- | ---------------- | ---------- | ----------------------- |
| Landing page       | Yes                                                             | Yes                                   | Yes              | Yes        | Docs site               |
| Changelog on site  | Yes (since 4 Oct, page per release)                             | In repo                               | Release notes    | Releases   | Releases                |
| Demo video         | 20-second tour (4 Oct)                                          | 72-second demo                        | Explainer series | YouTube    | none                    |
| Blog               | Essays on mg-crea.com/blog, none on the product site            | none                                  | Heavy            | Heavy      | ADRs                    |
| Comparison pages   | none                                                            | none                                  | none             | none       | none                    |
| Migration guides   | none                                                            | none                                  | none             | none       | Consolidate-config docs |
| Directory listings | Not in punkpeye; mcp.directory form sent 21 Sep, status unknown | Product Hunt, EveryDev, ToolRadar (S) | Everywhere       | Everywhere | punkpeye (P)            |

---

## 7. Opportunities

**The MCP Router diaspora (dated: 18 Sep).** 2,142 stars' worth of desktop users on macOS and Windows have been told not to stay. Their export carries credentials as plaintext environment variables and their app no longer gets security fixes. Bastion's strongest sentence ("credentials in the Keychain, never in a config file") meets them exactly at the moment they hold a JSON file full of secrets. Honest limits to publish alongside: Bastion takes catalog servers, npm packages and https URLs only, never a command line (`docs/servers.md`: "There is no field for a path and no field for an argv"), so `uvx`, Python-script and `docker run` servers do not move; there is no import from a file in the release build, by design (README, Debug-only seeding); and it is macOS 26+ only. Kytto will chase the same users, for free.

**Signed beats unsigned for something that holds every token.** Kytto's install steps tell the user to bypass Gatekeeper, and its developer says no signing is planned (issue #4). Bastion is Developer ID signed, notarized and Sparkle-updated. For a tool whose job is to hold every credential on the Mac, that is a trust argument, and it is one sentence.

**Docker now says Bastion's three promises, behind a sales call.** The Enterprise Gateway subhead is "Policy governs every call, credentials stay in your secret store, and every decision is recorded." That is a free anchor for a comparison page: the same promises, for one Mac, for $14.99, without Docker Desktop.

**Xcode's own MCP server, approved once.** Xcode 26.3's `mcpbridge` asks for approval per agent; behind Bastion that agent is Bastion, so one approval covers every client and the code-running tools are hidden with writes off (1.24.0). Nobody else in this set can say it, and it targets exactly the Mac developer.

**The tool-contract topic is open at desktop scale.** Kytto (Contract Guard, 29 Sep), mcp-bastion (definition pinning) and Docker (exact-case allowlists, 23 Sep) all moved on it within a month. Bastion sits in the call path and already holds each server's listing, which makes pinning a natural fit. This is a product opportunity, not a marketing one: nothing is built (see §9, action 6).

---

## 8. Threats

**KyttoMCP.** Free, open source, native, cross-platform, macOS 15+, weekly releases and a feature list that a reader will find longer than Bastion's in the areas Kytto chose (diagnostics, undo, safety scan). If its Gateway mode matures and it signs its builds, the "native app that enforces" quadrant is shared. Today: 8 stars, unsigned, beta, metadata-only activity.

**1MCP is closing the protocol gaps Bastion publishes as structural.** `Gaps.astro` says `list_changed` and `subscriptions/listen` "still cannot" be delivered because "a shared instance has no one client to send them to", and that sampling and elicitation are refused because "a shared instance has no single client to ask". 1MCP v0.39.0 (9 Oct) claims both on one shared runtime (P). The gaps list is Bastion's credibility device; a line that a competitor's release notes contradict turns it against Bastion. Bastion's position can stay "not yet", but not "cannot".

**The Keychain sentence is no longer unique in shape.** 1MCP (opt-in, OAuth only), Kytto (optional copy; native storage in Gateway mode) and MCP Router ("OS-encrypted secrets") all now say something about the OS credential store. The defensible claim is narrower and stronger: every credential, API keys included, is its own Keychain item per profile, by default, and no tool can return one.

**Name collision.** `mcp-bastion` is an npm package, an MCP Registry entry and a punkpeye listing in Bastion's own category ("security proxy … audit trails"), with an Apache-2.0 licence and a Zenodo DOI. `apatureai/bastion` is a second MCP project of the same name. Anyone searching "bastion mcp" or browsing the awesome list meets them first, and Bastion is not on that list (_no ranking data available to size this_).

**Vocabulary capture by Docker.** Docker's enterprise copy now owns "credentials never distributed through client config files" and "every decision is recorded" for buyers who read Docker first. Keep Bastion's version concrete (Keychain item, `tools/list`, hash chain, 0600) rather than generic.

**OS floor.** macOS 26 or later excludes developers on macOS 15, whom Kytto serves. _Unverified_ how large that share is among the target buyers; no data source connected.

**Campaign drift.** Three briefs in a row have recommended the hero line and comparison pages; neither shipped, while the product shipped fifteen releases. The roundup route is blocked (Glama requirement, 0 stars) and the Show HN re-run did not happen.

---

## 9. Recommended actions

Each action names what is built today. Nothing below asks to market an unbuilt feature.

**Quick wins (this week)**

1. **Publish "Moving off MCP Router" (page on bastion.mgcrea.io, mirrored as an X thread).** Hook: the 18 Sep end-of-support notice and its own warning that exports "may contain credentials". Content: what moves (catalog servers, npm packages, https remote servers with OAuth), how credentials end up as Keychain items through the profile editor, and a line telling the reader to delete the export afterwards. Say plainly what does not move: command-line servers, Windows, workflows. Built: catalog, custom npm/URL servers, OAuth 2.1, Keychain profiles, automatic client rewiring. Not built: import from a file (deliberately Debug-only), so the page must describe re-entering servers, not importing them.
2. **Correct the `list_changed` and server-initiated rows in `Gaps.astro`.** Replace "cannot … a shared instance has no one client" with "not yet", and keep the honest reason it is harder for Bastion. Evidence: 1MCP v0.39.0, PRs #536 and #555 (P). A gaps list that a rival's changelog contradicts costs more than one that is short.
3. **Put "No container runtime. No Docker Desktop. No account. Signed and notarized." directly under the hero.** Third time recommended. The first half answers Docker and ToolHive (both still need a runtime, P); the second answers Kytto (unsigned, P). All four facts are built and already on the site except "signed and notarized", which the release pipeline does today.
4. **Disambiguate the name everywhere it is listed.** Use "Bastion for Mac" or "Bastion, the MCP supervisor for macOS" in the page `<title>`, `llms.txt`, the GitHub repo description and any directory form, so a reader who meets `mcp-bastion` first can tell them apart. Evidence: punkpeye and MCP Registry listings of `mcp-bastion` (P).

**Strategic moves (this quarter)**

5. **Write the comparison pages, re-targeted.** vs Docker MCP Toolkit (anchor on Docker's own Enterprise Gateway subhead), vs ToolHive Studio, and **vs KyttoMCP** in place of MCP Router. Use the site's existing gaps voice and concede Kytto's lead where it is real (diagnostics, undo, safety scan, Windows, macOS 15, free). Built: everything in Bastion's column of §3.
6. **Decide on tool-contract pinning as a product question, not a marketing one.** Evidence that it is now table stakes in security-flavoured MCP tools: Kytto Contract Guard (1.0.7, 29 Sep), mcp-bastion definition pinning (v1.0.0, 8 Sep), Docker exact-case allowlists (v0.44.1, 23 Sep). Bastion is the only one of these in the path natively, so it could refuse or flag a changed tool list per profile rather than advise. Not built; do not mention it on the site until it is.
7. **Turn two shipped Mac-only features into posts on mg-crea.com/blog, the surface that already produces readers** (`campaign-plan-2026-09.md` §0): "One Xcode approval for every agent" (1.24.0) and "One set of Agent Skills in every client" (1.25.0). Both are built, both are unclaimed by Docker, ToolHive, 1MCP and Kytto, and both fit the 20-second tour format already on the site.

Carried over and still valid: the measured "what three MCP clients cost your Mac" post (7 Sep brief, action 6) and the explicit public "macOS only, by design" FAQ line (20 Sep brief, action 9). The roundup outreach needs a decision rather than a reminder: either meet punkpeye's Glama requirement or drop that route.

---

## 10. Sources (all accessed 9 October 2026)

**Bastion (repo):** `README.md`, `CHANGELOG.md` (1.22.0 to 1.27.0), `servers.json`, `docs/servers.md`, `apps/website/src/config.ts`, `apps/website/src/components/Hero.astro`, `Gaps.astro`, `Pricing.astro`, `docs/marketing/competitive-brief.md`, `competitive-brief-2026-09.md`, `campaign-plan-2026-09.md`, `roundup-outreach-kit-2026-09.md`, `docs/plans/website-update-plan-2026-09.md`; `gh repo view mgcrea/bastion`; `gh release list -R mgcrea/bastion`.

**KyttoMCP:** https://kytto.jakubhecht.sk/ · https://github.com/heyitsjakub/KyttoMCP · https://github.com/heyitsjakub/KyttoMCP/releases · https://github.com/heyitsjakub/KyttoMCP/issues/4 · https://news.ycombinator.com/ (Show HN, 11 Sep, via HN Algolia) · https://www.everydev.ai/tools/kyttomcp/llms.txt (S) · https://hunted.space/product/kyttomcp (S) · https://www.producthunt.com/products/kyttomcp (S) · https://toolradar.com/tools/kyttomcp (S)

**MCP Router:** https://github.com/mcp-router/mcp-router · https://github.com/mcp-router/mcp-router/releases/tag/v0.6.4 · https://github.com/mcp-router/mcp-router/blob/main/docs/END_OF_SUPPORT.md

**Docker:** https://github.com/docker/mcp-gateway/releases (v0.44.1) · https://github.com/docker/mcp-gateway/compare/v0.43.3...v0.44.1 · https://docs.docker.com/desktop/release-notes/ · https://docs.docker.com/ai/mcp-catalog-and-toolkit/toolkit/ · https://www.docker.com/products/mcp-enterprise-gateway/ · https://www.docker.com/blog/ · https://www.docker.com/blog/docker-cncf-open-spec-agent-permissions/

**ToolHive / Stacklok:** https://stacklok.com/ · https://stacklok.com/blog · https://github.com/stacklok/toolhive/releases (v0.51.0 to v0.51.4) · https://github.com/stacklok/toolhive-studio (README, v0.40.1) · https://docs.stacklok.com/toolhive/updates

**1MCP:** https://github.com/1mcp-app/agent (README) · https://github.com/1mcp-app/agent/releases/tag/v0.39.0 · https://github.com/1mcp-app/agent/pull/536 · /pull/555 · /pull/589 · /pull/600

**Others:** https://github.com/metatool-ai/metamcp/releases · https://github.com/sparfenyuk/mcp-proxy/releases · https://github.com/TBXark/mcp-proxy/releases · https://github.com/Fentaris/fentaris (cli 1.7.0) · https://github.com/Gowthaman90/mcp-bastion (v1.1.0) · https://github.com/apatureai/bastion · https://github.com/mjalalimanesh/skillhub-local · https://portus-gateway.dev/ · https://www.apiblaze.com · https://github.com/IBM/mcp-context-forge/releases · https://github.com/mcpjungle/MCPJungle/releases · https://github.com/punkpeye/awesome-mcp-servers (README) · https://hn.algolia.com/api (Show HN queries: "MCP gateway", "MCP proxy", "MCP manager", "MCP servers mac", "MCP menu bar", "MCP keychain", "MCP hub", since 1 Jul 2026; and url:bastion.mgcrea.io)

## Monitoring (re-check monthly, next on or around 9 November)

- **KyttoMCP:** release notes for Gateway mode scope, signing (issue #4), stars, any price. This is now the first thing to check.
- **1MCP:** whether native credential storage becomes the default and whether a GUI appears; any further protocol gaps it closes that `Gaps.astro` lists.
- **ToolHive Studio:** any move off the container prerequisite (still the change that would hurt most).
- **Docker:** Desktop release notes for an MCP Toolkit line, gateway releases, and whether the Toolkit ever runs without Desktop.
- **MCP Router:** whether a fork or successor appears to take its users.
- **mcp-bastion:** growth, and whether it ships a GUI (brand confusion would get worse).
- **Bastion itself:** stars, directory listings, Show HN, and whether actions 1 to 4 shipped.
- Quarterly only: MetaMCP (dormant), both mcp-proxies, Fentaris, SkillHub Local, ContextForge, MCPJungle.
- Connect a traffic/SEO source (Ahrefs or Similarweb) before the next refresh if keyword data for "bastion mcp" or "MCP Router alternative" is wanted; this brief has none.
