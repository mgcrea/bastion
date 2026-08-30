/**
 * The server list, as the site reads it.
 *
 * GENERATED from the repo-root `servers.json` by `make servers`, and `make
 * servers-check` fails in CI if it has drifted. Do not edit the region below;
 * edit the manifest and rerun.
 *
 * The site makes a claim about this list — "the list is closed", "seven behind a
 * write gate, three read-only" — and a hand-kept copy is exactly how a page ends
 * up counting differently from the app it describes. The counts below are
 * derived here rather than typed, for the same reason.
 *
 * The whole file is in `.oxfmtrc.json`'s `ignorePatterns`, beside `docs/servers.md`
 * and for the same reason: the formatter wraps a long `summary` that the
 * generator emits on one line, so running both leaves the file permanently
 * "drifted" and `make servers-check` fails on a tree nobody touched. The
 * generator is the formatter here.
 */

export interface Server {
  /** The manifest id, which is also the path segment: `/s/<profile>/<id>`. */
  id: string;
  displayName: string;
  summary: string;
  /** The env var that turns writes on, or null when the server has no write path. */
  writeGate: string | null;
  /** The newest protocol revision the server's SDK negotiates. */
  dialect: string;
}

// <generated:servers> generated from servers.json by `make servers` — do not edit by hand
export const SERVERS: Server[] = [
  {
    id: "shopify",
    displayName: "Shopify",
    summary: "Shopify Admin GraphQL API: products, variants, collections, metafields, locations.",
    writeGate: null,
    dialect: "2025-11-25",
  },
  {
    id: "appstore-connect",
    displayName: "App Store Connect",
    summary: "App Store Connect API: apps, versions, builds, TestFlight, listings, analytics, sales.",
    writeGate: "APP_STORE_CONNECT_ALLOW_WRITES",
    dialect: "2025-11-25",
  },
  {
    id: "keycloak",
    displayName: "Keycloak",
    summary: "Keycloak Admin REST API: realms, clients, users, roles, sessions.",
    writeGate: "KEYCLOAK_ALLOW_WRITES",
    dialect: "2025-11-25",
  },
  {
    id: "ovh-api",
    displayName: "OVHcloud",
    summary: "OVHcloud API, focused on Object Storage: containers, objects, policies, regions.",
    writeGate: "OVH_ALLOW_WRITES",
    dialect: "2025-11-25",
  },
  {
    id: "reddit",
    displayName: "Reddit",
    summary: "Reddit API: subreddits, posts, comments, search, and the user's own history.",
    writeGate: "REDDIT_ALLOW_WRITES",
    dialect: "2025-11-25",
  },
  {
    id: "x-api",
    displayName: "X",
    summary: "X (Twitter) API v2: posts, threads, timelines, search, bookmarks, and the Ads API.",
    writeGate: "X_API_ALLOW_WRITES",
    dialect: "2025-11-25",
  },
  {
    id: "tastytrade",
    displayName: "TastyTrade",
    summary: "TastyTrade brokerage API: accounts, positions, balances, quotes, and order entry.",
    writeGate: "TASTYTRADE_ALLOW_TRADING",
    dialect: "2025-11-25",
  },
  {
    id: "boursobank",
    displayName: "BoursoBank",
    summary: "BoursoBank customer API: accounts, transactions, statements, market data.",
    writeGate: "BOURSOBANK_ALLOW_TRADING",
    dialect: "2025-11-25",
  },
  {
    id: "buzzberg",
    displayName: "Buzzberg",
    summary: "Buzzberg market intelligence: speaker calls, timelines and crowd sentiment.",
    writeGate: null,
    dialect: "2025-11-25",
  },
  {
    id: "yahoo-finance",
    displayName: "Yahoo Finance",
    summary: "Yahoo Finance market data: quotes, fundamentals, holders, time series.",
    writeGate: null,
    dialect: "2025-11-25",
  },
];
// </generated:servers>

/** Servers with no mutating tool registered at all. */
export const readOnly = SERVERS.filter((s) => s.writeGate === null);

/** Servers whose writes are off until a profile turns them on. */
export const gated = SERVERS.filter((s) => s.writeGate !== null);
