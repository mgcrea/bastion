# Bastion: Competitive Brief, 21 October 2026

**Research date:** 21 October 2026 (desk research, web, GitHub API and HN Algolia as of that day).
**Scope:** what changed between 9 and 21 October among the local MCP gateways, supervisors and managers a Mac developer would weigh against Bastion: KyttoMCP, Docker MCP Toolkit / Gateway, ToolHive (Stacklok), 1MCP, MCP Router and its forks, the minor players, and new entrants since 9 October (mcpock, Delta MCP, Ask Key, Cheatcode, rabin-a/mcp-router). Short-cycle refresh of [competitive-brief-2026-10-09.md](competitive-brief-2026-10-09.md); profiles that did not change are summarised in one line and point back there.
**Baseline used for Bastion:** v1.30.0, shipped 16 Oct 2026 (`app-v1.30.0`, Developer ID signed and notarized, Sparkle updates). macOS 26 or later. $14.99 / €14.99 once per major version, every 1.x release on every Mac you own, 30-minute trial, 30-day refund, no account. App source-available (`apps/apple/LICENSE`); website, scripts and docs MIT (root `LICENSE`). `mgcrea/bastion`: 0 stars, 0 forks. Sources: README, CHANGELOG 1.28.0 to 1.30.0, `apps/website/src` (Hero, Gaps), `git log` of `apps/website` since 9 Oct.
**Not available:** no SEO or traffic tool connected, so no ranking, traffic or keyword-volume numbers. GitHub search rate limits cut some new-entrant queries short; Swift-language and topic searches covered the same ground. Platform pages outside GitHub were read through a summarising fetch, not quoted in full.

**Evidence grades:** (P) primary: vendor page, GitHub release, PR or README, docs. (S) secondary: directory, aggregator, third-party listing. _Unverified_ marks anything not confirmed. "They have" means "they say they have"; nothing here was tested hands-on.

---

## 1. Executive summary

A quiet twelve days for the large players and a busy one at the edges. Docker shipped nothing for MCP (a Go bump), ToolHive Studio shipped dependency patches, and 1MCP shipped bug fixes. The movement came from free native rivals: **KyttoMCP 1.0.8 (15 Oct) added native OAuth sign-in for remote servers** with credentials "in native secure storage", plus discovery of plugin-added servers and a portable setup export, and its developer **closed the signing question for good** ("The releases stay unsigned", issue #4). Two new Mac-native entrants appeared: **mcpock**, a signed and notarized Swift menu bar app for macOS 26 that health-checks every agent's MCP servers, and **Delta MCP**, an unshipped "Coming soon" app with 82 GitHub stars that promises per-tool approval and undo between AI apps and their servers.

**Biggest opportunity:** trust is now the cleanest wedge, and the evidence for it got sharper this window. Kytto is ad-hoc signed with a non-notarized DMG by decision, ToolHive's new Homebrew cask is "Developer ID signed but not notarized" and strips `com.apple.quarantine` on install (PR #6859), and the only other signed native Mac app in the set (mcpock) holds no credentials. Bastion is the only product here that is signed, notarized and holds every token. That sentence is built and true today; it still is not under the hero.

**Biggest threat:** attention, not features. Delta MCP collected 82 stars with no code and a consumer-grade promise ("Let your AI act on your tools. Without crossing your fingers."); Cheatcode collected 81 in ten days; Bastion has 0 after thirty releases. Meanwhile none of the four quick wins from the 9 October brief shipped. The product keeps widening its lead in the call path while the market hears about other apps first.

### What changed since 9 October

**Bastion (1.28.0 to 1.30.0).** Three releases. **Only Bastion** (1.28.0, 13 Oct): a per-profile switch that writes `disableClaudeAiConnectors` and an `allowedMcpServers` list into Claude Code's `settings.json`, filtering out servers added by plugins, claude.ai connectors and a repository's `.mcp.json`; plus a reliability pass on remote-server token refresh, client wiring and a writes-off race. **Rename a profile** with credentials, sign-ins, workspaces and history following, and Shopify writes behind the writes switch, Shopify Dev in the catalog (1.29.0, 15 Oct). A **right-click menu** on sidebar servers (1.30.0, 16 Oct). Website: the tour video's pacing and zoom (13 Oct).

**Bastion, not done (P, repo).** None of the 9 October quick wins shipped: no "Moving off MCP Router" page; `Gaps.astro` still says `list_changed` and `subscriptions/listen` "still cannot" be delivered and sampling and elicitation are refused because "a shared instance has no single client to ask"; the hero badge still reads "signed, notarized, and sold direct" and the "No container runtime" line is still only on the pricing card; no name disambiguation beyond the repo description's "for macOS". No new HN submission; the only one remains 14 Sep (2 points) (P, HN Algolia). No third-party mention found on Reddit, blogs or X (S).

**Competitors.**

- **KyttoMCP 1.0.8 (15 Oct, pre-release).** Remote Doctor for Streamable HTTP endpoints, native OAuth with PKCE, read-only discovery of servers from Claude Code and Codex plugins, portable export/import with secrets as required inputs, Contract Guard diffs, workspace filters. Gateway scope unchanged: "Legacy SSE transport and remote gateway routing remain unsupported." Hero changed to "Your MCP setup. Finally in sync." (date _unverified_). Signing refused for good (issue #4, closed 1 Oct). 9 stars. (P)
- **Docker.** mcp-gateway v0.44.2 (21 Oct) is a Go 1.26.10 bump only. Desktop 4.95.0 to 4.96.1 (12 to 21 Oct) carry no MCP line items. Toolkit still needs Desktop 4.62+. Enterprise gateway copy unchanged. Six blog posts, none about MCP; all Sandboxes and agent security. Pricing unchanged. (P)
- **ToolHive.** Core v0.52.0 to v0.55.2 (12 to 19 Oct): a Kubernetes operator file-read fix (v0.53.0), Pi as a client (v0.54.0), `thv client connector` for Claude Desktop (v0.55.0, see §2.3), a Homebrew cask that strips quarantine (v0.55.1), a Podman egress advisory (v0.55.2). Studio v0.40.2 (14 Oct) maintenance only, still needs Docker, Podman, Colima or Rancher Desktop. Homepage hero unchanged; nav reads MCP Registry, MCP Gateway, MCP Runtime, AI Gateway. Five thought-leadership posts. (P)
- **1MCP.** v0.39.1 to v0.39.3 (12 to 15 Oct), fixes only. Unreleased work on `main` points at multi-project agent sessions: per-call project binding, session ownership and project defaults, shareable JSON recipes, a README section on worktrees (13 to 21 Oct). Credential store unchanged (still opt-in, OAuth records). 522 stars. (P)
- **MCP Router.** Repo now **archived** (date _unverified_), 2,136 stars (down 6). No successor: the most active fork (chalan630, 9 commits, 10 to 11 Oct) removes the retirement notice and fixes wake reconnection, with 0 stars and no release. (P)
- **New entrants.** mcpock (created 9 Oct), Delta MCP (7 Oct, no code), Ask Key (1 Oct), Cheatcode (11 Oct), rabin-a/mcp-router (16 Oct). See §2.6 and §2.7.
- **Minor players.** Fentaris cli 2.0.0 (10 Oct, breaking: `tools` becomes `mcp`, a project vault, named upstream accounts); sparfenyuk/mcp-proxy v0.13.0 (10 Oct); IBM ContextForge v1.1.0 (20 Oct, "New Redesigned Web UI"); mcp-bastion npm 1.3.0 (20 Oct, shadow-mode audit). MetaMCP, TBXark/mcp-proxy, MCPJungle, apatureai/bastion unchanged. (P)
- **Platforms.** Claude Code 2.1.296 to 2.1.305: up-front tool description and instruction limit raised from 2,048 to 4,096 characters (9 Oct); `mcp__a` allow rules no longer match `a__b` (14 Oct); **`allowedMcpServers` filtering of `managed-mcp.json` changed (2.1.305, 20 Oct)**. Codex 0.163.0 (15 Oct): a verified sandbox launcher for local MCP servers and opt-in credential masking for proxied sandboxed sessions. Xcode 27.2 RC (19 Oct) adds a `GetCodeCoverage` MCP tool. VS Code 1.143: a sandbox credential proxy (MCP scope _unverified_). Claude Desktop and Cursor: nothing local-MCP. (P)

**What the 9 October brief got wrong or left open:** Kytto issue #4 was already closed on 1 Oct, so "none is planned for now" understated it: signing is refused, not deferred. The 9 Oct brief said the punkpeye route was blocked by Glama; Glama now lists `mgcrea/bastion` (S, see §7).

---

## 2. Competitor profiles

Ordered by how likely a Mac developer is to weigh each against Bastion this month. Full profiles of Docker, ToolHive and 1MCP are in the 9 October brief §2.2 to §2.4; only the changes are here.

### 2.1 KyttoMCP (still the closest rival)

**Overview.** Solo developer, `heyitsjakub/KyttoMCP`, MIT, 9 stars, 3 forks. Native Swift Mac app and .NET Windows app. 1.0.8 on 15 Oct, still pre-release; the release cadence slowed from weekly to one release in twelve days (P).

**Messaging.** Hero is now **"Your MCP setup. Finally in sync."** with "Every server. Every AI client. One clear view." The site also says "no gateway you are required to route through", which positions the gateway as optional on purpose (P). README tagline: "A local control panel for MCP servers across the AI clients you already use." (P). A comparison page (`compare.html`, "Updated 29 September 2026") compares Kytto with editing config files by hand, and names no competitor (P).

**What 1.0.8 changed (P, release notes).**

- **Native OAuth sign-in** (PKCE). "Credentials stay in native secure storage"; "Kytto's sign-in does not sign other MCP clients in." This closes part of the remote-OAuth distinction Bastion listed against Kytto on 9 Oct, but only for Kytto itself: other clients still need their own sign-in or Kytto's Gateway, which does not route remote servers.
- **Remote Doctor:** checks Streamable HTTP endpoints and their tool lists without calling a tool.
- **Plugin discovery:** shows servers that Claude Code and Codex plugins add, read-only. Bastion 1.28's Only Bastion _filters_ the same servers out of Claude Code.
- **Portable setup:** export and import a setup, secrets as required inputs on the new machine, imported servers disabled.
- **Contract Guard** shows before/after diffs, no longer alerts on key reordering (issue #12).

**Signing (P, issue #4, closed 1 Oct).** "I am not buying an Apple Developer membership, and I am not planning a Windows signing certificate for now… The releases stay unsigned." 1.0.8 is "ad-hoc signed and the DMG is not notarized."

**Strengths.** Free, MIT, native, Windows too, macOS 15+, the widest diagnostic surface in the set, and now OAuth for remote servers.

**Weaknesses.** Unsigned by decision; Gateway mode still stdio-only and optional; activity metadata-only; no write gate; advice rather than enforcement; momentum slowing (9 stars, one release this window).

**Positioning statement (reverse-engineered).** For developers juggling MCP servers across several AI clients, KyttoMCP is the free local control panel that keeps every client's setup in sync and explains what broke, because it reads each client's own config and never requires a gateway.

### 2.2 Docker MCP Toolkit / Gateway / Catalog

No change of substance (P). mcp-gateway v0.44.2 (21 Oct, pre-release) is "chore: bump Go to 1.26.10 (#609)"; 1,611 stars. Desktop 4.95.0 (12 Oct), 4.96.0 (19 Oct), 4.96.1 (21 Oct) update Docker Agent and fix Gordon, no MCP items. The Toolkit page still "describes the MCP Toolkit interface in Docker Desktop 4.62 and later" and the `docker mcp` commands "are available in Docker Desktop". Enterprise gateway hero and subhead unchanged; deployment modes "Managed in your cloud" and "Air-gapped appliance" available, "Docker-managed cloud" coming soon (whether new since 9 Oct _unverified_). Blog, 12 to 21 Oct: a Docker Hub PAT advisory (CVE-2026-105445), "AI Agent Security Risks", Harbor + Sandboxes evals, "From Containers to Sandboxes: Developer Trust in the Agentic Era", a Sandboxes team kit, a Secure Software Factory post. None mentions MCP. The individual Mac developer is still not addressed.

### 2.3 ToolHive / ToolHive Studio (Stacklok)

**Core (P).** Six releases, v0.52.0 (12 Oct) to v0.55.2 (19 Oct); 2,304 stars. Two matter to Bastion:

- **`thv client connector add|list|rm --client claude-desktop` (v0.55.0, PR #6840, merged 16 Oct).** Writes remote servers into Claude Desktop's `managedMcpServers` key; Desktop then runs the OAuth sign-in itself. Scope, from the PR: it only works for Claude Desktop **in third-party mode** ("inference through an LLM gateway, configured by `thv llm setup --client claude-desktop`"), "since without the inference settings Desktop ignores `managedMcpServers`", and an MDM profile overrides it. It does not reach a Claude subscriber's ordinary Desktop, so Bastion's bridge requirement for Desktop is unaffected for its buyer. Worth noting for later: the PR says Desktop "connects to each entry directly", i.e. from the Mac, in that mode (_unverified_ whether a loopback URL would be accepted).
- **Homebrew cask (v0.55.1, PR #6859).** The Mac binaries "are Developer ID signed but not notarized", so a post-install hook removes `com.apple.quarantine` to get past Gatekeeper.

Also: operator ignores `MCPServer.spec.permissionProfile` after an arbitrary-file-read finding (v0.53.0), Pi as a client (v0.54.0), rootless Podman egress advisory GHSA-2x65-h9w3-h7hc (v0.55.2).

**Studio (P).** v0.40.2 (14 Oct): security dependency fixes, bundled ToolHive v0.53.0. 171 stars, one commit on main since 9 Oct. Install docs still list Docker, Podman, Colima or Rancher Desktop (experimental) with no container-free path.

**Company (P).** Hero unchanged ("The open architecture for a multi-model world"). Nav: MCP Registry, MCP Gateway, MCP Runtime, AI Gateway; banner for Mecatl. Five posts 12 to 20 Oct on governance, AI spend attribution, the agent layer, "Own your intelligence, own your tools". No funding news.

### 2.4 1MCP

v0.39.1 (12 Oct), v0.39.2 (13 to 14 Oct), v0.39.3 (15 Oct): connections survive a backend recovering, large capability lists no longer truncated, OAuth user-agent and discovery roles (P). 522 stars, 68 forks. **Direction on `main` (unreleased, P):** agent sessions across projects: per-call project binding (#636), ownership-aware project lifecycle (#662), session ownership and project defaults resolved automatically (#669, 21 Oct), shareable JSON recipes for checkout and backend preparation (#640, #652), a README section on worktrees (#668). Opt-in OTLP telemetry in an open PR (#665). This is the same problem Bastion's Workspaces solve for Claude Code (folder-scoped profiles), approached from the CLI-agent side. Credential storage unchanged since v0.39.0 (docs and no commits to `src/auth/storage`; code default _unverified_). No GUI.

### 2.5 MCP Router (archived)

Repo archived, description "MCP Router — development, support and security updates ended 2026-09-18." 2,136 stars, 184 forks. `docs/END_OF_SUPPORT.md` unchanged since 18 Sep (P). Forks: chalan630/mcp-router is 9 commits ahead (10 to 11 Oct: removes the retirement notice, reconnects after wake, per-session isolation), 0 stars, no release; chenqinggang001 is 1 commit ahead (21 Oct). No successor has users (P). No "MCP Router alternative" thread found on HN; Reddit coverage _unverified_. **Search noise:** rabin-a/mcp-router (created 16 Oct, Rust CLI, unrelated) now shares the name, with a 1-point Show HN "I benchmarked 6 MCP proxies in Claude Code, then built my own" (P).

### 2.6 mcpock (new, signed native Mac)

**Overview.** `aka-kika/mcpock`, created 9 Oct, MIT, 2 stars, Swift, macOS 26 Apple Silicon, "Signed and notarized", direct download from mcpock.com. Fast cadence: 1.10.7 and 1.10.8 on 17 Oct, 1.10.9 on 20 Oct (P).

**Messaging.** Tagline: "Every MCP server, quietly checked." Repo: "A small Mac menu bar app that checks every MCP server your AI agents use: broken, slow, waiting for a sign-in, or set up differently." Reads the configs of 20 agents (P).

**Product.** A health checker: it does not run servers, hold credentials or sit in the call path (P). Free.

**Why it matters.** It is the first other app in the set that matches Bastion on the surface signals a Mac buyer sees first: Swift, menu bar, macOS 26, signed and notarized. A reader skimming a directory can file both under "Mac MCP menu bar app". The difference is the whole product: mcpock reports on servers; Bastion runs them, holds their credentials and gates their writes.

**Positioning statement.** For Mac developers with servers spread across many agents, mcpock is the free menu bar checker that tells you which servers are broken, slow or out of sync, because it reads every agent's config quietly in the background.

### 2.7 Delta MCP (announced, not shipped)

**Overview.** `mcpdelta/mcpdelta`, created 7 Oct, 82 stars, no licence, no code; "Coming soon for macOS, Windows and Linux", free. The README asks visitors to star the repo (P).

**Messaging.** Tagline: "Let your AI act on your tools. Without crossing your fingers." Repo: "sits between your AI apps and their MCP servers: any server, every tool. It checks each task before it runs, applies it all or nothing, reads back what it changed and lets you undo it. Far fewer tokens on multi-step tasks, and shortcuts that run on a schedule." (P)

**Why it matters.** It claims the upper-right quadrant (in the call path, desktop app) with a consumer outcome story (safety, undo) rather than a mechanism story, and it is already out-collecting Bastion's attention 82 to 0 on GitHub without a binary. "Applies it all or nothing" and "undo" across arbitrary MCP servers are hard claims for any gateway (most tools have no inverse); treat them as aspirational until a build ships.

**Positioning statement.** For people letting AI apps act on real tools, Delta MCP is the free safety layer that checks, applies and can undo every task, because it sits between every AI app and every server.

### 2.8 Adjacent and minor

- **Ask Key** (`sudoHG/AskKey`, created 1 Oct, 6 stars, MIT, Swift, v0.3.2 on 21 Oct): "the Mac key manager for AI agents". API keys encrypted on the Mac, agents find them over MCP, per-use approval, "the value goes only to the program, never to the AI" (P). Overlaps Bastion's credential sentence, not supervision.
- **Cheatcode** (`ChenxingJi-Innovate/Cheatcode_`, created 11 Oct, 81 stars, MIT, Swift): "Skills and tools for your AI apps, added in one click"; open-source parts of cheatcodehq.com, a Mac installer and skill packs (P). Overlaps Bastion 1.25's Skills and the catalog. Price _unverified_.
- **mcp-bastion** (Gowthaman90): GitHub v1.2.0 (16 Oct, per-request identity forwarding), npm 1.3.0 (20 Oct, shadow-mode audit), 7 stars, still Node/Docker, no GUI (P). A further name collision: PyPI `bastion-mcp` (Apache-2.0, 1.0.2, 29 May) (P).
- **Fentaris** cli 2.0.0 (10 Oct) and 2.0.1 (14 Oct), 8 stars (P). **SkillHub Local** 0.2.21 (10 Oct, Pi and DeepSeek Harness), 20 stars (P). **sparfenyuk/mcp-proxy** v0.13.0 (10 Oct, Basic/Digest upstream auth) (P). **IBM ContextForge** v1.1.0 (20 Oct, redesigned web UI), server-side (P).
- **Older Mac config syncers** surfaced by search and not profiled in earlier briefs: MCPBolt, MyMCP, Vibe Manager (paid), MCP Controller (S, all _unverified_ beyond listings). Same lower-right quadrant as Kytto's default mode.
- Unchanged: MetaMCP (dormant), TBXark/mcp-proxy, MCPJungle, apatureai/bastion.

---

## 3. Messaging comparison matrix

|                          | **Bastion**                                                                                      | KyttoMCP                                                   | mcpock                               | Delta MCP (announced)                                           | Docker Toolkit / Gateway                | ToolHive Studio                                   | 1MCP                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------- | ------------------------------------ | --------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------- | ------------------------------------------ |
| Tagline                  | "One MCP server, running once, for every client."                                                | "Your MCP setup. Finally in sync."                         | "Every MCP server, quietly checked." | "Let your AI act on your tools. Without crossing your fingers." | "One secure gateway for all your tools" | "Run any MCP server … in a locked-down container" | "The unified MCP runtime"                  |
| Target buyer             | Individual Mac developer, several MCP clients                                                    | Individual developer, Mac or Windows                       | Mac developer, many agents           | Anyone letting AI apps act on tools                             | Platform and security teams             | Engineering leaders; developers via Studio        | Developers running agent CLIs              |
| Key differentiator       | One supervised process per profile; Keychain items; write gate; hash-chained audit; Only Bastion | Config sync, Doctor, Contract Guard, OAuth, portable setup | Health checks across 20 agents       | Pre-checks, all-or-nothing apply, undo                          | Signed container catalog, policy        | Isolation, Kubernetes pedigree                    | One shared runtime, project-aware sessions |
| In the call path         | Yes, always                                                                                      | Optional, stdio only                                       | No                                   | Yes (claimed)                                                   | Yes                                     | Yes                                               | Yes                                        |
| Secrets                  | Each credential its own Keychain item, per profile, by default                                   | Native storage for OAuth and Gateway; masked config        | None held                            | _Unverified_                                                    | Desktop secret store                    | Encrypted file, 1Password, Vault                  | Files default; opt-in Keychain for OAuth   |
| Container runtime on Mac | No                                                                                               | No                                                         | No                                   | _Unverified_                                                    | Yes (Desktop 4.62+)                     | Yes                                               | No                                         |
| Signed build (Mac)       | Developer ID, notarized                                                                          | Ad-hoc, not notarized, by decision                         | Signed and notarized                 | No build                                                        | Desktop signed                          | CLI signed, not notarized; quarantine stripped    | _Unverified_                               |
| Price                    | $14.99 / €14.99 once per major                                                                   | Free (MIT)                                                 | Free (MIT)                           | Free                                                            | Free with Desktop; enterprise by sales  | Free; enterprise by demo                          | Free                                       |
| Platforms                | macOS 26+                                                                                        | macOS 15+, Windows                                         | macOS 26+, Apple Silicon             | Mac, Windows, Linux (promised)                                  | Mac, Windows, Linux                     | Mac, Windows, Linux                               | Mac, Windows, Linux                        |
| GitHub stars (21 Oct)    | 0                                                                                                | 9                                                          | 2                                    | 82                                                              | 1,611 (gateway)                         | 171 (Studio), 2,304 (core)                        | 522                                        |
| Tone                     | Exact, self-auditing                                                                             | Careful, reassuring                                        | Quiet, small                         | Consumer, outcome-led                                           | Confident, CISO-facing                  | Authoritative platform                            | Engineering, ADR-driven                    |

---

## 4. Value proposition and narrative comparison

|               | Promise                                                                            | Evidence offered                                              | Mechanism                                          | Villain / hero / transformation                                      |
| ------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------- |
| **Bastion**   | Each server once, for every client; secrets out of files; every call on the record | `make smoke`, `make audit`, `/checked`, changelog per release | Loopback gateway supervising one child per profile | A refresh token in `.mcp.json` / the developer / trust you can audit |
| **KyttoMCP**  | Every client's setup in sync, and why it broke                                     | Screenshots, open issues, privacy page                        | Reads and rewrites each client's config            | Config drift / the developer / one clear view                        |
| **mcpock**    | Know which server is broken before the agent does                                  | Signed build, fast release cadence                            | Background checks of 20 agents' configs            | Silent breakage / the developer / quiet confidence                   |
| **Delta MCP** | Let AI act without fear                                                            | None yet (no build)                                           | A checking layer between apps and servers          | Agents doing damage / the user / "without crossing your fingers"     |
| **Docker**    | Approve, isolate, record                                                           | Enterprise customers, signed images                           | Containers and a policy gateway                    | Ungoverned agents / the platform team / trust for agents             |

The shift this window: Delta MCP's story is the one Bastion's write gate and audit could tell, told as an outcome ("act without crossing your fingers") instead of a mechanism ("a write gate that removes tools from `tools/list`"). Bastion's mechanism is real and Delta's is not shipped, but Delta's sentence is the one people starred.

---

## 5. Positioning map

Axes unchanged from 9 Oct: **where enforcement happens** (edits or reads client configs ↔ sits in the call path as one shared runtime) and **what the Mac user has to run** (container runtime or server stack ↔ native app, nothing else).

```
                        Sits in the call path (shared runtime, enforces)
                                          ^
          Docker Toolkit/Gateway          |   BASTION  (signed, notarized)
          ToolHive Studio                 |   (Delta MCP: claimed, no build)
                                          |   (1MCP: shared runtime, CLI only)
                                          |   (Kytto Gateway mode: optional, stdio only)
  Container / server stack <--------------+--------------> Native app, nothing else
                                          |
          (no one)                        |   KyttoMCP (default mode, unsigned)
                                          |   mcpock (checker, signed)
                                          |   SkillHub Local, Cheatcode, MCPBolt, MyMCP
                                          |   MCP Router (archived)
                                          v
                        Reads or edits client configs (each client still spawns)
```

The upper-right quadrant is still Bastion's alone among shipped products. The lower-right is getting crowded (five or more free tools), which is good for Bastion only if a buyer can tell the quadrants apart; on a directory card or a menu bar screenshot they look the same. Delta MCP is the first product announced into Bastion's own quadrant.

---

## 6. Content gap analysis

**Topics (changes since 9 Oct in bold)**

| Topic                                        | Bastion                                                   | Competitors                                                        | Gap                                                                     |
| -------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| Moving off MCP Router                        | none                                                      | none; one 0-star fork                                              | Still open, decaying (repo archived, users scattering)                  |
| **Plugin and claude.ai connector servers**   | **Only Bastion, built (1.28), changelog only**            | **Kytto shows them read-only (1.0.8)**                             | **Open: Bastion is the only one that filters them**                     |
| **Signed and notarized as a trust argument** | Hero badge only                                           | **mcpock says it; Kytto refuses; ToolHive strips quarantine**      | **Open and now evidenced**                                              |
| **Agent safety: approve, undo**              | Write gate, audit (built); no per-call approval or undo   | **Delta MCP (announced)**, Docker blog ("AI Agent Security Risks") | Bastion has half the story built; say the half it has                   |
| **Moving a setup to a new Mac**              | none (iCloud Keychain sync, per the entitlement decision) | **Kytto portable export (1.0.8)**                                  | _Unverified_ what Bastion can honestly claim here; check before writing |
| Xcode's MCP server for every agent           | Built (1.24), changelog only                              | none; **Xcode 27.2 RC adds `GetCodeCoverage`**                     | Open, Mac-only, Bastion-only                                            |
| **Projects / worktrees for agents**          | Workspaces (1.23), Claude Code only                       | **1MCP `main` (project binding, worktrees)**                       | Parity risk once 1MCP releases                                          |
| Comparison pages                             | none                                                      | **Kytto `compare.html` (vs hand-editing only)**                    | Open, high intent                                                       |
| Tool contract changes                        | nothing built                                             | Kytto Contract Guard diffs, mcp-bastion pinning                    | Product question (9 Oct action 6)                                       |

**Formats**

| Format             | Bastion                                | KyttoMCP          | mcpock       | Delta MCP | Docker | ToolHive | 1MCP     |
| ------------------ | -------------------------------------- | ----------------- | ------------ | --------- | ------ | -------- | -------- |
| Landing page       | Yes                                    | Yes               | Yes          | README    | Yes    | Yes      | Docs     |
| Changelog on site  | Yes, page per release                  | Repo              | Repo         | n/a       | Notes  | Releases | Releases |
| Demo video         | Tour loop                              | 72-second demo    | _Unverified_ | none      | Series | YouTube  | none     |
| Blog               | mg-crea.com/blog, none on product site | none              | none         | none      | Heavy  | Heavy    | ADRs     |
| Comparison pages   | none                                   | vs hand-editing   | none         | none      | none   | none     | none     |
| Directory listings | Glama (S); not punkpeye                | Product Hunt etc. | _Unverified_ | none      | All    | All      | punkpeye |

---

## 7. Opportunities

**The punkpeye route may be open again.** The 9 Oct brief recorded the awesome-mcp-servers PR as blocked by its Glama requirement. Glama now lists `mgcrea/bastion` under Developer Tools and Security, marked "Active" (S). Every "bastion" line in the punkpeye README today belongs to someone else (`apatureai/bastion`, `Gowthaman90/mcp-bastion`, and two SSH-bastion mentions) (P), so a listing would also be the first disambiguation in the one place the collision is visible. Check what punkpeye's requirement asks of the Glama entry (a badge, a score) before reopening.

**Signed and notarized, now with three contrasts to cite.** Kytto: "ad-hoc signed and the DMG is not notarized", by decision (P). ToolHive: "Developer ID signed but not notarized", with the installer removing `com.apple.quarantine` (P). Delta: no build. mcpock is signed and notarized but holds no credentials. "The only signed, notarized app here that holds your tokens" is checkable and true.

**Only Bastion is unclaimed and timely.** Claude Code plugins and claude.ai connectors add MCP servers a developer did not configure on that Mac; Kytto 1.0.8 now _shows_ them, read-only, which tells readers the problem exists. Bastion 1.28 _filters_ them out per profile, keeps a backup, changes only two keys and says plainly it is "hygiene rather than a boundary". Nobody else in the set does this. Built; changelog only. (Confirm it still behaves on Claude Code 2.1.305 first, see §8.)

**Delta's sentence, Bastion's proof.** Delta MCP shows demand for "let your AI act without fear" (82 stars, no code). Bastion has the built half: writes off by default per profile, write tools removed from `tools/list` rather than refused, every call recorded with arguments in a hash-chained log. It does not have per-call approval or undo, and must not imply them. An outcome-led line over the existing mechanism ("Your agent can read everything. It writes only where you said so, and you can prove what it did.") answers Delta without overclaiming.

**MCP Router's users, still unclaimed.** Archived, no successor fork with users, no migration page anywhere (P). The window is closing rather than closed; the export-contains-credentials hook from the 9 Oct brief still applies.

---

## 8. Threats

**Attention gap.** Delta MCP (82 stars, no code), Cheatcode (81 in ten days), Bastion 0 after thirty public releases. Stars are a weak proxy for users, but directories, the awesome list and readers skimming GitHub sort by them. Bastion's lack of any third-party mention (S) is the larger problem; the product is not the bottleneck.

**Kytto closes gaps one release at a time.** Native OAuth (1.0.8) removes one line from Bastion's column against it; plugin discovery and portable setup add two to Kytto's. Its weaknesses are now structural and chosen (unsigned, config-side, advice rather than enforcement), which makes them durable talking points, but its feature list keeps lengthening.

**Same-looking Mac apps.** mcpock is Swift, menu bar, macOS 26, signed and notarized, free. Next to it in a listing, Bastion's paid price needs the one-line reason (it runs the servers and holds the keys) to be visible on the card itself.

**Claude Code changed `allowedMcpServers` filtering (2.1.305, 20 Oct).** The changelog entry concerns `managed-mcp.json` (P); Bastion 1.28's Only Bastion writes `allowedMcpServers` into a profile's `settings.json`. Whether the change alters how the user-settings list is applied is _unverified_. Separately, 2.1.299 stopped `mcp__a` allow rules from matching `a__b`, which interacts with profile renames (1.29 already warns that renamed tool names stop matching rules). Product risk, not marketing: test before promoting Only Bastion.

**Gaps list contradicted.** Unchanged from 9 Oct and still live on the site: 1MCP v0.39.0 delivers `subscriptions/listen` and bridges elicitation on a shared runtime, while `Gaps.astro` says a shared instance "still cannot" and "has no single client to ask" (P).

**Licence signal.** GitHub's repo sidebar reports **MIT** for `mgcrea/bastion` because the root `LICENSE` is MIT; the app is source-available under `apps/apple/LICENSE` (P). Directories and listings copy GitHub's field. A reader can come away believing the app is MIT, or later think the "source-available" wording is a bait and switch.

**Name collisions grew.** mcp-bastion shipped two versions this window (v1.2.0, npm 1.3.0), PyPI has `bastion-mcp`, and OVH's SSH "The Bastion" surfaced on HN on 17 Oct (P). "MCP Router" is now also an unrelated Rust CLI, which muddies the migration search (P).

**Campaign drift, fourth brief running.** Hero line recommended on 7 Sep, 20 Sep and 9 Oct; gaps fix and MCP Router page on 9 Oct; none shipped, while three releases did.

---

## 9. Recommended actions

Each action names what is built today. Nothing below asks to market an unbuilt feature. Five, not seven: the backlog is the problem.

**Quick wins (this week)**

1. **Ship the hero line, or decide to drop it.** "Signed and notarized. No container runtime. No account." under the hero. Fourth recommendation; the evidence is stronger now (Kytto unsigned by decision, ToolHive strips quarantine, Docker and ToolHive Studio still need a runtime, all P). If it is not wanted, say so and it leaves the list.
2. **Fix `Gaps.astro`'s two "cannot" lines to "not yet".** Second recommendation. Evidence: 1MCP v0.39.0, PRs #536 and #555 (P). A one-file change.
3. **Reopen the punkpeye awesome-mcp-servers PR on the strength of the Glama listing** (S), after checking the exact requirement. Use "Bastion for Mac" wording in the entry so it reads apart from `mcp-bastion` four lines away.
4. **Make the licence split visible where GitHub reads it.** Options: say "App source-available, website and scripts MIT" in the repo description, or restructure the root licence file so GitHub stops detecting plain MIT. The second changes a legal file; that is your call, not a copy edit.

**Strategic moves (this quarter)**

5. **One post and one comparison, both from built features.** (a) "Only Bastion: keep Claude Code to the servers you chose" on mg-crea.com/blog, framed against plugin and connector sprawl, after confirming behaviour on Claude Code 2.1.305. (b) A Bastion vs KyttoMCP page that concedes Kytto's real leads (free, Windows, macOS 15, diagnostics, portable setup) and states Bastion's (in the path, signed, write gate, chained audit, credentials for every client not just itself). The 9 Oct comparison set (Docker, ToolHive) and the MCP Router page stay valid; do them after these two, or drop the MCP Router page if it is not written by mid-November.

**Product questions surfaced (not marketing):** test Only Bastion on Claude Code 2.1.305; check the Xcode catalog entry handles Xcode 27.2's new `GetCodeCoverage` tool correctly with writes off; per-call approval and undo (Delta's claim) and tool-contract pinning (9 Oct action 6) remain undecided.

---

## 10. Sources (all accessed 21 October 2026)

**Bastion (repo):** `README.md` (Licence section), `CHANGELOG.md` 1.28.0 to 1.30.0, `LICENSE`, `apps/apple/LICENSE`, `apps/website/src/components/Hero.astro`, `Gaps.astro`; `git log --since=2026-10-09 -- apps/website`; `gh repo view mgcrea/bastion`; HN Algolia `url:bastion.mgcrea.io`; https://github.com/punkpeye/awesome-mcp-servers (README, lines matching "bastion"); https://glama.ai (listing of mgcrea/bastion) (S).

**KyttoMCP:** https://kytto.jakubhecht.sk/ · https://kytto.jakubhecht.sk/compare.html · https://github.com/heyitsjakub/KyttoMCP/releases/tag/v1.0.8 · https://github.com/heyitsjakub/KyttoMCP/issues/4 · https://github.com/heyitsjakub/KyttoMCP/issues/12 · https://www.producthunt.com/products/kyttomcp (S)

**Docker:** https://github.com/docker/mcp-gateway/releases/tag/v0.44.2 · https://docs.docker.com/desktop/release-notes/ · https://docs.docker.com/ai/mcp-catalog-and-toolkit/get-started/ · https://docs.docker.com/ai/mcp-catalog-and-toolkit/cli/ · https://www.docker.com/products/mcp-enterprise-gateway/ · https://www.docker.com/blog/ · https://www.docker.com/pricing/

**ToolHive / Stacklok:** https://github.com/stacklok/toolhive/releases (v0.52.0 to v0.55.2) · https://github.com/stacklok/toolhive/pull/6840 · https://github.com/stacklok/toolhive/pull/6859 · https://github.com/stacklok/toolhive-studio/releases/tag/v0.40.2 · https://docs.stacklok.com/toolhive/guides-ui/install · https://stacklok.com/ · https://stacklok.com/blog/

**1MCP:** https://github.com/1mcp-app/agent/releases (v0.39.1 to v0.39.3) · commits on `main` 13 to 21 Oct (#636, #640, #652, #662, #668, #669) · https://github.com/1mcp-app/agent/pull/665 · `docs/site/en/commands/auth.md`

**MCP Router:** https://github.com/mcp-router/mcp-router (archived) · `docs/END_OF_SUPPORT.md` · https://github.com/chalan630/mcp-router · https://github.com/chenqinggang001/mcp-router · https://github.com/rabin-a/mcp-router · https://news.ycombinator.com/item?id=50124411

**New entrants:** https://github.com/aka-kika/mcpock · https://mcpock.com · https://github.com/mcpdelta/mcpdelta · https://github.com/sudoHG/AskKey · https://github.com/ChenxingJi-Innovate/Cheatcode_ · HN Algolia Show HN queries since 2026-10-09 (13 queries: MCP gateway, proxy, manager, hub, control panel, menu bar, Keychain, servers mac and variants)

**Minor players:** https://github.com/Gowthaman90/mcp-bastion · https://www.npmjs.com/package/mcp-bastion · https://pypi.org/project/bastion-mcp/ · https://github.com/apatureai/bastion · https://github.com/Fentaris/fentaris · https://github.com/mjalalimanesh/skillhub-local · https://github.com/metatool-ai/metamcp · https://github.com/sparfenyuk/mcp-proxy/releases · https://github.com/TBXark/mcp-proxy/releases · https://github.com/IBM/mcp-context-forge/releases · https://github.com/mcpjungle/MCPJungle/releases

**Platforms:** Claude Code CHANGELOG (2.1.296 to 2.1.305) · https://support.claude.com (release notes) · https://github.com/openai/codex/releases (0.163.0) · https://github.com/openai/codex/issues/48195 · https://cursor.com/changelog · VS Code 1.143 release notes · Xcode 27.2 RC release notes

## Monitoring (next full refresh on or around 9 November)

- **Delta MCP:** first build, licence, what "undo" covers in practice, stars. If it ships, it becomes the comparison that matters most.
- **KyttoMCP:** Gateway scope (remote routing), whether OAuth extends to other clients through it, cadence.
- **mcpock:** whether it starts running or proxying servers (it would then enter Bastion's quadrant signed and free).
- **1MCP:** whether the project-aware sessions on `main` ship, and any GUI.
- **Claude Code:** `allowedMcpServers` and settings-precedence changes (Only Bastion depends on them); any built-in credential store.
- **ToolHive:** `managedMcpServers` beyond third-party mode; notarization of the CLI; Studio's runtime prerequisite.
- **Docker:** any Toolkit line in Desktop release notes; Toolkit without Desktop.
- **Bastion itself:** stars, the punkpeye PR, and whether actions 1 to 4 shipped.
- Quarterly only: MetaMCP, both mcp-proxies, Fentaris, SkillHub Local, ContextForge, MCPJungle, the older Mac config syncers.
