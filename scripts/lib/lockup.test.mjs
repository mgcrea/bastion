// Tests for the lockup composition.
//
// The failure this guards against is not a crash — it is a banner that renders,
// looks roughly right, and carries an older mark than the app ships. That is a
// real incident next door: cupertino's lockup was hand-drawn beside the mark and
// its hills had been a single simplified path for two revisions before anyone
// noticed, because nothing asserted the artwork's provenance.
//
// So the assertions are about inheritance rather than appearance: the mark's
// shapes have to arrive from the icon file unmodified, and anything that would
// let them arrive mangled has to throw instead. Appearance is checked by looking
// at the render, which no test can do for you.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { composeCard, composeLockup, LOCKUP, SOCIAL_CARD, wordmarkWidth } from "./lockup.mjs";

const design = join(dirname(dirname(dirname(fileURLToPath(import.meta.url)))), "design");
const icon = readFileSync(join(design, "bastion-icon.svg"), "utf8");
const palette = JSON.parse(readFileSync(join(design, "colors.json"), "utf8"));

/**
 * The four shapes of design/bastion-mark.svg, character for character. If one of
 * these ever needs updating here, the lockup has stopped inheriting — which is
 * the only thing these tests exist to catch.
 */
const MARK_SHAPES = [
  "M-39.7 882.8 Q512 609.1 1063.7 882.8 V1063.7 H-39.7 Z",
  "M-39.7 935.7 Q282.5 829.8 582.6 918.1 T1121.1 891.6 V1063.7 H-39.7 Z",
  "M247.2 776.8 L194.2 485.5 L512 194.2 L829.8 485.5 L776.8 776.8",
  "M512 423.7 L662.1 547.3 L688.6 706.2 L335.4 706.2 L361.9 547.3 Z",
];

const CARD_COPY = { headline: "A headline", subhead: "A subhead", ground: "#0b0c0f" };

describe("the mark the compositions read", () => {
  it("is the geometry design/README.md documents", () => {
    const mark = readFileSync(join(design, "bastion-mark.svg"), "utf8");
    for (const shape of MARK_SHAPES) assert.ok(mark.includes(shape), `missing ${shape}`);
    // The one number that is chosen rather than transcribed. `make icon` has no
    // opinion on it, so this is the only place it is written down in code.
    assert.match(mark, /stroke-width="48\.6"/);
  });
});

describe("composeLockup", () => {
  const svg = composeLockup(icon, palette);

  it("inherits the mark's geometry verbatim from the icon", () => {
    for (const shape of MARK_SHAPES) assert.ok(svg.includes(shape), `missing ${shape}`);
  });

  it("namespaces the icon's ids so nothing collides with the wash gradient", () => {
    assert.ok(svg.includes('id="icon-appshot-plate"'));
    assert.ok(svg.includes("url(#icon-appshot-plate)"));
    assert.ok(svg.includes('id="icon-c"'));
    assert.ok(svg.includes('clip-path="url(#icon-c)"'));
    // The bare ids must be gone, not merely accompanied by prefixed ones.
    assert.doesNotMatch(svg, /\bid="c"/);
    assert.doesNotMatch(svg, /url\(#c\)/);
    assert.ok(svg.includes('id="wash"'), "the lockup's own gradient survived");
  });

  it("centres the icon and the word as one block", () => {
    const block = LOCKUP.ICON + LOCKUP.GAP + LOCKUP.TEXT_WIDTH;
    const iconX = Math.round((LOCKUP.WIDTH - block) / 2);
    assert.ok(
      svg.includes(`translate(${iconX} ${Math.round((LOCKUP.HEIGHT - LOCKUP.ICON) / 2)})`),
      "the icon is not where centring the block puts it",
    );
    assert.ok(svg.includes(`x="${iconX + LOCKUP.ICON + LOCKUP.GAP}"`), "the word follows the gap");
    // Equal margins either side is the whole claim, and it is what pins GAP to
    // 44 for this wordmark — see the constant.
    assert.equal(iconX, LOCKUP.WIDTH - (iconX + block));
  });

  it("pins the wordmark to its measured width", () => {
    assert.ok(svg.includes(`textLength="${wordmarkWidth(LOCKUP.FONT_SIZE)}"`));
    assert.ok(svg.includes('lengthAdjust="spacingAndGlyphs"'));
    // The pin IS the tracking. A letter-spacing beside it would fight it.
    assert.doesNotMatch(svg, /letter-spacing/);
  });

  it("drops the icon's own title so the document has one accessible name", () => {
    assert.equal(svg.match(/<title>/g)?.length, 1);
    assert.ok(svg.includes("<title>Bastion</title>"));
    assert.doesNotMatch(svg, /icon mark/);
  });

  it("refuses a palette it cannot compose against", () => {
    assert.throws(() => composeLockup(icon, {}), /colors\.ink/);
    assert.throws(
      () => composeLockup(icon, { colors: { ink: "#000" } }),
      /two-stop `gradients\.wash`/,
    );
    // The vertical-only rule from design/README.md, enforced rather than stated.
    const rotated = {
      ...palette,
      gradients: { ...palette.gradients, wash: { ...palette.gradients.wash, angle: 90 } },
    };
    assert.throws(() => composeLockup(icon, rotated), /not vertical/);
  });

  it("refuses artwork that is not the generated icon", () => {
    // The viewBox is read before the body, so that is the assertion that fires.
    assert.throws(() => composeLockup("<p>not an svg</p>", palette), /no `viewBox/);
    assert.throws(
      () =>
        composeLockup(
          '<svg viewBox="0 0 1024 512"><rect/><path/><path/><path/><path/></svg>',
          palette,
        ),
      /not square/,
    );
    // A mark that lost a shape still renders; that is exactly why it is caught.
    assert.throws(
      () => composeLockup(icon.replace(/<path[^>]*>\s*/, ""), palette),
      /fewer than four paths/,
    );
  });
});

describe("composeCard", () => {
  const svg = composeCard(icon, palette, CARD_COPY);

  it("inherits the same mark, at the card's own scale", () => {
    for (const shape of MARK_SHAPES) assert.ok(svg.includes(shape), `missing ${shape}`);
    assert.ok(svg.includes(`scale(${SOCIAL_CARD.ICON / 1024})`));
  });

  it("keeps every mark clear of the band X crops away", () => {
    // X renders summary_large_image at 2:1 against og:image's 1.91:1. The crop is
    // silent, so the check cannot be.
    const iconY = Number(/translate\(\d+ (\d+)\)/.exec(svg)?.[1]);
    assert.ok(iconY >= SOCIAL_CARD.SAFE_INSET, `the lockup starts at ${iconY}`);
    const baselines = [...svg.matchAll(/<text[^>]*\sy="(\d+)"/g)].map((m) => Number(m[1]));
    assert.ok(baselines.length >= 3, "headline, subhead and wordmark all present");
    assert.ok(Math.max(...baselines) <= SOCIAL_CARD.HEIGHT - SOCIAL_CARD.SAFE_INSET);
  });

  it("takes a flat ground or a gradient, and nothing else", () => {
    assert.ok(composeCard(icon, palette, CARD_COPY).includes('fill="#0b0c0f"'));
    const ramped = composeCard(icon, palette, {
      ...CARD_COPY,
      ground: {
        angle: 90,
        stops: [
          { offset: 0, color: "#15161b" },
          { offset: 1, color: "#08090b" },
        ],
      },
    });
    // appshot's convention: 90 is CLOCKWISE with y DOWN, so it runs top to
    // bottom. Getting this backwards is a card that ramps the wrong way and
    // still looks deliberate.
    assert.match(ramped, /<linearGradient id="plate"[^>]*x1="600" y1="0" x2="600" y2="630"/);
    assert.throws(() => composeCard(icon, palette, { ...CARD_COPY, ground: "black" }), /not a hex/);
    assert.throws(() => composeCard(icon, palette, { ...CARD_COPY, ground: {} }), /neither a hex/);
  });

  it("refuses a card missing half its copy", () => {
    assert.throws(() => composeCard(icon, palette, { ground: "#000000", headline: "x" }), /both/);
  });

  it("escapes copy rather than letting it close a tag", () => {
    const escaped = composeCard(icon, palette, { ...CARD_COPY, subhead: 'a & b <c> "d"' });
    assert.ok(escaped.includes("a &amp; b &lt;c&gt; &quot;d&quot;"));
  });
});
