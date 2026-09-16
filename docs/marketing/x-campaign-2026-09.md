# Bastion on X, 14 to 28 September 2026

The X track of `campaign-plan-2026-09.md`, rebuilt on 2026-09-14 because it had not started: the
two articles went out, but no Bastion post has, and the week-1 blockers it leaned on (`/blog`, the
measurement script, `/changelog`) have not shipped. This version depends on none of them. Every
post is a receipt that already exists in the repo.

Drafts follow `reply-as-olivier` and `.studio/X-POSTING.md`: no emoji, no em dashes, conclusion
first, link in a self-reply, app named last or not at all.

## Where the account stands

|                              | 2026-09-14                                                                          |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| Followers                    | 124 (following 712)                                                                 |
| Subscription                 | Premium, so posts over 280 characters are fine                                      |
| Pinned                       | "The blast radius" article, 469 views, 8 replies, 3 of them still unanswered        |
| Best Bastion-adjacent result | the article post itself                                                             |
| Worst                        | bare-link pitches under @levelsio (8 views) and @yacineMTB (21 views) on 2026-09-11 |

The X-POSTING finding holds again this week: an argument gets hundreds of views, a link with a
pitch gets single digits.

## How posting works

The mgcrea X login carries `tweet.read users.read bookmark.read offline.access`, no `tweet.write`,
so nothing is posted through the API. `x_compose_post` validates a draft and returns an
`x.com/intent/tweet` URL that opens the composer pre-filled, and you press Post. Free, no quota.

Two limits of intents:

- **No media.** Attach a screenshot by hand in the composer. The website shots are demo-seeded
  (Stats shows Dec to Jan dates), so any figure on them must not be quoted as real. A capture of
  your own Stats pane or profile row is fine.
- **No threads in one go.** Post the first one, then the self-reply is an intent with `inReplyTo`,
  which needs the new post's id. Paste the URL back, or ask for it to be read off the timeline.

## Calendar

Paris times, 14:00 to 16:00 (US East morning), per the parent plan.

| Day              | What                                                                             | Draft      |
| ---------------- | -------------------------------------------------------------------------------- | ---------- |
| **Mon 14**       | Answer the three open replies under the pinned article                           | R1, R2, R3 |
| Mon 14           | Reply into @0xZenad's quota thread (454 views, posted 13 Sep 20:14 UTC, closing) | R4         |
| Mon 14, optional | Reply to @tpritha03's security poll (216 views)                                  | R5         |
| **Tue 15**       | Tool listings cost tokens before any call                                        | P1         |
| **Thu 17**       | The write gate removes tools rather than refusing them                           | P2         |
| **Tue 22**       | Loopback rules, and why 403 comes before 401                                     | P3         |
| **Wed 23**       | What a hash-chained audit log does not prove (2 posts)                           | P4         |
| **Thu 24**       | Measured protocol dialects across eleven third-party servers                     | P5         |
| **Mon 28**       | What leaks if a .mcp.json leaks, plus price                                      | P6         |
| Daily            | One or two replies from the searches below, never more                           |            |

P6 is the only post that sells. It sits last so it lands after five that did not, and the day before
the Show HN date in the parent plan (Tue 29), which still depends on `/blog`, comparison page 1 and
the audit post, none of which exist yet.

## Replies, today

### R1 · @shlokbuilds, "inverted meaning on by default unless you flag it? that's a footgun"

Reply to `2098778728763662629`. Also answers his earlier question about third parties changing
their schema. 474 weighted characters.

```
No, the toggle means the same thing on every server: writes off is off.

The inversion lives in the catalog entry. MongoDB, DBHub and the Kubernetes server read a READ_ONLY style variable, so for those Bastion sends 1 when writes are off. That is resolved in one function, and make unit checks both polarities in CI.

Where it could bite is a third party renaming the variable. make catalog-check greps the published tarball for it, but it runs by hand, not on every update.
```

Verified: `writeGateSense: "disables"` on mongodb, dbhub, kubernetes in `servers.json`;
`scripts/unit-check.swift:728-740`; `catalog-check` is in no CI job and no Makefile prerequisite.

### R2 · @dxiaolong, "What did you replace npm install plus OAuth with that still lets the agent ship?"

Reply to `2098622715041288601`.

```
The agent still gets the same servers, just not their keys.

Each server runs once on the Mac with credentials in the Keychain, and every client reaches it over loopback with its own revocable token. For remote servers Bastion runs OAuth once per profile and no client sees the token. Nothing arriving over the wire can name a package, a path or an argv.
```

### R3 · @rpa_dake, asking where in the article the details are (Japanese)

Reply to `2098775654305280031`. 108 weighted characters. The link is fine here, it was asked for.

```
Thanks! It is the last section of the article, and the full details are on the site: https://bastion.mgcrea.io
```

### R4 · @0xZenad, "if Claude Code / Codex keeps eating your quota, don't blame the model yet"

Reply to `2099230255550755239`. 329 weighted characters. No app name, no link: his list is about
context cost and nobody in the 7 replies has raised tool listings.

```
One cost missing from the list is the tool listings themselves.

Every MCP server wired to a session sends its whole tools/list on connect, and it stays in the context. One of mine is 85 tools, about 26.2k tokens, before the agent has asked anything.

Claude Code defers those schemas now, Codex and the editors are not known to.
```

### R5 · @tpritha03, "What is currently the biggest security problem?" (optional)

Reply to `2099138993493279215`. The position is the one "The blast radius" already published.

```
Agent permissions, because they decide what the other three can reach.

Injection and a malicious server are ways in. What they get is what the agent already holds. The nx postinstall last year did almost nothing itself, it ran the claude it found with the checks off.
```

## Posts

### P1 · Tue 15 · tool listings

Source: `docs/clients.md` "What a client pays to be wired at all". 477 weighted characters.

```
An MCP server costs tokens before the agent calls a single tool.

My App Store Connect server is 85 tools, about 26.2k tokens, sent to every client on connect and held for the whole conversation. Claude Code and Claude Desktop defer the schemas on their own. The editors and Codex are not known to.

For those, Bastion can serve three tools in its place (search, describe, call), about 0.4k tokens on connect. The full index costs about 3.2k, and only if something asks for it.
```

Self-reply (155):

```
Off by default, because every call then reaches the editor as a dispatcher and per-tool approval rules get coarser. The trade-offs: https://github.com/mgcrea/bastion/blob/main/docs/clients.md
```

Media, optional: your real profile row showing the 26.2k figure.

### P2 · Thu 17 · the write gate

Source: README "Bastion, as one of its own servers" and `servers.json`. 533 weighted characters.

```
With writes off, Bastion does not refuse the mutating tools. It leaves them out of tools/list.

A refused tool still sits in the context, costs tokens and invites a retry. One that is not listed is never planned around. The switch is per profile, so lab/unifi-network can have writes on next to home/unifi-network with writes off, same server.

Three third-party servers in the catalog invert the variable (MongoDB, DBHub and Kubernetes read a READ_ONLY style flag), so polarity is resolved in one function and unit tested both ways.
```

Self-reply (250), the limit said before somebody else says it:

```
The limit: a remote server has no environment to switch, so there the gate is a list of tool names Bastion will not forward. The key's own scopes stay the real boundary, which is why the Stripe entry asks for a restricted key. https://bastion.mgcrea.io
```

### P3 · Tue 22 · loopback rules

Source: README "Security". 462 weighted characters.

```
A local gateway holding every credential you own is reachable from the browser, not just from the machine.

That was CVE-2025-49596, Anthropic's own MCP Inspector: a listener on localhost, no CSRF protection, and a page you visited could reach it.

Bastion binds 127.0.0.1 (not configurable), checks Origin and Host on every request, and refuses a rebound Host with 403 before it looks at the token. The other order would let a 401 confirm the Host was accepted.
```

Self-reply (113):

```
make audit launches the built app and asserts the rules, loopback-only via lsof included: https://github.com/mgcrea/bastion/blob/main/scripts/audit-listener.sh
```

This week's news fits the angle (IBM ContextForge's MCP gateway, CVE-2026-78573, default
credentials) but is left out on purpose. The parent plan says compare, never dunk, and nothing here
needs another vendor's CVE to stand.

### P4 · Wed 23 · the audit log, two posts

Source: README "What the audit log sees, and what it does not". 419 weighted characters.

```
Bastion's audit log is hash chained, and that proves less than it sounds like.

It catches an edited field, a removed record, or corruption from something that was not trying. It does not stop anyone who can write the file, because they can recompute the chain.

A chain also cannot detect its own truncation (a shorter chain is still valid), so the export writes a manifest with each segment's record count and digest.
```

Self-reply (257):

```
Signing the export proves it came from this Mac and was not altered afterwards. It does not prove the log was not curated before it was signed.

The durable log is opt-in, and arguments stay out of it unless you flip a second switch: https://github.com/mgcrea/bastion#what-the-audit-log-sees-and-what-it-does-not
```

### P5 · Thu 24 · measured dialects

Source: README "Status". 383 weighted characters. The one aimed at spec people rather than users.

```
I asked eleven third-party MCP servers for protocol 2026-07-28, a revision none of them support, so each would answer with its own newest.

All eleven said 2025-11-25. Two of them, DBHub and Context7, are built on the 2.0 SDK that knows 2026-07-28 and still negotiate the older one.

Stripe's hosted server negotiated 2025-03-26, two revisions behind the default I had seeded for it.
```

Self-reply (131):

```
The ten remote entries that refuse initialize without a credential are still seeded, not measured. Details: https://github.com/mgcrea/bastion#status
```

### P6 · Mon 28 · the product

Source: README "The problem" and "Licence". 460 weighted characters.

```
What leaks if a .mcp.json leaks should be a revocable loopback token, not a Shopify secret.

Four of my MCP repos kept real credentials in plaintext beside the code, one of them a brokerage refresh token. They are Keychain items now, one set per profile, and the configs point at 127.0.0.1:8720 with a per-client token.

That is Bastion: one process per server for every client on the Mac, writes gated per profile, and every tool call recorded.
```

Self-reply (113):

```
Signed and notarized, source public, $14.99 for every 1.x release with a 30-minute trial: https://bastion.mgcrea.io
```

Media: `apps/website/src/assets/shots/log.png` works here, since it illustrates the shape and quotes
no figure.

## Finding replies

X search reaches back 7 days, so re-run these every Monday with `x_count_recent` first. Target
1k to 20k view posts under 24 hours old, and skip every other vendor's launch post (Sable, Exorails,
TCB, OmaSeal this week: all traps).

| For                | Query                                                                                                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Context cost       | `(mcp OR "mcp servers") ("claude code" OR cursor OR codex) ("too many" OR "context window" OR "tool list" OR tokens OR ".mcp.json") -is:retweet -is:reply lang:en`                                |
| Security           | `(mcp OR "mcp server" OR "mcp servers") ("prompt injection" OR "blast radius" OR "supply chain" OR "tool poisoning" OR localhost OR "dns rebinding" OR "api keys") -is:retweet -is:reply lang:en` |
| Secrets in configs | `("mcp server" OR "mcp servers" OR ".mcp.json") (credentials OR secrets OR plaintext OR "api keys" OR keychain OR leaked) -is:retweet -is:reply lang:en`                                          |

Dropped: `("mcp gateway" OR "mcp proxy" OR "docker mcp" OR "mcp toolkit" OR metamcp)`. This week it
returned listicles, Oracle and SAP press, and competitor launches, with no thread worth answering.

## Measuring it

Baseline above. Each Friday, `x_get_user_posts` for views and replies on P1 to P6, plus the
follower count. Judge against the account's own numbers (50 to 500 views for a post that argues
something), not the parent plan's +300 followers and 50k impressions, which assumed a starting
audience this account does not have. Referrals can be read from the site's Web Analytics beacon,
installed 2026-09-07, by `refererHost` for `t.co`.

## Open decisions

- Whether the Show HN stays on Tue 29 Sep, given its three prerequisites have not started.
- Whether to change the bio ("FullStack Developer - e/acc") to name Bastion and Cupertino. The
  pinned post already does the selling, so this is optional.
- The Stats pane (unreleased) is the obvious P7 once it ships, with a real capture.
