# Roundup outreach kit, September 2026

Prepared Mon 21 Sep 2026 for the "Roundup outreach" row of `campaign-plan-2026-09.md`. Every
target below was fetched on 21 Sep before anything was drafted.

## What the check found

The brief and the plan both say the four roundups "list MCP Router today and not Bastion". That
is wrong for all four: **none of them lists MCP Router.** No draft below makes that claim, and the
line should come out of the brief and the plan.

Two of the four are also poor fits, for a reason the brief did not look at:

| Target | What it actually is | Route | Fit |
| --- | --- | --- | --- |
| awesomeclaude.ai/mcp/aggregators | 24 entries in `owner/repo` form, the same shape as the Aggregators section of `punkpeye/awesome-mcp-servers`. It appears to mirror that list; the site's own repo (`webfuse-com/awesome-claude`) holds no aggregator list. | PR to punkpeye | **Good.** One PR, probably two listings. |
| mcp.directory | A server directory with a submit form (GitHub URL, reviewed within 24 hours) and a blog that compares gateways (Composio, Docker, MCPJungle, Obot). Contact: hello@mcp.directory. | Form, then email | **Good** |
| heyitworks Q1-2026 survey | Daniel Rosehill's personal blog. He runs Linux (KDE) and scores 17 server-side tools against his own target architecture: three-level hierarchy, nested aggregation, self-hosted, per-endpoint auth, client-dimension visibility. Contact: public@danielrosehill.com. | Email | **Weak.** Mac only, no namespaces. Worth one honest mail, low odds. |
| zimaspace "10 Best MCP Gateways & Proxies for Local AI" | Content marketing on a home-server hardware shop (Eva Wong, 2 Sep 2026). Ten server-side tools, no desktop app, no Mac app. Contact form only. | Form | **Poor.** Their readers run Zima boxes, not Macs. Send last or skip. |

Two constraints to know before sending:

- `mgcrea/bastion` has **0 stars** today. `webfuse-com/awesome-claude` asks for "reasonable
  stars/forks" and for open source, and Bastion's app is source-available, so do not PR there.
  punkpeye asks only for a public repository you install and run yourself.
- punkpeye's legend has no Swift emoji, so the entry carries scope and OS only.

The primary KPI (three of four listings by 16 Oct) was set against the wrong picture. A realistic
reading is two likely (punkpeye plus its mirror, mcp.directory), one possible (heyitworks), one
unlikely (zimaspace). Candidates to replace zimaspace, not yet checked: PulseMCP, and
manveerc.substack.com "Best MCP Gateways in 2026: A Hands-On Comparison".

## The kit

**Three sentences.**

> Bastion is a macOS menu bar app that runs each MCP server once and lets every client on the Mac
> share it over loopback HTTP, each with its own revocable token. Credentials are Keychain items,
> a per-profile write gate leaves the mutating tools out of tools/list, and an opt-in audit log is
> hash chained. No container runtime, no account, source public, signed build $14.99 with a
> 30-minute trial.

**One table row**, in zimaspace's columns since theirs is the only published table with fixed
headers (Gateway · Best For · Self-Hosted · Aggregation · Security / Policy · Key Difference):

| Bastion | One developer on a Mac with several MCP clients | Yes, loopback only | One shared process per server, one endpoint per profile and server (not merged into one) | Keychain credentials, per-client tokens, per-profile write gate, opt-in hash-chained audit log | Native macOS app, no container runtime |

**Two screenshots**, from `apps/website/src/assets/shots/`: `running.png` and `log.png`. Both are
demo-seeded, so quote no figure from them. Attach by hand.

**Links.** https://github.com/mgcrea/bastion · https://bastion.mgcrea.io

## 1. PR to punkpeye/awesome-mcp-servers

**Blocked, not opened (21 Sep).** The list now requires every entry to be listed on Glama, which
runs the server from a Dockerfile and checks that it answers introspection. A bot asks for the
Glama score badge on every PR without one, and the maintainer repeats it (see #12295, an unrelated
"Bastion" SAST server, open since 17 Aug for exactly this). A signed macOS app cannot start in a
Linux container, so this PR cannot pass. The draft stays below in case the rule changes; the
awesomeclaude.ai listing goes with it.

Section `### 🔗 Aggregators`. The section is not alphabetical in practice, so add at the bottom.

```
- [mgcrea/bastion](https://github.com/mgcrea/bastion) 🏠 🍎 - macOS menu bar app that runs each MCP server once for every client on the machine, with credentials in the Keychain, a per-profile write gate and a record of every tool call.
```

Title: `Add mgcrea/bastion to Aggregators`

```
Bastion is a macOS menu bar app that supervises MCP servers: each one runs once and every client on the Mac (Claude Code, Claude Desktop, Cursor, Codex, etc.) reaches it over loopback HTTP with its own token.

Not sure if Aggregators is the best section, it is the closest one. Each server keeps its own endpoint rather than being merged into one.

The app's source is public (source-available, not OSI) and the signed build is sold, happy to reword the entry if that needs to be stated.

Thanks!
```

Check the client list in the first paragraph against `docs/clients.md` before opening it.

## 2. mcp.directory

Submit https://github.com/mgcrea/bastion at https://mcp.directory/submit first, with the three
sentences as the short description. Then, to hello@mcp.directory:

Subject: `Bastion, a desktop MCP gateway for macOS`

```
Hi,

I just submitted github.com/mgcrea/bastion through the server form, though not sure it is the right place for it.

Bastion is not an MCP server itself, it is a macOS menu bar app that runs them: each server runs once, its credentials are Keychain items, and every client on the Mac reaches it over loopback with its own token. It does ship one built-in server (to manage Bastion itself), which is probably what your tool detection will pick up.

It could also sit next to Docker MCP Gateway in your gateways comparison, as the local option that needs no container runtime. The source is public and the signed build is $14.99 with a 30-minute trial:

https://bastion.mgcrea.io

Thanks,
Olivier
```

## 3. heyitworks (Daniel Rosehill)

To public@danielrosehill.com. Read the survey before sending; the second paragraph says you did.

Subject: `Bastion, for your MCP gateway survey`

```
Hi Daniel,

I read your Q1 survey of MCP aggregation gateways and wanted to point you to one that is not in it: Bastion, a macOS menu bar app I built that runs each MCP server once and lets every client on the machine share it over loopback HTTP.

It is macOS only and does not do namespaces or nested aggregation, so it will not match your target architecture. What it does cover from your criteria is tool-level controls (a per-profile write gate that leaves the mutating tools out of tools/list rather than refusing them), a separate revocable token per client, and a record of every call per client.

Credentials are Keychain items, there is no container runtime and no account. The source is public and the signed build is $14.99 with a 30-minute trial:

https://github.com/mgcrea/bastion

Would be great if you could consider it for the next edition,

Thanks,
Olivier
```

## 4. zimaspace (optional)

Contact form on shop.zimaspace.com, addressed to Eva Wong. Send only after the other three.

```
Hi Eva,

Your MCP gateways roundup notes that ToolHive is more platform than a single-user setup needs, and all ten entries run server-side.

For a single developer on a Mac there is also Bastion (https://bastion.mgcrea.io), a native menu bar app I built: one shared process per MCP server for every client, credentials in the Keychain, no container runtime. It is macOS only, so it may be out of scope for your readers.

Happy to send a table row in your format if it is useful,

Thanks,
Olivier
```

## Tracking

| Target | Sent | Reply | Listed |
| --- | --- | --- | --- |
| punkpeye PR | Blocked by the Glama requirement | | |
| awesomeclaude.ai | Blocked with it | | |
| mcp.directory form | 21 Sep, no email given | | |
| mcp.directory email | Draft in Mail, 21 Sep | | |
| heyitworks | Draft in Mail, 21 Sep | | |
| zimaspace | Held until the two mails are out | | |

The two Mail drafts carry no attachment and do not mention one; each links the site or the repo
instead. Add the screenshots by hand only if you also add a line saying so.
