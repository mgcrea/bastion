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
