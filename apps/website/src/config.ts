/**
 * Every fact that changes between commits lives here, and nowhere else.
 * Components and the JSON-LD both read from this file, so a step of the build
 * order landing is a single edit.
 *
 * The repo is the authority on all of it. If something here disagrees with the
 * root README's Status table, the tree is right and this file is stale.
 */

import {
  children,
  gated,
  ownChildren,
  readOnly,
  remote,
  SERVERS,
  thirdPartyChildren,
} from "./data/servers.ts";

export const SITE_DOMAIN = "bastion.mgcrea.io";
export const SITE_URL = `https://${SITE_DOMAIN}`;

export const APP_NAME = "Bastion";
export const BUNDLE_ID = "io.mgcrea.bastion";

export const REPO_URL = "https://github.com/mgcrea/bastion";

export const DOCS = {
  servers: `${REPO_URL}/blob/main/docs/servers.md`,
  manifest: `${REPO_URL}/blob/main/servers.json`,
  audit: `${REPO_URL}/blob/main/scripts/audit-listener.sh`,
  readme: `${REPO_URL}#readme`,
  licensing: `${REPO_URL}/blob/main/docs/licensing.md`,
} as const;

/**
 * The account X attributes the card to. Both `twitter:site` (the publisher) and
 * `twitter:creator` (the author) are the same handle here, because they are the
 * same person — splitting them would be a fiction.
 */
export const X_HANDLE = "@mgcrea";

/**
 * Small counts are spelled out; a digit mid-sentence reads as a spec sheet.
 * Exported because headings need it too — the Servers heading opens with the
 * count, and a literal "Ten" there is exactly the drift this file prevents.
 *
 * Padded well past the current count on purpose: a list that ends at today's
 * number fails silently on the next server, and the fallback is `String(n)` —
 * which would put the spec-sheet digit back in the one place the rule is about.
 */
export const SPELLED = [
  "no",
  "one",
  "two",
  "three",
  "four",
  "five",
  "six",
  "seven",
  "eight",
  "nine",
  "ten",
  "eleven",
  "twelve",
  "thirteen",
  "fourteen",
  "fifteen",
  "sixteen",
  "seventeen",
  "eighteen",
  "nineteen",
  "twenty",
  "twenty-one",
  "twenty-two",
  "twenty-three",
  "twenty-four",
  "twenty-five",
  "twenty-six",
  "twenty-seven",
  "twenty-eight",
  "twenty-nine",
  "thirty",
] as const;

const spell = (n: number) => SPELLED[n] ?? String(n);
const title = (s: string) => `${s[0]?.toUpperCase() ?? ""}${s.slice(1)}`;

/** "Ten", "Seven", "Three" — however many the manifest turns out to hold. */
export const COUNTS = {
  servers: SERVERS.length,
  children: children.length,
  ownChildren: ownChildren.length,
  thirdPartyChildren: thirdPartyChildren.length,
  remote: remote.length,
  gated: gated.length,
  readOnly: readOnly.length,
  serversWord: spell(SERVERS.length),
  serversTitle: title(spell(SERVERS.length)),
  childrenWord: spell(children.length),
  ownChildrenWord: spell(ownChildren.length),
  thirdPartyChildrenWord: spell(thirdPartyChildren.length),
  remoteWord: spell(remote.length),
  gatedWord: spell(gated.length),
  readOnlyWord: spell(readOnly.length),
} as const;

/**
 * The gateway's loopback address, and the shape of a server URL. Quoted on the
 * page in three places, so it is one constant — `Gateway.swift` is the
 * authority on the port.
 */
export const GATEWAY = {
  host: "127.0.0.1",
  port: 8720,
  get origin() {
    return `http://${this.host}:${this.port}`;
  },
  /** The path a client points at. `<profile>` and `<server>` are placeholders. */
  path: "/s/<profile>/<server>",
} as const;

/**
 * The protocol revisions Bastion serves, and the one its children speak.
 *
 * `modern` and `legacy` are the two eras of the gateway's own dialect layer.
 * `children` is a measured fact, not a pin: the manifest said 2025-06-18 until a
 * live handshake was run against one of the servers, which is why the number
 * lives beside that sentence on the page rather than on its own.
 */
export const DIALECT = {
  modern: "2026-07-28",
  legacy: "initialize",
  children: "2025-11-25",
  conformanceChecks: 24,
} as const;

/**
 * False until there is something to download.
 *
 * It gates the CTA, and it does not gate everything: any string outside a
 * SHIPPED branch has to be true on its own.
 *
 * True as of 1.0.0 — signed, notarized, and published as a GitHub release. The
 * two sentences it used to guard, about a development-only signature and an
 * unsettled licence, are gone rather than hidden behind the flag: both are now
 * false, and a flag is not the place to retire a claim.
 */
export const SHIPPED = true;

/**
 * The price, as charged. Two currencies, both named explicitly on the Stripe
 * price via `currency_options` — never one converted from the other.
 *
 * This page quoted euro alone until the price carried a dollar figure, because
 * quoting a currency the checkout does not charge is the kind of small lie that
 * becomes a support thread. Both are now set on `price_1UAVXcFQJry8F0HM4eliIHoy`,
 * so both can be quoted, and the number here is `unit_amount` in each case.
 *
 * USD leads because most of the audience is there. EUR is named rather than left
 * to conversion for two reasons. Stripe's Adaptive Pricing only converts *out
 * of* a settlement currency, and this account settles in EUR alone, so a
 * USD-only price would put an FX conversion on this side of every sale; naming
 * both keeps that cost in the presented rate. And EU consumer law wants a
 * VAT-inclusive total shown up front, which a figure converted at checkout
 * cannot promise in advance.
 *
 * So the two numbers are not equal and are not meant to be: the account's tax
 * default is `inferred_by_currency`, which resolves USD tax-exclusive and EUR
 * VAT-inclusive — the ordinary convention on each side. `Pricing.astro` has to
 * show both rather than pick one.
 *
 * One price, one major version, every Mac. 2.0 is a new purchase; nothing here
 * promises an upgrade discount, because that decision has not been made and a
 * marketing page is a bad place to make it by accident.
 */
export const PRICE = {
  /**
   * The display form. `amount` is the same number split for structured data:
   * Schema.org's `Offer` wants a bare decimal and a currency code, and a
   * `$14.99` in `price` is a validation error rather than a formatting quirk —
   * so it is split here rather than parsed back out at the call site.
   */
  price: "$14.99",
  amount: "14.99",
  currency: "USD",
  /** Shown alongside, VAT included, as an EU buyer is quoted and charged. */
  eur: { price: "€14.99", amount: "14.99", currency: "EUR" },
  covers: "every 1.x release, on every Mac you own",
  refund: "Thirty days, full refund, no reason needed",
} as const;

/**
 * The evaluation window, and the two properties that make it worth describing
 * rather than just offering.
 *
 * `Trial.swift` is the authority on both. The duration is a constant there, and
 * "full function" is not marketing: every server relays and every write gate
 * obeys its own switch, because a crippled demo answers the wrong question. The
 * thing being evaluated is whether this works on this Mac against these
 * servers, and a degraded mode cannot answer that.
 *
 * `minutes` is separate from `sentence` so a count never has to be read out of
 * prose — see the rule at the top of this file.
 */
export const TRIAL = {
  minutes: 30,
  get sentence() {
    return `A ${this.minutes}-minute trial runs the whole app, not a crippled version of it.`;
  },
} as const;

/**
 * The shipped version.
 *
 * Hand-kept against `MARKETING_VERSION` in apps/apple/Bastion.xcodeproj and the
 * top of CHANGELOG.md. It appears in the JSON-LD beside `downloadUrl`, and it
 * is a claim about a build that exists — so it moves in the release commit, not
 * before it. Nothing enforces the mirror.
 */
export const APP_VERSION = "1.6.0";

/**
 * The MCP clients Bastion can wire in one click.
 *
 * `apps/apple/Bastion/ClientWiring.swift` is the authority; this is the copy the
 * page reads, and the two are kept in step by hand. Naming them matters more
 * than it looks: "works with your MCP client" is what every gateway claims, and
 * the question a visitor actually has is whether it knows about the one they
 * use.
 *
 * Codex is one entry and three surfaces — ChatGPT, the Codex CLI and the IDE
 * extension share a single TOML config, which is why it is spliced rather than
 * re-serialised like the JSON six.
 */
export const CLIENTS = [
  { name: "Claude Code", config: "~/.claude.json" },
  { name: "Claude Desktop", config: "claude_desktop_config.json", viaBridge: true },
  { name: "VS Code", config: "User/mcp.json" },
  { name: "Cursor", config: "~/.cursor/mcp.json" },
  { name: "LM Studio", config: "~/.lmstudio/mcp.json", viaBridge: true },
  { name: "Windsurf", config: "windsurf/mcp_config.json", viaBridge: true },
  { name: "ChatGPT & Codex", config: "~/.codex/config.toml" },
] as const;

/** "Claude Code, Claude Desktop, VS Code, Cursor, LM Studio, Windsurf and ChatGPT & Codex". */
export const clientList = (() => {
  const names = CLIENTS.map((c) => c.name);
  return names.slice(0, -1).join(", ") + " and " + names[names.length - 1];
})();

/** macOS 26 or later: the icon is an Icon Composer bundle, which nothing older renders. */
export const REQUIRES = "macOS 26 or later";

/**
 * The og:image card. `pnpm icons` bakes these two lines into `og-image.png`, so
 * editing them here is only half the change — re-run it, or the picture and the
 * page disagree.
 *
 * They deliberately do not repeat the page title. X renders og:title and
 * og:description as text beneath the image, so a card that restates the title
 * spends its one visual asset saying something already on screen. The title
 * carries the promise; these carry the specifics it leaves out — what the thing
 * actually is, and what state it is in.
 *
 * `composeCard` does NOT fit text: both lines are a fixed size, centred, with no
 * measuring and no wrap, so a line that outgrows 1200px is silently clipped at
 * both ends in a picture nothing in CI looks at. Keep the headline short.
 *
 * `alt` is the accessible description X and Mastodon both expose, capped at 420
 * characters. It describes the picture, not the product.
 */
export const SOCIAL_CARD = {
  headline: "One supervised process per profile, not one per editor",
  // Not a server count any more. It was `${COUNTS.serversTitle} servers` while
  // the list was closed and that was the claim; now the number describes a
  // catalog you install from, and a social card is the last place to explain a
  // distinction. What the app does is the same either way.
  subhead: "Bring your own servers · credentials in the Keychain · every call recorded",
  alt: "The Bastion icon — a curtain wall standing on a dusk ridge — beside the word Bastion, above the line “One supervised process per profile, not one per editor”, and “Bring your own servers · credentials in the Keychain · every call recorded”.",
  /**
   * The card's ground, in appshot's angle convention (degrees CLOCKWISE with y
   * DOWN, so 90 runs top to bottom). NOT the CSS convention `design/colors.json`
   * uses for `plate` and `wash`; see the note on `gradientAxis` in
   * scripts/lib/lockup.mjs. It is the page's own background, ramped, so the card
   * and the site cannot quote different grounds at each other.
   */
  ground: {
    angle: 90,
    stops: [
      { offset: 0, color: "#15161b" },
      { offset: 1, color: "#08090b" },
    ],
  },
  width: 1200,
  height: 630,
} as const;

/**
 * The sibling app by the same studio, cross-linked from the homepage and the
 * footer. One constant feeds both, so the name, the URL and the icon cannot
 * drift between the two placements — which is the failure the r2/d1 pair has,
 * where the same URL is typed into two files.
 *
 * There is no App Store URL and there is not going to be one: neither app is on
 * the store. Both sell through `/buy` and ship the build from GitHub.
 *
 * The pitch deliberately carries no surface count. Cupertino derives that from
 * its own `data/surfaces.ts`; a number typed out over here would be wrong the
 * day the next surface lands, in the one sentence on this site that describes a
 * product this site cannot see.
 *
 * It also does not claim the two interoperate. Cupertino's servers are wired to
 * clients by Cupertino's own app, nothing in either repo documents running them
 * under Bastion, and a cross-promo card is the worst possible place to invent an
 * integration.
 */
export const SIBLING_APP = {
  name: "Cupertino",
  tagline: "Your Apple apps, as MCP servers.",
  pitch:
    "Bastion supervises the servers you bring it. Cupertino is a set of them — Mail, Notes, Calendar, Messages and the rest of the Apple apps already on your Mac — behind a single Full Disk Access grant, held by a signed menu-bar app you can watch.",
  url: "https://cupertino.mgcrea.io",
  repo: "https://github.com/mgcrea/cupertino",
  /**
   * Cupertino's own `public/app-icon.svg`, copied into this site's `public/apps/`.
   *
   * Copied rather than hotlinked because astro.config.mjs sets `img-src 'self'
   * data:`, so a cross-origin image is blocked with nothing on screen and
   * nothing in the build log. It sits under `public/apps/` rather than the
   * public root to keep a hand-copied one-off visibly apart from the three
   * outputs `pnpm icons` writes — and nothing keeps this copy fresh, because
   * that script only ever generates Bastion's own mark.
   */
  icon: "/apps/cupertino.svg",
} as const;

/**
 * The "More apps" column in the footer.
 *
 * Three, not nine. Every one of these sites is a subdomain of `mgcrea.io`, and a
 * full mesh between all of them would read as a link farm rather than a
 * recommendation — so this is the short list a Bastion reader plausibly
 * also wants. Separate from `SIBLING_APP` above, which is the one app the
 * homepage gives a card of its own.
 */
export const FOOTER_APPS = [
  {
    name: "Cupertino",
    url: "https://cupertino.mgcrea.io",
    blurb: "Your Apple apps as MCP servers, behind one Full Disk Access grant.",
  },
  {
    name: "DevPulse",
    url: "https://dev-pulse.mgcrea.io",
    blurb: "A release radar for the repos you depend on, grouped by risk.",
  },
  {
    name: "R2Explorer",
    url: "https://r2-explorer.mgcrea.io",
    blurb: "Browse and manage Cloudflare R2 and S3-compatible storage natively.",
  },
] as const;
