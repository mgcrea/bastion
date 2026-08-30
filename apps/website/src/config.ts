/**
 * Every fact that changes between commits lives here, and nowhere else.
 * Components and the JSON-LD both read from this file, so a step of the build
 * order landing is a single edit.
 *
 * The repo is the authority on all of it. If something here disagrees with the
 * root README's Status table, the tree is right and this file is stale.
 */

import { gated, readOnly, SERVERS } from "./data/servers.ts";

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
] as const;

const spell = (n: number) => SPELLED[n] ?? String(n);
const title = (s: string) => `${s[0]?.toUpperCase() ?? ""}${s.slice(1)}`;

/** "Ten", "Seven", "Three" — however many the manifest turns out to hold. */
export const COUNTS = {
  servers: SERVERS.length,
  gated: gated.length,
  readOnly: readOnly.length,
  serversWord: spell(SERVERS.length),
  serversTitle: title(spell(SERVERS.length)),
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
 * SHIPPED branch has to be true on its own. The app is code-signed for
 * development only and nothing is licensed, both of which the page says in those
 * words rather than leaving to a flag.
 */
export const SHIPPED = false;

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
