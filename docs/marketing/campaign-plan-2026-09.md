# Bastion — Awareness Campaign Brief, September 2026 (revised 21 Sep)

**Prepared:** Mon 7 September 2026. **Revised:** Mon 21 September 2026, at the start of what was week 3.
**Window (revised):** Mon 21 Sep → Fri 16 Oct 2026, Show HN moved to **Tue 6 Oct**, readout Fri 16 Oct.
**Budget:** $0 — time only. **Channels:** Hacker News, X (@mgcrea), Reddit, blog (now `mg-crea.com/blog`, see below).
**Inputs:** the competitive brief, the 14 Sep X sub-plan (`docs/marketing/x-campaign-2026-09.md`), the repo at `app-v1.22.0` (18 Sep), the website source, the X API and HN Algolia as of 21 Sep.

---

## 0. What happened in the first two weeks

**Shipped (product).** Bastion went from 1.12.0 to 1.22.0 in eleven days. Launch at login landed in 1.19.0 (16 Sep), which closes the one feature-table row where the free Electron apps beat Bastion; the Gaps section already reflects it. A feedback form and a `/support` page shipped, the site stopped claiming the activity log never touches disk (correct, since the durable audit is opt-in), screenshots were regenerated for the new Stats pane, and a COOP header and 404 noindex went in. A third app, **Armada** (armada.mgcrea.io, "every coding agent you have running, on one screen"), went from first commit to signed 1.0 on 11 Sep and is cross-linked from the Bastion site.

**Shipped (content).** Three essays on `mg-crea.com/blog`, each mirrored as an X Article: *The late software developer* (8 Sep), *The blast radius* (11 Sep), *The input layer* (18 Sep). X results: 14 → 577 → 227 views for the article posts, 8 and 6 replies on the last two, Premium now on the account. Hacker News: 2, 3 and 1 points respectively as plain links; no front page. Followers 123 → 126. The X sub-plan's finding holds: an argument gets hundreds of views, a bare link with a pitch gets single digits (8 and 21 views under two big accounts on 11 Sep; 22 views for the Armada launch post on 19 Sep).

**Not shipped.** Everything the 7 Sep calendar put in week 1 as a blocker: no `/blog` or `/changelog` route on bastion.mgcrea.io, no measurement script, no Post 1 ("What three MCP clients cost your Mac"), no comparison page, no Post 2 (audit log), no Reddit post, no newsletter pitch. The "No container runtime, no Docker Desktop" line is still only on the pricing card, not under the hero. The X sub-plan's six receipt posts (P1–P6, 15–28 Sep) have not started either; the two slots already passed (15 and 17 Sep) were missed. Roundup outreach status is unknown to me; treat as not sent unless you say otherwise.

**Baselines.** Still not captured (Cloudflare referrers, GitHub stars, downloads, Stripe). Without them the readout cannot be written; this is now the first task, not a nice-to-have.

**What this means.** The plan's structure was right and its week-1 load was wrong: it front-loaded site engineering onto the same person who was shipping ten app releases. Meanwhile the thing that did happen, essays on your own domain with an X Article on top, is the only channel that produced readers. The revision below keeps the two arguments (measurement, audit) and the Show HN, drops the bastion-site blog as a prerequisite, and moves every remaining piece onto the surface that already works.

---

## 1. Campaign overview (unchanged in substance)

**Working name:** *One process, on the record.*

**Primary objective (revised dates).** By 16 October, Bastion is listed in at least three of the four roundups that define the category and omit it (heyitworks, mcp.directory, zimaspace, awesomeclaude.ai), and at least one Bastion-authored piece reaches the HN front page (≥100 points).

**Secondary objectives.** The measurement post and the audit post published; one comparison page live; the hero copy change shipped; a captured baseline so the sales push has numbers. `mg-crea.com/blog` is now the publishing surface; a bastion.mgcrea.io blog is out of scope for this campaign. Whether Armada rides along is an open decision (§10).

This is still not a sales campaign.

---

## 2. Target audience — unchanged, one addition

See the 7 Sep version: the multi-client Mac developer (primary), the roundup writers (secondary), platform/security engineers (do not repel). One addition from two weeks of X replies: the questions that actually came in were about **rate limits and running many sessions** (the *Input layer* thread, the quota thread you replied into), not about credentials. That audience overlaps Armada's exactly and Bastion's partially; it is why the Armada decision matters.

---

## 3. Key messages — unchanged, one re-ordering

The five supporting messages stand (memory cost, Keychain items, write gate removes tools from `tools/list`, audit that admits its limits, no Docker / no account / one price). Re-order for the next three weeks: lead with the **write gate** and the **audit log**, because those are the two receipts already drafted in the X sub-plan (P2, P4) and because *The blast radius*, which is about exactly that, is the best-performing thing you have published. The memory measurement stays the HN bet, but it moves to second because it still needs the script.

**What not to say** stands: no "governance", "control plane", "enterprise-grade". Add, from the X evidence: no bare links, no pitches under other people's posts.

---

## 4. Channel strategy — what changes

**Blog: `mg-crea.com/blog`, not bastion.mgcrea.io.** It exists, it has OG tags and a canonical, it is already indexed, and three posts are on it. The measurement post and the audit post go there. The comparison page is the one thing that belongs on the product site, as a single Astro page (`/compare`), not a blog. Drop `/blog` and `/changelog` on the Bastion site from this campaign; the changelog is already served by GitHub releases.

**Hacker News.** Three plain links have scored 1–3 points, which tells you nothing except that essays about your job are not what HN wants from an unknown account. The measurement post is a different kind of submission (a number, a script, a reproducible claim) and remains the bet. The Show HN moves to **Tue 6 Oct**, one week later than planned, gated on three things being live: the comparison page, the audit post, and the screenshots. If any of the three is missing on Mon 5 Oct, the Show HN moves again rather than going out thin. No more plain-link essay submissions until then; they cost nothing but they shape the account's history.

**X.** Follow the 14 Sep sub-plan as written, compressed: P1–P6 in the next eight working days rather than two weeks, one per working day, links in a self-reply, product named last. It is the only X activity that has evidence behind it. Answer every reply on the *Input layer* thread. Do not post another Armada launch post until the Armada decision is made.

**Reddit.** Nothing has gone out and that is fine; Reddit was always the channel with the worst effort-to-evidence ratio here. Keep one post: the measurement thread in r/ClaudeAI and r/cursor the day after its HN submission. Drop the r/macapps "developer of" post unless the HN thread goes well.

**Roundup outreach.** Still the highest-leverage, lowest-effort item and still the primary KPI. If it has not gone out, it goes out this week, before anything else. The kit is three sentences, two screenshots (you have them now), one table row.

---

## 5. Content calendar (revised)

| Week | Content piece | Channel | Notes | Status |
|---|---|---|---|---|
| **Wk 3** (21–25 Sep) | Capture baselines: Cloudflare referrers for bastion.mgcrea.io, GitHub stars, downloads, Stripe, X followers (126) | — | Mon 21. Non-negotiable; the readout depends on it. | Pending |
| Wk 3 | Roundup outreach × 4 (+ awesome-mcp lists) | Earned | Tue 22 at the latest. Screenshots exist since 1.22. | Pending / unknown |
| Wk 3 | Hero line: "No container runtime, no Docker Desktop, no account." under the h1 | Site | 25 words, already written in the website-update plan. | Pending |
| Wk 3 | X receipts P1, P2, P3 (tool listings cost tokens; write gate removes tools; loopback rules) | X | Tue, Wed, Thu 14:00–16:00 Paris. Replies only from the sub-plan's searches. | Pending |
| Wk 3 | Write the measurement script (`scripts/measure-clients.mjs`) and run it on a clean account | Repo | The one engineering task in the campaign. If it slips past Fri 25, the measurement post slips a week and the Show HN does not. | Pending |
| **Wk 4** (28 Sep–2 Oct) | **Post 1: "What three MCP clients actually cost your Mac"** on mg-crea.com/blog | Blog | Mon 28 or Tue 29. Numbers, script, before/after, four competitor tracker links. | Pending |
| Wk 4 | HN plain link of Post 1 | HN | Tue 29 or Wed 30, 14:00–16:00 Paris. Six hours in the thread. | Pending |
| Wk 4 | Reddit thread of Post 1 in r/ClaudeAI, r/cursor | Reddit | Day after HN. Author disclosed, numbers in the body. | Pending |
| Wk 4 | X receipts P4 (audit, 2 posts), P5 (dialects), P6 (what leaks, plus price) + Post 1 launch post | X | P6 last, as the sub-plan says. | Pending |
| Wk 4 | **Post 2: "What a hash-chained audit log on one machine can and cannot prove"** on mg-crea.com/blog | Blog | Thu 1 Oct. Expand P4 into 1,000 words; cite mcp-proxy #224. | Pending |
| Wk 4 | `/compare` page on bastion.mgcrea.io: Bastion vs Docker MCP Toolkit vs MCP Router, one table, gaps column for Bastion | Site | Fri 2 Oct. One page, two competitors; ToolHive can be a row rather than a page. | Pending |
| **Wk 5** (5–9 Oct) | Gate check Mon 5 Oct: comparison page, Post 2, screenshots all live? | — | If not, Show HN → Tue 13 Oct. | Pending |
| Wk 5 | **Show HN: Bastion – run each MCP server once for every client on your Mac** | HN | Tue 6 Oct (fallback Wed 7), 14:00–16:00 Paris. First comment: what, why no Docker, what it does not do, price; screenshots; `/compare` and source linked. Licence offer by email only, never tied to commenting. | Pending |
| Wk 5 | X thread for the Show HN; reply to every mention | X | — | Pending |
| Wk 5 | Follow up with roundups that have not replied, with the HN threads as social proof | Earned | — | Pending |
| **Wk 6** (12–16 Oct) | Readout: KPIs vs baseline, what worked (essays) and what did not (plain links, pitches), decide the sales push and the Armada question | — | Fri 16 Oct, via `/marketing:performance-report`. | Pending |

**Dependencies.** Baselines before anything. Script before Post 1; Post 1 before its HN/Reddit/X. Post 2, `/compare` and screenshots before the Show HN; the gate check on 5 Oct is real. Nothing depends on bastion.mgcrea.io having a blog.

**Load.** About 35–40 hours over four weeks, roughly half the original estimate, because the site engineering is gone and the X copy is already drafted. If it still does not fit beside the release cadence, drop Reddit first, then the comparison page (list the gaps in the Show HN comment instead), never the baselines or the measurement.

---

## 6. Content pieces needed (revised)

| Asset | Type | Priority | When | State |
|---|---|---|---|---|
| Baseline sheet | Internal | Must | Wk 3 | Not started |
| Roundup outreach kit (3 sentences, 2 screenshots, 1 row) | Email/PR | Must | Wk 3 | Screenshots done; kit not sent (?) |
| Hero "no Docker" line | Site copy | Must | Wk 3 | Not started |
| X receipts P1–P6 | Social | Must | Wk 3–4 | Drafted in the X sub-plan |
| Measurement script | Repo | Must | Wk 3 | Not started |
| Post 1, measurement | Blog, ~1,500 words | Must | Wk 4 | Not started |
| Post 2, audit log | Blog, ~1,000 words | Must | Wk 4 | P4 draft exists |
| `/compare` page | Site | Must | Wk 4 | Not started |
| Show HN title + first comment | HN copy | Must | Wk 5 | Not started |
| Reddit measurement thread | Community | Nice | Wk 4 | Not started |
| Demo GIF | Video | Dropped | — | — |
| `/blog`, `/changelog` on bastion site | Site | Dropped | — | — |
| Readout | Internal | Must | Wk 6 | — |

---

## 7. Success metrics (revised dates, targets adjusted)

Primary: ≥3 of 4 roundup listings and ≥1 HN front page (≥100 points) by 16 Oct. Secondary: ≥3,000 referral sessions over the window (Cloudflare, server-side); +150 GitHub stars; downloads and trial starts at 3× the baseline weekly rate around the two HN dates; purchases counted, not targeted. X: two weeks in, follower growth is +3 and the best post is 577 views, so the honest target is +100 followers and 10k impressions, not +300 and 50k.

New leading indicator from the evidence so far: **views per X post by kind**. Articles and arguments: 227–577. Links and pitches: 4–32. If a P-post lands under 100 views, its framing is wrong, not the channel.

Reporting: five lines every Friday; full readout 16 Oct.

---

## 8. Budget — unchanged

$0. Time, roughly 35–40 hours over four weeks (see §5). If cash appears, $200 on a Console.dev or TLDR slot for Post 1; nothing on social ads.

---

## 9. Risks and mitigations (revised)

**The script slips again.** It has slipped once and it is the campaign's only engineering task competing with product releases. Mitigation: time-box it to one afternoon; a `ps`-based sampler that prints RSS and child counts for each client's config is enough, the polish can follow. If it is not done by Fri 25, publish Post 1 with the figures already on the Problem section plus a manual Activity Monitor screenshot, and say so.

**The Show HN goes out thin because the date arrived.** Mitigation: the 5 Oct gate is a rule, not a hope. A Show HN on 13 Oct with the comparison page beats one on 6 Oct without it.

**Armada eats the attention.** A third product launched mid-campaign, with a launch post that got 22 views. Mitigation: decide (§10) rather than drift. Either Armada joins as the "rate limits" story the X audience is already asking about, with its own Show HN two weeks after Bastion's, or it stays quiet until this window closes.

**Plain-link essays keep scoring 1–3 on HN and it gets discouraging.** Mitigation: stop submitting them. The essays are doing their job on X and on your own domain; HN is for the measurement and the Show HN.

**Baselines never get captured and the readout is vibes.** Mitigation: it is the first row of the calendar and it takes an hour.

---

## 10. Next steps and decisions

**This week:** baselines (Mon), roundup emails (Tue), hero line (Tue), P1–P3 on X (Tue–Thu), measurement script (by Fri).

**Decisions that are yours:**

1. **Armada: in or out of this campaign?** In: it answers the question your X audience is actually asking (rate limits, many sessions), it shares the Show HN prerequisites (screenshots, a price, public source) and it could take a second Show HN slot on Tue 20 Oct. Out: it splits a one-person effort three ways and the Bastion KPIs have not moved yet. Recommendation: out until 16 Oct, with one exception: if a P-post about rate limits performs, let Armada be the self-reply link.
2. **Roundup outreach: has any of it gone out?** If yes, say which and the sheet gets updated; if no, it is Tuesday's job.
3. **Show HN date:** 6 Oct with the gate, or 13 Oct without the stress. Either is defensible; what is not is 29 Sep.

No stakeholder approvals needed. Comparison claims about competitors carry a link and a date, as before.

---

*Would you like me to draft the measurement script, the `/compare` table, the Show HN first comment, or the roundup email next?*
