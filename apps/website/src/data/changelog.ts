/**
 * The releases, for /changelog and /changelog/<version>.
 *
 * Read from the repository's CHANGELOG.md at build time — `?raw`, as the terms
 * page reads the EULA, and for the reason given there — and through the same
 * parser the appcast, the GitHub release body and the app's What's New pane
 * use, so the four cannot disagree about what a release said. `### Internal`
 * is left out here as it is there, through the same `userFacing`: it is about
 * CI and the licence API, and these pages are for people deciding whether to
 * update.
 *
 * A release's social card exists only if `pnpm cards` rendered one, which it
 * does for every release with a summary. The manifest it writes is what says
 * so; a page for a release without one falls back to the site card.
 */
import changelog from "../../../../CHANGELOG.md?raw";
import {
  inline,
  parse,
  plain,
  postText,
  renderHTML,
  userFacing,
} from "../../../../scripts/lib/changelog.mjs";
import { APP_VERSION } from "../config";
import cards from "./release-cards.json";

export interface Release {
  version: string;
  date: string;
  /** "September 26, 2026", fixed to UTC so the build machine's zone cannot move it. */
  longDate: string;
  /** The page every share links to. */
  path: string;
  /** The `**Title.**` lead and its sentence, when the release has one. */
  summary: { title: string; description: string; post: string } | null;
  /** The notes as HTML, without `### Internal`. */
  html: string;
  /** Each visible entry's bold headline, plain — the stand-in for a summary. */
  highlights: string[];
  /** The same headlines as inline HTML, so a tool name keeps its code styling. */
  highlightsHtml: string[];
  /** `/changelog/<version>.png`, or null where no card was rendered. */
  card: string | null;
}

const longDate = (iso: string) =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });

/**
 * Newest first, released only. `## [Unreleased]` is in the file between
 * releases and is not something to link to.
 */
export const RELEASES: Release[] = parse(changelog)
  .filter((release) => !release.unreleased)
  .map((release) => {
    const headlines = userFacing(release)
      .groups.flatMap((group) => group.entries)
      .map((entry) => entry.headline)
      .filter((headline): headline is string => headline !== null);
    return {
      version: release.version,
      date: release.date,
      longDate: longDate(release.date),
      path: `/changelog/${release.version}/`,
      summary: release.summary
        ? {
            title: plain(release.summary.title),
            description: plain(release.summary.description),
            post: postText(release.summary),
          }
        : null,
      // The lead's first paragraph IS the summary, and the page sets it as the
      // headline and standfirst. Rendering it again in the notes would say it twice.
      html: renderHTML(release.summary ? { ...release, lead: release.lead.slice(1) } : release),
      highlights: headlines.map(plain),
      highlightsHtml: headlines.map(inline),
      card: release.version in cards ? `/changelog/${release.version}.png` : null,
    };
  });

/*
 * The nav's version badge links to `/changelog/${APP_VERSION}/`, and both are
 * typed by hand on release day — APP_VERSION in config.ts, the heading in
 * CHANGELOG.md. CI already holds APP_VERSION to the pbxproj; this holds it to
 * the changelog, so a release commit that bumps one and not the other fails the
 * build instead of shipping a badge that 404s on every page.
 */
if (!RELEASES.some((release) => release.version === APP_VERSION)) {
  throw new Error(
    `config.ts says APP_VERSION ${APP_VERSION}, and CHANGELOG.md has no released section for it`,
  );
}
