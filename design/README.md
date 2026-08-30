# Bastion icon

Direction `4a` — "dusk ridge", from `.idea/design/Bastion Logo v2.dc.html`. A curtain wall with a
solid spur inside it, standing on cupertino's own hills.

One source, four renderings, one command:

```bash
make icon
```

| File                                 | Role                                                                             |
| ------------------------------------ | -------------------------------------------------------------------------------- |
| `bastion-mark.svg`                   | **the source.** Hills, wall and spur on a transparent sky, 1024×1024. Edit this. |
| `colors.json`                        | palette and gradients                                                            |
| `bastion-menubar.svg`                | **authored**, not composed — the menu bar template glyph. Edit this too.         |
| `bastion-icon.svg`                   | _generated_ — plated vector for the web/README/docs                              |
| `bastion-lockup.svg`                 | _generated_ — the icon and the word, banner for the README                       |
| `../apps/apple/Bastion/Bastion.icon` | _generated_ — the Icon Composer bundle Xcode compiles                            |

`make icon` writes every generated file and audits the bundle. Never hand-edit them: the mark and
the menu bar glyph are the only geometry, which is the whole point of generating the rest.

## Why it borrows cupertino's plate

Deliberately, and it is the one decision here that is not about Bastion. These are two apps by one
author in one family, and the family's mark is a warm vertical plate with a dark landscape running
off the bottom. Cupertino puts a sun over it; Bastion puts a fort on it. The plate gradient, both
hill colours and the squircle are copied to the digit from `../../cupertino/design/colors.json` —
not approximated — so the two sit beside each other in a Dock as siblings rather than as near
misses, which is worse than either matching or differing.

What is Bastion's own is the subject and the ink: `#FDEFDC`, the wall, at 78% over the sky.

## Why the sky is a flag and not artwork

The mark carries no background. `make icon` passes the sky as `--plate-gradient
'#FFD08A,#F2895C' --plate-angle 90`, so appshot writes the `.icon` as **two layers** — `mark.png`
over an opaque `plate.png`. macOS 26 lights and parallaxes them independently; a single flattened
bitmap gets one specular sweep across the whole icon and reads flat.

`icon.json`'s `layers` array runs **front to back**, so the plate is the _last_ entry. Backwards is
silent: the bundle still compiles and installs, and renders as a bare plate with no mark.

## Why the hills bleed off the edges

They are landscape, not a centred glyph — `M-39.7 882.8 … V1063.7` deliberately overruns the canvas
on three sides, so the mark goes in at `--mark-fraction 1.0` and maps 1:1. The usual 70–80%
glyph-to-plate band does not apply to a scene icon, and `appshot icon build` says so in its own
output: it reports the mark spanning 100% of the composed plate.

Measured on macOS 26.6 with `render-icon` + `measure-icon`, against the peers the band came from:

| icon      | plate/canvas | glyph w | glyph h |
| --------- | ------------ | ------- | ------- |
| Bastion   | 80.5%        | 80.1%   | 80.1%   |
| Cupertino | 80.5%        | 80.1%   | 80.1%   |
| Notes     | 80.5%        | 80.1%   | 80.1%   |
| Podcasts  | 80.5%        | 80.1%   | 80.1%   |

Every row is the measurement tool's own clamp, which is the answer worth having: Bastion renders at
exactly the plate size its neighbours do, and the figure cannot distinguish a scene icon from a
system one. Re-run both after any change to the mark rather than trusting this table.

The overrun is why `make icon` clips the generated SVG afterwards. macOS masks the `.icon` to its
own squircle for free, but nothing masks an SVG on a web page — without the clip the hills square
off the plate's bottom two corners.

## The transcription from the canvas

The design canvas draws 4a on a **232-unit** grid, which is cupertino's 1024 grid at 232/1024. Every
coordinate in `bastion-mark.svg` is that geometry multiplied by 1024/232 = 4.4138 and rounded to one
decimal — computed, not eyeballed. If the canvas changes, re-run the multiplication; a hand-copied
coordinate is invisible until somebody measures.

One number is **not** transcribed. The canvas carries three stroke weights for the wall — 8 units at
its 232px render, 10 at 38px, 13 at 116px and below — because its author compensated optically at
each size. The `.icon` format carries one artwork for every size, so there is exactly one weight to
pick. It is **48.6** (11 on the canvas grid, between the two extremes), chosen by rendering 35.3,
48.6 and 57.4 at 16, 32, 64 and 256px and looking at the counter between the wall and the spur: it
closes at 57.4 by 32px and the wall reads thin at 35.3. Re-render at 32px after any change; that is
where this fails first, and it is not visible at the size you will be looking at it.

## Small sizes

The `.icon` format carries one artwork for every size. At 32px the wall, the spur and both hills
still separate; at 16px the wall and spur merge into a single arch on a ridge, which is the intended
degradation and is why there is no second geometry to keep in step.

## Palette

| Token        | Hex       | Role                                     |
| ------------ | --------- | ---------------------------------------- |
| plate top    | `#FFD08A` | icon background, top                     |
| plate bottom | `#F2895C` | icon background, bottom                  |
| wall         | `#FDEFDC` | the mark's ink, light text on warm fills |
| hill mid     | `#B0532F` | back hill (at 90% over the sky)          |
| hill fore    | `#7A2F1C` | front hill                               |
| ink          | `#151617` | wordmark, body text on light             |
| ground       | `#0B0C0F` | the website's own background             |
| paper        | `#F4F2EF` | body text on the ground                  |
| accent       | `#F2A07C` | links and eyebrows on the ground         |

The plate gradient is always vertical, top light → bottom warm. Don't rotate it, don't add a third
stop.

`gradients` uses the **CSS** angle convention (180 = top to bottom). `scripts/lib/lockup.mjs` uses
appshot's (degrees clockwise, y-down, 90 = top to bottom) for the social card's ground. The two must
not meet; the card takes a raw angle, never a palette entry.

## Deriving other assets

`appshot icon build --out <path>` picks its format from the extension. For an `apple-touch-icon`,
pass `--corner-radius 0` — iOS applies its own mask, and a rounded source gets double-rounded.

The website does not transcribe any of this. `apps/website/scripts/generate-icons.mjs` reads
`bastion-icon.svg` and `bastion-menubar.svg` out of this directory and renders every favicon, touch
icon and card from them, so the chain is one mark end to end:

```
design/bastion-mark.svg --make icon--> design/bastion-icon.svg --pnpm icons--> apps/website/public/*
```

## The menu bar glyph

`bastion-menubar.svg` is direction **4a's own menu bar glyph**, transcribed from the 15px chip in
`.idea/design/Bastion Logo v2.dc.html`: the curtain wall closed at the base, with the solid spur
inside it. Same subject as the app icon, so the menu bar and the Dock read as one app.

It is **authored, not composed** — `make icon` copies it, and never derives it from the mark. Two
details are easy to get wrong by taking the geometry from `bastion-mark.svg` or the site mock
instead of from 4a itself, and both matter at 18pt:

- **The wall is closed.** The icon leaves it open at the base so the outline runs into the hills.
  There are no hills at 18pt, and an open wall leaves the silhouette with no floor — the two legs
  and the spur merge into one mass at 1x. The closed base gives it a bottom edge to read against.
- **The stroke is 6**, the canvas's own weight in its 64-unit box, which lands at 3.17 here
  (1.58pt). Not the 5 the lockup beside it uses; the canvas thickens it for the small size.

The weight was checked rather than assumed. Rendered at 18pt against 2.8 and 2.5, the counter
between the wall and the spur survives at all three, so the canvas weight costs nothing and there is
nothing to tune. Re-render at **1x** after any change — that is where this fails first, and it is
invisible at the 2x you will be looking at.

It is a **template image**: pure black plus alpha, no colour, so AppKit tints it for light menu
bars, dark menu bars and the highlighted state instead of us shipping three renderings. `Image(_:)`
resolves by name **without** consulting `template-rendering-intent`, so `MenuBarLabel` in
`BastionApp.swift` also says `.renderingMode(.template)`; without it the glyph ships black-on-black
in a dark menu bar. The website hits the same wall from the other side — an `<img>` cannot recolour
the file either, so `Hero.astro` filters it to white where its mock draws a dark bar.

Coordinates are cupertino's own 36-unit grid drawn at 18pt — 2 units = 1pt — so the two menu bar
glyphs in this family are comparable without conversion. The 64-unit source is scaled so the ink
spans 32.2 units vertically, cupertino's constraining dimension.

|                   | ink              | canvas     | strokes |
| ----------------- | ---------------- | ---------- | ------- |
| cupertino's glyph | 16.10 × 14.15 pt | 18 × 18 pt | 1.10 pt |
| this glyph        | 15.57 × 16.10 pt | 18 × 18 pt | 1.58 pt |

The two shapes carry two weights on purpose — one light (the stroked wall), one solid (the spur) —
for the reason cupertino's three do: matched weights read as tramlines rather than as one form
inside another.

There is a second, unused glyph in the design assets worth knowing about. The **v1** logo canvas
draws a flat plan mark — a bastion from above — marks it "unchanged in all three" directions, and
argues for it on the grounds that "the plan mark is symmetric, so it holds at menu-bar size where a
single-spur silhouette would close up". That concern is real but it applies to the wall left _open_;
closed, 4a holds its counter at 1x, which is why 4a's own glyph is the one that ships. (The v1 path
is also not symmetric as drawn: `L40 16`, `L48 24` and `L40 48` want 44, 20 and 44. Fix those three
first if it is ever revived.)

`actool` reads the SVG directly and preserves the vector representation, so there are no PNG slots
to keep in step. `make icon` copies the file into `MenuBarIcon.imageset`, which is why that copy is
listed as generated above.

## The horizontal lockup

`bastion-lockup.svg` sets the plated icon beside the word on the `wash` gradient from `colors.json`,
and it is **composed from `bastion-icon.svg`, not drawn beside it** — the generator embeds that file
whole and scales it, so the sky, the squircle and the bleed clip are inherited rather than repeated.

That is not fussiness, and the evidence is next door. Cupertino's lockup lived in its design canvas,
hand-drawn alongside the mark, and its hills had been a single simplified path for two revisions
before anyone noticed. A lockup nothing generates is a lockup nothing checks.

One number is not inherited: `textLength`. GitHub serves the file inside an `<img>`, so the wordmark
resolves against the reader's fonts — SF Pro Display on a Mac, something else everywhere else,
measuring differently and pushing the composition off its own plate. The run is pinned to the width
it was laid out for and `lengthAdjust="spacingAndGlyphs"` absorbs the difference. The value is a
CoreText measurement of "Bastion" at the size it is set in — 346.6 natural at 104px, 334.1 with the
wordmark's 2% tracking applied to the six interior gaps — so changing the string means re-measuring
it; `scripts/lib/lockup.mjs` says so where the constant is defined.
