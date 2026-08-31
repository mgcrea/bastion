# Bastion icon

Direction `4a` — "dusk ridge", from `.idea/design/Bastion Logo v2.dc.html`. A fort standing on
cupertino's own hills, with a curtain wall around it.

The wall is not in the icon. It moved to the menu bar, where it is the glyph the app draws while a
server is running — so the mark is the fort, and the wall is what the fort does when it is guarding
something. That is also why the icon and an idle menu bar are now one silhouette instead of two
drawings of the same idea.

One source, four renderings, one command:

```bash
make icon
```

| File                                 | Role                                                                             |
| ------------------------------------ | -------------------------------------------------------------------------------- |
| `bastion-mark.svg`                   | **the source.** Hills, wall and spur on a transparent sky, 1024×1024. Edit this. |
| `colors.json`                        | palette and gradients                                                            |
| `bastion-menubar.svg`                | **authored**, not composed — the menu bar glyph, idle. Edit this too.            |
| `bastion-menubar-active.svg`         | **authored** — the same glyph with the wall, drawn while a server runs.          |
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

What is Bastion's own is the subject and the ink: `#FDEFDC`, the fort, at 90% over the sky.

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

Two numbers are **not** transcribed, and they are the only two anybody chose. Dropping the wall left
the fort spanning 34% of the canvas — an island in a large field, and exactly the diagnosis the
usual glyph-ratio check exists to catch. So it is scaled to **580** wide, roughly the footprint the
wall used to hold, and seated at **y850** rather than the wall's old 776.8.

The seat is the composition. At 850 the front hill crosses the fort's feet and the back hill runs
behind it, so it stands *on* the ridge; raise it and it floats above the hills with a visible strip
of sky under it. Both numbers are pinned by `scripts/lib/lockup.test.mjs`, which holds the fort's
path character for character.

The canvas's three stroke weights for the wall — 8 units at its 232px render, 10 at 38px, 13 at 116
and below, its author compensating optically at each size — no longer apply to anything here. The
menu bar glyph carries the only stroke left in the family, and it is picked against cupertino's halo
rather than against the canvas. See below.

## Small sizes

The `.icon` format carries one artwork for every size. This got easier when the wall left: the
counter between wall and fort was the thing that closed first, and there is no longer one. At 32px
the fort and both hills separate cleanly; at 16px the fort and the back hill merge into a single
mass on a ridge, which is the intended degradation and is why there is no second geometry to keep in
step.

## Palette

| Token        | Hex       | Role                                     |
| ------------ | --------- | ---------------------------------------- |
| plate top    | `#FFD08A` | icon background, top                     |
| plate bottom | `#F2895C` | icon background, bottom                  |
| fort         | `#FDEFDC` | the mark's ink, light text on warm fills |
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

## The menu bar glyphs

Two files, one mark, two states — the shape cupertino uses for the same job:

| file                         | state              | ink (measured at 18pt) |
| ---------------------------- | ------------------ | ---------------------- |
| `bastion-menubar.svg`        | idle               | 23.0 × 18.2 units      |
| `bastion-menubar-active.svg` | a server is live   | 31.5 × 24.8 units      |
| cupertino's, for scale       | idle / connected   | 34.0 × 16.8 / 34.0 × 20.8 |

`MenuBarLabel` in `BastionApp.swift` swaps them on `Activity.shared.instances`, and reads that
rather than `Supervisor.running` for the reason the popover's rows do: the supervisor's view is a
lock-protected snapshot with nothing for SwiftUI to observe. Bastion's own built-in server never
spawns a process and so never appears there, which is what makes the state mean something.

They are still **authored, not composed** — `make icon` copies them and never derives them from the
mark, because the sizing below is a menu bar problem the 1024 mark knows nothing about. What is no
longer authored is the *shape*: the fort's five vertices are `bastion-mark.svg`'s own, scaled. The
two used to differ by about 5% in aspect for no reason anybody had written down.

### The wall is open at the base, and that is the whole design

Closed, it is a parallel outline of the fort at every point and reads as **tramlines** — one shape
drawn twice. That is what the old glyph did with its two nested pentagons, and it is what a naive
"halo around the fort" produces if you offset the silhouette and join it up. Open, the wall
terminates level with the fort's own floor and reads as a wall arcing over a keep.

Cupertino gets the same effect for free and it is worth seeing why, because it is not obvious from
the file: its halo is a full `<circle>`, but it sits inside the clip that cuts the sun off at the
horizon, so what anybody actually sees is an **arc**. There is no closed ring around that sun
either.

This is also the shape the icon used to carry — the old mark's wall was open at the base too, so the
outline could run down into the hills. There are no hills at 18pt, and that used to be an argument
for closing it: an open wall left the silhouette with no floor. It no longer is, because the fort
below it is solid and has a floor of its own.

### The numbers, and how they were picked

- **Gap 2.8 units.** 2.4 separates cleanly but still reads as a tramline at 8×; 3.2 buys nothing and
  costs the fort width it needs to carry the idle glyph alone. 2.8 is where the wall reads as a
  second object and the fort keeps its mass.
- **Stroke 1.6 units (0.8pt)** — cupertino's halo weight exactly, and half the 3.17 the old wall
  carried. Matched weights read as tramlines; one light shape around one solid one reads as a form
  inside another.
- **Fort 22.67 units wide.** Not a drawing decision: it is the widest fort the active glyph can
  carry while keeping a 2-unit margin, because the wall standing off it eats 8.8 units of the width
  budget. The old glyph was 31.5 × 32.5 — nearly twice cupertino's mass, which is not what two icons
  in one menu bar by one author should look like.
- **Both files sit 1.18 units below centre.** The wall adds 5.6 units above the fort and 0.5 below,
  so no one position centres both states. This splits the error exactly — idle 1.12 low, active 1.12
  high — and it is the same compromise cupertino makes. Change it in both files or in neither: the
  fort must not move when a server starts, or the swap reads as the icon twitching rather than as
  something happening.

Coordinates are cupertino's 36-unit grid at 18pt, so 2 units = 1pt and the menu bar glyphs in this
family are comparable without conversion.

### Verify by counting, not by looking

At 18pt the active glyph is two connected components at 8× and 2×, and **one** at 1×, where the wall
comes out as a grey outline rather than a black line. Cupertino's ring and sun merge at 1× too. That
is acceptable degradation rather than a bug to chase — retina is the design target, and 1× still
changes visibly, which is what a state needs to do. Re-measure with a component count after any
edit; by eye at 2× you cannot see the failure.

### Template images

Pure black plus alpha, so AppKit tints them for light menu bars, dark ones and the highlighted state
instead of us shipping six renderings. `Image(_:)` resolves by name **without** consulting
`template-rendering-intent`, so `MenuBarLabel` also says `.renderingMode(.template)`; without it the
glyph ships black-on-black in a dark menu bar. The website hits the same wall from the other side —
an `<img>` cannot recolour the file either, so `Hero.astro` filters it to white where its mock draws
a dark bar. That mock shows the **active** glyph, because it depicts a client mid-session.

`actool` reads the SVGs directly and preserves the vector representation, so there are no PNG slots
to keep in step. `make icon` copies each file into its own imageset — `MenuBarIcon.imageset` and
`MenuBarIconActive.imageset` — which is why those copies are listed as generated above.

There is a second, unused glyph in the design assets worth knowing about. The **v1** logo canvas
draws a flat plan mark — a bastion from above — marks it "unchanged in all three" directions, and
argues for it on the grounds that "the plan mark is symmetric, so it holds at menu-bar size where a
single-spur silhouette would close up". (The v1 path is also not symmetric as drawn: `L40 16`,
`L48 24` and `L40 48` want 44, 20 and 44. Fix those three first if it is ever revived.)

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
