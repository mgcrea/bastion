// CHANGELOG.md, parsed once.
//
// Three things read this file and they must not disagree about it: the Sparkle
// appcast, which renders the tagged version's section as HTML at release time,
// the GitHub release body, which is the same section as markdown, and the app's
// What's New pane, which is generated from the last few sections at build time.
// Parsers over one hand-written file drift the first time somebody writes a
// bullet in a shape one of them did not anticipate, and the failure is silent in
// both directions — the appcast keeps rendering while the pane quietly drops a
// bullet. So there is one parser, and `renderHTML` below is the appcast's
// renderer moved here verbatim, changed since only to leave out
// `HIDDEN_SECTIONS`.
//
// The sections users never see are decided here too, for the same reason.
// `HIDDEN_SECTIONS` used to live in the pane's generator alone, so the pane left
// `### Internal` out while the appcast and the release body, which had no such
// list, published it: Bastion 1.18.0 went out with its `### Internal` notes in
// every update dialog and on its release page.
//
// `renderHTML` reads `entry.paragraphs` and nothing else. That is the whole
// reason entries carry their raw paragraphs alongside the `headline`/`body`
// split the Swift generator wants: the HTML path never sees the split, so
// changing how the split works cannot move a byte of the appcast.

/**
 * One bullet.
 *
 * `paragraphs` is what the source said, with continuation lines joined by a
 * single space — the shape the HTML renderer has always emitted. `headline` is
 * the leading `**…**` span with its asterisks removed, or null: seven bullets in
 * this file have no headline at all (the `Notes` block in 1.0.0), so a required
 * headline would be a lie about the format.
 *
 * @typedef {{ paragraphs: string[], headline: string | null, body: string[] }} Entry
 */

/**
 * One `### Added` / `### Fixed` block.
 *
 * `lead` is the prose that can sit between the heading and the first bullet.
 * There is exactly one in the file today and it is easy to forget it exists;
 * dropping it silently shortens the release notes every user reads.
 *
 * @typedef {{ name: string, lead: string[], entries: Entry[] }} Group
 */

/** @typedef {{ version: string, date: string, unreleased: boolean, lead: string[], groups: Group[] }} Release */

/** The leading `**…**`, non-greedy so a headline containing a code span still ends at its own close. */
const HEADLINE = /^\*\*(.+?)\*\*\s*/;

/**
 * Sections that exist for the repository rather than for the user.
 *
 * Every renderer that faces a user goes through `userFacing`, so adding a name
 * here removes it from the appcast, the release body and the pane at once.
 */
export const HIDDEN_SECTIONS = new Set(["Internal"]);

/**
 * A release with its hidden sections removed. Empty groups are kept: whether one
 * is worth a heading is each renderer's own decision, and `renderHTML` has always
 * emitted it.
 *
 * @param {Release} release
 * @returns {Release}
 */
export const userFacing = (release) => ({
  ...release,
  groups: release.groups.filter((group) => !HIDDEN_SECTIONS.has(group.name)),
});

/**
 * Every `## ` section, newest first.
 *
 * @param {string} markdown
 * @returns {Release[]}
 */
export const parse = (markdown) => {
  const lines = markdown.split("\n");
  /** @type {Release[]} */
  const releases = [];

  /** @type {Release | null} */
  let release = null;
  /** @type {Group | null} */
  let group = null;
  /** @type {string[] | null} */
  let bullet = null; // the paragraphs of the bullet being collected
  /** @type {string[]} */
  let paragraph = [];

  const flushParagraph = () => {
    if (bullet && paragraph.length) {
      bullet.push(paragraph.join(" "));
      paragraph = [];
    }
  };
  const flushBullet = () => {
    if (!bullet) return;
    flushParagraph();
    const paragraphs = bullet;
    bullet = null;
    const first = paragraphs[0] ?? "";
    const match = HEADLINE.exec(first);
    const rest = match ? first.slice(match[0].length) : first;
    group?.entries.push({
      paragraphs,
      headline: match ? match[1] : null,
      body: [rest, ...paragraphs.slice(1)].filter((p) => p !== ""),
    });
  };

  for (const raw of lines) {
    const line = raw.trimEnd();

    if (line.startsWith("## ")) {
      flushBullet();
      // `## [1.13.0] - 2026-09-07`, or `## [Unreleased]` with no date.
      const heading = line.slice(3).trim();
      const version = /^\[([^\]]+)\]/.exec(heading)?.[1] ?? heading;
      const date = /-\s*(\d{4}-\d{2}-\d{2})\s*$/.exec(heading)?.[1] ?? "";
      release = {
        version,
        date,
        unreleased: version.toLowerCase() === "unreleased",
        lead: [],
        groups: [],
      };
      releases.push(release);
      group = null;
      continue;
    }

    // Everything above the first `## ` is the file's own intro. Not a release.
    if (!release) continue;

    if (line.startsWith("### ")) {
      flushBullet();
      group = { name: line.slice(4).trim(), lead: [], entries: [] };
      release.groups.push(group);
    } else if (line.startsWith("- ")) {
      flushBullet();
      bullet = [];
      paragraph = [line.slice(2)];
    } else if (line === "") {
      flushParagraph();
    } else if (bullet) {
      paragraph.push(line.trim());
    } else {
      // Prose outside any bullet. One paragraph per line, deliberately: that is
      // what the HTML renderer has always emitted, and joining them here would
      // change the appcast.
      (group ?? release).lead.push(line.trim());
    }
  }
  flushBullet();

  return releases;
};

// ─── HTML, for the appcast ────────────────────────────────────────────────────
//
// Moved here from `changelog-notes.mjs` character for character, and since then
// changed in one way: hidden sections are left out. Sparkle renders
// the <description> as HTML, and the release path used to slice raw markdown
// into it: every user's update dialog showed literal `**` and `- ` bullets. This
// is the smallest renderer that covers what the CHANGELOG actually uses.

const escape = (text) =>
  text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/**
 * Inline markdown. Code spans are lifted out first so nothing inside is touched.
 *
 * The placeholder is delimited by NUL rather than by spaces, and that is not a
 * flourish: ` 400 ` is a bare number the restoration pass would happily read as
 * placeholder 400 and replace with `undefined`. NUL cannot occur in the source.
 */
export const inline = (text) => {
  const codes = [];
  let out = escape(text).replace(/`([^`]+)`/g, (_, code) => {
    codes.push(`<code>${code}</code>`);
    return `\0${codes.length - 1}\0`;
  });
  out = out
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[\s(])_([^_]+)_(?=[\s.,;:)]|$)/g, "$1<em>$2</em>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');
  return out.replace(/\0(\d+)\0/g, (_, index) => codes[Number(index)]);
};

/**
 * One release as the HTML Sparkle shows, without its hidden sections.
 *
 * Reads `entry.paragraphs`, never `headline`/`body`, so the split those two
 * carry cannot move the output.
 *
 * @param {Release} release
 * @returns {string}
 */
export const renderHTML = (release) => {
  const html = [];
  for (const text of release.lead) html.push(`<p>${inline(text)}</p>`);
  for (const group of userFacing(release).groups) {
    html.push(`<h3>${inline(group.name)}</h3>`);
    for (const text of group.lead) html.push(`<p>${inline(text)}</p>`);
    if (group.entries.length === 0) continue;
    html.push("<ul>");
    for (const entry of group.entries) {
      html.push(`<li>${entry.paragraphs.map((p) => `<p>${inline(p)}</p>`).join("")}</li>`);
    }
    html.push("</ul>");
  }
  return html.join("\n");
};

// ─── markdown, for the GitHub release body ────────────────────────────────────
//
// The release body used to be an awk slice of the first `## ` section, which is
// wrong twice: the first section is `[Unreleased]` whenever a tag is cut before
// the heading is retitled, and a slice cannot leave a section out. Rendering
// from the parse fixes both, at the cost of the source's line wrapping, which
// GitHub would have shown as hard breaks anyway.

/**
 * One release as the markdown of its GitHub release, without its hidden
 * sections. Each paragraph is one line, and bullets keep the blank line between
 * them that the CHANGELOG itself uses.
 *
 * @param {Release} release
 * @returns {string}
 */
export const renderMarkdown = (release) => {
  const blocks = [...release.lead];
  for (const group of userFacing(release).groups) {
    blocks.push(`### ${group.name}`, ...group.lead);
    for (const entry of group.entries) {
      blocks.push(entry.paragraphs.map((p, i) => (i === 0 ? `- ${p}` : `  ${p}`)).join("\n\n"));
    }
  }
  return blocks.join("\n\n");
};
