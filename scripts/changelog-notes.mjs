#!/usr/bin/env node
// One CHANGELOG section, for the two places a release describes itself.
//
// HTML by default, for the Sparkle appcast: Sparkle renders the <description>
// as HTML, and `make appcast` used to slice the raw markdown into it, so every
// user's update dialog showed literal `**` and `- ` bullets. `--markdown` for
// the GitHub release body, which used to be an awk slice of the same file. The
// parser and both renderers live in `lib/changelog.mjs`, shared with the
// generator behind the app's What's New pane so that the three cannot disagree
// about what a bullet is, or about which sections a user never sees.
//
// ## Why the version is an argument
//
// This used to take the FIRST section, which is `[Unreleased]` whenever a tag is
// cut before the heading is retitled: the appcast and the release body would
// both have shipped notes for work that is not in the build. Matching the tagged
// version instead, and exiting non-zero when the section is missing or holds
// nothing a user would see, turns a heading typo (`## [1.1]` against
// `## [1.1.0]`) into a failed release rather than an update dialog with nothing
// in it. Neither caller has a fallback that would paper over it.
//
// What stays here rather than in the library is what is true of these callers
// and not of markdown: which section to take, the guards below, and escaping
// `]]>`, which would otherwise close the Makefile's CDATA early and hand Sparkle
// a malformed feed.
//
//   node scripts/changelog-notes.mjs [--markdown] <version> [CHANGELOG.md]
import { readFileSync } from "node:fs";

import { parse, renderHTML, renderMarkdown } from "./lib/changelog.mjs";

const args = process.argv.slice(2);
const markdown = args.includes("--markdown");
const [version, file = "CHANGELOG.md"] = args.filter((arg) => arg !== "--markdown");
if (!version) {
  console.error("usage: changelog-notes.mjs [--markdown] <version> [CHANGELOG.md]");
  process.exit(2);
}

// Matched on the bracketed version alone, so the ` - <date>` that follows it
// does not have to be known.
const release = parse(readFileSync(file, "utf8")).find((r) => r.version === version);
if (!release) {
  console.error(`${file} has no '## [${version}]' section; the release notes would be empty`);
  process.exit(1);
}

// A section that matched its heading but holds nothing renderable, or only
// `### Internal`, is the same empty dialog reached a different way.
const out = markdown ? renderMarkdown(release) : renderHTML(release);
if (!/\S/.test(out)) {
  console.error(
    `${file} section '## [${version}]' has nothing users would see; the release notes would be empty`,
  );
  process.exit(1);
}

// A `]]>` in the notes would end the CDATA section the Makefile wraps the HTML
// in. Markdown goes to a file, where the sequence means nothing.
process.stdout.write(`${markdown ? out : out.replaceAll("]]>", "]]]]><![CDATA[>")}\n`);
