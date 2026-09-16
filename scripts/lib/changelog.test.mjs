// Tests for the CHANGELOG parser, its two renderers and `changelog-notes.mjs`.
//
// The failure these guard against is silent in both directions. Three consumers
// read this parse — the Sparkle appcast every user sees when they update, the
// GitHub release body, and the generated What's New pane inside the app — and a
// shape one of them did not anticipate does not crash: it drops a bullet from one
// while the others keep rendering. Nobody notices for a release or two.
//
// The fixture below is not a tidy example. It is every awkward shape the real
// CHANGELOG.md actually contains, each of which broke something on the way in:
//
//   - a `###` group whose prose sits between the heading and the first bullet
//   - a bullet with NO bold headline at all (the `Notes` block in 1.0.0)
//   - a bold headline with a code span inside it
//   - a bullet with a second paragraph after a blank line
//   - a bare number, which the placeholder restoration once ate as an index
//   - an `### Internal` section, which 1.18.0 published to every update dialog
//     and release page because only the pane's generator knew to drop it

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { HIDDEN_SECTIONS, parse, renderHTML, renderMarkdown, userFacing } from "./changelog.mjs";

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

### Internal

- **CI.** Repo-facing prose nobody updating the app should read.

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

describe("userFacing", () => {
  it("drops the hidden sections and keeps the rest in order", () => {
    const [, release] = parse(FIXTURE);
    assert.deepEqual(
      release.groups.map((g) => g.name),
      ["Fixed", "Notes", "Internal"],
    );
    assert.deepEqual(
      userFacing(release).groups.map((g) => g.name),
      ["Fixed", "Notes"],
    );
    assert.ok(HIDDEN_SECTIONS.has("Internal"));
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

  it("leaves the Internal section out", () => {
    assert.doesNotMatch(html, /Internal|Repo-facing/);
  });

  it("does not eat a bare number as a code-span placeholder", () => {
    // The placeholder is NUL-delimited for exactly this reason. With spaces,
    // ` 400 ` read as placeholder 400 and rendered as the string "undefined"
    // in the release notes every user sees.
    assert.match(html, /answers 400 and/);
    assert.doesNotMatch(html, /undefined/);
  });
});

describe("renderMarkdown", () => {
  const [, release] = parse(FIXTURE);

  it("renders the whole section exactly, one line per paragraph", () => {
    assert.equal(
      renderMarkdown(release),
      [
        "### Fixed",
        "Not every fix here is a bullet; this line is the group's own lead.",
        "- **A server that shells out to `npm` could not find it.** The gateway now answers 400 and keeps serving.",
        "  A second paragraph, after a blank line.",
        "- **Plain.** One line only.",
        "### Notes",
        "- No headline on this one at all.",
      ].join("\n\n"),
    );
  });

  it("keeps a release's own lead above its sections", () => {
    const first = parse(FIXTURE).at(-1);
    assert.equal(
      renderMarkdown({ ...first, lead: ["First release."] }).split("\n")[0],
      "First release.",
    );
  });
});

/** Run `body` with `text` written to a throwaway CHANGELOG.md. */
const withFixture = (text, body) => {
  const dir = mkdtempSync(join(tmpdir(), "changelog-notes-"));
  try {
    const file = join(dir, "CHANGELOG.md");
    writeFileSync(file, text);
    body(file);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

describe("changelog-notes.mjs", () => {
  const cli = join(root, "scripts/changelog-notes.mjs");
  const run = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });

  it("takes the section for the version asked for, not the first one", () => {
    // `[Unreleased]` sits on top of the fixture. The script used to take it.
    withFixture(FIXTURE, (file) => {
      const html = run("1.2.0", file);
      assert.equal(html.status, 0, html.stderr);
      assert.match(html.stdout, /could not find it/);
      assert.doesNotMatch(html.stdout, /In flight|Internal/);

      const markdown = run("--markdown", "1.2.0", file);
      assert.equal(markdown.status, 0, markdown.stderr);
      assert.match(markdown.stdout, /^### Fixed$/m);
      assert.doesNotMatch(markdown.stdout, /In flight|Internal|<h3>/);
    });
  });

  it("fails on a version with no section", () => {
    withFixture(FIXTURE, (file) => {
      const result = run("1.1.0", file);
      assert.equal(result.status, 1);
      assert.equal(result.stdout, "");
    });
  });

  it("fails on a section that holds only what users never see", () => {
    const internalOnly = "## [2.0.0] - 2026-05-01\n\n### Internal\n\n- **CI.** Only this.\n";
    withFixture(internalOnly, (file) => {
      assert.equal(run("2.0.0", file).status, 1);
      assert.equal(run("--markdown", "2.0.0", file).status, 1);
    });
  });

  it("fails without a version", () => {
    assert.equal(run().status, 2);
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

  it("keeps Internal out of both renderings of a release that has one", () => {
    const release = releases.find((r) => r.groups.some((g) => g.name === "Internal"));
    assert.ok(release, "no release with an Internal section left to check against");
    assert.doesNotMatch(renderHTML(release), /<h3>Internal<\/h3>/);
    assert.doesNotMatch(renderMarkdown(release), /^### Internal$/m);
  });

  it("renders the top section to HTML with no markdown left over", () => {
    const html = renderHTML(releases[0]);
    assert.doesNotMatch(html, /\*\*/, "bold markers survived into the appcast");
    assert.doesNotMatch(html, /^- /m, "a literal bullet survived into the appcast");
    assert.doesNotMatch(html, /undefined/);
  });
});
