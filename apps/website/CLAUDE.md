# apps/website

Astro 7, static output, Tailwind v4 through `@tailwindcss/vite` — there is no `tailwind.config.*`,
and every token lives in `src/styles/global.css`. Deployed to Cloudflare Workers static assets with
`wrangler`.

Lint and format are **root-only**: `pnpm lint` and `pnpm format:check` from the repository root
cover every workspace at once. oxfmt formats the `.css`, `.mjs` and `.ts` here and leaves `.astro`
alone, so an Astro file's formatting is whatever you write.

## `src/assets/shots/` belongs to the pipeline

The six app screenshots in `Screens.astro` are captured, not placed. `make screenshots` from the
repository root builds Bastion, launches it in demo mode onto each screen, gates the result against
committed goldens, and writes the images here.

**That command deletes every `.png` in `src/assets/shots/` before writing.** Do not park anything
else in the directory, and do not edit the files — the next capture overwrites them. To change what
a shot shows, change the fixture in `apps/apple/Bastion/DemoSeed.swift` and re-run.

They are committed via Git LFS (see `.gitattributes` here) because `astro build` imports them
through `astro:assets`, so a clone that has not just run a capture still has to build. A checkout
without `git lfs pull` gets 131-byte pointer files still named `.png`, and the build then fails
inside sharp complaining about the image format rather than about the checkout. That is why the
`website` job in `.github/workflows/ci.yml` checks out with `lfs: true`.

`Screens.astro` renders every plate at one pixel scale rather than stretching each to the column
width. Five captures are the main window at 2360px and `licence` is the smaller Settings window at
1520; left to `w-full` it rendered about half again as large as the rest, which reads as two
applications. The `plate()` helper is what keeps them honest, and it derives everything from the
imported image's own width, so a capture that changes size does not need a second edit here.

`public/video/tour.mp4` (and its `tour.jpg` poster), played by `Tour.astro` under the hero, is
rendered from the same captures by `make site-video`, from the `tour` entry in
`apps/apple/Screenshots/screenshots.config.json`. It is in `public/` because astro:assets does
nothing for video, so `make screenshots` neither clears nor refreshes it and nothing fails when it
falls behind: run `make site-video` after every capture run. Its captions are burned in, so a claim
reworded on the page stays in the old words there until it is re-rendered.

The figures' anchors are prefixed `shot-`. The bare `#screens`, `#servers`, `#status`, `#rules` and
`#how` belong to sections the nav links to.

## Three visual idioms, never mixed

1. **Real captures** — `Screens.astro`, and only there.
2. **Hand-drawn macOS chrome** — the menu bar and the four-tabbed config panel in `Hero.astro`, the
   `make audit` transcript in `Rules.astro`. Each is drawn because a capture cannot do that
   particular job: a menu-bar popover is a high-layer panel `appshot` cannot photograph at all, four
   editors holding one identical file is not a photograph of anything, and both have to reflow on a
   phone.
3. **Plain diagrams, no chrome** — the fan-in lanes in `Problem.astro`. Dressing a diagram in a
   title bar would promise a pane the app does not have.

A drawing must never disagree with a photograph. `Hero.astro`'s `MENU` holds the same five profiles
in the same states as `DemoSeed.profiles`, and nothing enforces that — change the two together. One
capture is promoted out of `Screens.astro` into `ServerPane.astro`, one scroll below the hero,
because it answers the drawing up there; if the hero's drawing changes, check that the promoted
capture is still the one that answers it.

## Facts live in `src/config.ts`

Counts are derived, never typed: `src/data/servers.ts` is generated from the repository root's
`servers.json` by `make servers` and verified by `pnpm servers:check`. `SHIPPED` gates anything that
names something you can buy or download; a string outside a `SHIPPED` branch has to be true on its
own. `pnpm icons` re-bakes `og-image.png` from `SOCIAL_CARD`, and nothing checks that you remembered
to.

## One generated mark has a reader outside this site

`pnpm icons` renders every favicon, the touch icon, the OG card and
`public/product-image.png` from `design/bastion-icon.svg`. That last one is the `images` entry on
the live Stripe product, so it is what a buyer sees beside the line item on the checkout page.
Stripe stores the URL and fetches it, which has two consequences: the checkout only picks up a new
mark **once the site deploys**, and renaming or deleting the file breaks a page nothing in this
repo builds.

## The changelog pages come from CHANGELOG.md

`/changelog` and `/changelog/<version>` read the repository's `CHANGELOG.md` at build time
(`src/data/changelog.ts`, `?raw`), through `scripts/lib/changelog.mjs` — the parser the appcast, the
GitHub release body and the app's What's New pane use, so the four cannot disagree. `### Internal`
is left out here through the same `userFacing`. Nothing is copied into this app; a release appears
when its section does.

- **Each release from 1.24.0 on opens with a summary**: one paragraph, `**Title.** Description.`,
  right under its `## [x.y.z]` heading. It is the version page's headline and standfirst, its
  og:title and og:description, and the post the "Share this release" box offers. A test in
  `scripts/lib/changelog.test.mjs` holds the title to two lines on the card and the post to 256
  characters, which is X's 280 less the link. Write it for somebody who has never opened the app.
- **Each summary gets a social card**, `public/changelog/<version>.png`, rendered by `pnpm cards`
  (`make changelog` runs it) through `composeReleaseCard` in `../../scripts/lib/lockup.mjs`, on the
  store plates' ground from `apps/apple/Screenshots/screenshots.config.json`. It is baked on a Mac
  and committed for the reason `og-image.png` is. `src/data/release-cards.json` records the hash of
  the SVG each PNG came from, so `pnpm changelog:check` — which CI's manifest job runs on Linux —
  catches a card that has fallen behind its title, its date or the layout without needing the font.
  A release with no summary falls back to the site card.
- **The nav's version badge links to `/changelog/${APP_VERSION}/`**, and `src/data/changelog.ts`
  fails the build when `CHANGELOG.md` has no released section for `APP_VERSION`. Bump the two in the
  same release commit.
- **The copy button's script is a processed `<script>`** in `ShareRelease.astro`, which Astro hashes
  into the CSP. An `is:inline` one would be refused, and only in the build.
