// Tests for the CHANGELOG parser and the appcast's HTML renderer.
//
// The failure these guard against is silent in both directions. Two consumers
// read this parse — the Sparkle appcast every user sees when they update, and
// the generated What's New pane inside the app — and a shape neither anticipated
// does not crash: it drops a bullet from one of them while the other keeps
// rendering. Nobody notices for a release or two.
//
// The fixture below is not a tidy example. It is every awkward shape the real
// CHANGELOG.md actually contains, each of which broke something on the way in:
//
//   - a `###` group whose prose sits between the heading and the first bullet
//   - a bullet with NO bold headline at all (the `Notes` block in 1.0.0)
//   - a bold headline with a code span inside it
//   - a bullet with a second paragraph after a blank line
//   - a bare number, which the placeholder restoration once ate as an index

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { parse, renderHTML } from "./changelog.mjs";

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));

const FIXTURE = `# Changelog

Intro prose that belongs to no release.

## [Unreleased]

### Changed

- **Something.** In flight.

## [1.2.0] - 2026-03-04

### Fixed

Not every fix here is a bullet; this line is the group's own lead.

- **A server that shells out to \`npm\` could not find it.** The gateway now
  answers 400 and keeps serving.

  A second paragraph, after a blank line.

- **Plain.** One line only.

### Notes

- No headline on this one at all.

## [1.0.0] - 2026-01-31

### Added

- **First.** It shipped.
`;

describe("parse", () => {
  const releases = parse(FIXTURE);

  it("reads every section, newest first, and skips the file's intro", () => {
    assert.deepEqual(
      releases.map((r) => r.version),
      ["Unreleased", "1.2.0", "1.0.0"],
    );
    assert.equal(releases[0].unreleased, true);
    assert.equal(releases[1].unreleased, false);
    assert.equal(releases[1].date, "2026-03-04");
    assert.equal(releases[0].date, "");
  });

  it("keeps a group's lead prose", () => {
    const fixed = releases[1].groups[0];
    assert.equal(fixed.name, "Fixed");
    assert.deepEqual(fixed.lead, [
      "Not every fix here is a bullet; this line is the group's own lead.",
    ]);
  });

  it("splits a bold headline off, code span and all", () => {
    const [first] = releases[1].groups[0].entries;
    assert.equal(first.headline, "A server that shells out to `npm` could not find it.");
    assert.deepEqual(first.body, [
      "The gateway now answers 400 and keeps serving.",
      "A second paragraph, after a blank line.",
    ]);
  });

  it("joins continuation lines with a single space", () => {
    const [first] = releases[1].groups[0].entries;
    assert.equal(
      first.paragraphs[0],
      "**A server that shells out to `npm` could not find it.** The gateway now answers 400 and keeps serving.",
    );
  });

  it("allows a bullet with no headline", () => {
    const [note] = releases[1].groups[1].entries;
    assert.equal(note.headline, null);
    assert.deepEqual(note.body, ["No headline on this one at all."]);
  });
});

describe("renderHTML", () => {
  const [, release] = parse(FIXTURE);
  const html = renderHTML(release);

  it("renders the whole section exactly", () => {
    assert.equal(
      html,
      [
        "<h3>Fixed</h3>",
        "<p>Not every fix here is a bullet; this line is the group's own lead.</p>",
        "<ul>",
        "<li><p><strong>A server that shells out to <code>npm</code> could not find it.</strong> " +
          "The gateway now answers 400 and keeps serving.</p>" +
          "<p>A second paragraph, after a blank line.</p></li>",
        "<li><p><strong>Plain.</strong> One line only.</p></li>",
        "</ul>",
        "<h3>Notes</h3>",
        "<ul>",
        "<li><p>No headline on this one at all.</p></li>",
        "</ul>",
      ].join("\n"),
    );
  });

  it("does not eat a bare number as a code-span placeholder", () => {
    // The placeholder is NUL-delimited for exactly this reason. With spaces,
    // ` 400 ` read as placeholder 400 and rendered as the string "undefined"
    // in the release notes every user sees.
    assert.match(html, /answers 400 and/);
    assert.doesNotMatch(html, /undefined/);
  });
});

describe("the real CHANGELOG.md", () => {
  const releases = parse(readFileSync(join(root, "CHANGELOG.md"), "utf8"));

  it("parses into dated releases with entries", () => {
    assert.ok(releases.length > 5);
    const dated = releases.filter((r) => !r.unreleased);
    for (const release of dated) {
      assert.match(release.version, /^\d+\.\d+\.\d+$/);
      assert.match(release.date, /^\d{4}-\d{2}-\d{2}$/);
      assert.ok(release.groups.length > 0, `${release.version} has no sections`);
    }
  });

  it("renders the top section to HTML with no markdown left over", () => {
    const html = renderHTML(releases[0]);
    assert.doesNotMatch(html, /\*\*/, "bold markers survived into the appcast");
    assert.doesNotMatch(html, /^- /m, "a literal bullet survived into the appcast");
    assert.doesNotMatch(html, /undefined/);
  });
});
