import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";
// @ts-check
import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://bastion.mgcrea.io",
  integrations: [sitemap()],
  // Every page here is `.astro` — there is no markdown to highlight. Left at its
  // `shiki` default, Astro warns on every start that the highlighter's inline
  // styles fight the CSP below; it warns on the config alone, without checking
  // whether any code block exists.
  markdown: { syntaxHighlight: false },
  security: {
    csp: {
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        // The beacon POSTs its measurement to the first (no `static.` prefix).
        // Miss it and the script loads, runs, and every report stays empty.
        //
        // The second is the feedback Worker `/feedback/` posts to. Miss that and
        // the form renders, the user types a report, presses Send, and the
        // browser refuses the fetch — no build error, one console line nobody
        // reads. `pnpm feedback:check` asserts it survives into the policy.
        "connect-src 'self' https://cloudflareinsights.com https://feedback.mgcrea.io",
        "base-uri 'self'",
        "form-action 'self'",
        "object-src 'none'",
      ],
      /*
       * The Cloudflare Web Analytics beacon is a manual embed, so the browser has to be
       * allowed to fetch it from a third-party origin. Astro fills `script-src` with
       * `'self'` plus a sha256 per inline script and nothing else, and hashes only ever
       * match inline scripts — an external URL needs a host source or it is refused
       * silently, with the tag sitting in the HTML looking perfect.
       *
       * `resources` REPLACES Astro's default source list rather than extending it, so
       * `'self'` has to be repeated here. The per-script hashes are still appended.
       */
      scriptDirective: {
        resources: ["'self'", "https://static.cloudflareinsights.com/beacon.min.js"],
      },
      // The marquee, the fan-in connector lanes and the staggered dash
      // animations carry computed delays in per-element `style` attributes. CSP
      // hashes never cover style attributes, and 'unsafe-inline' on `style-src`
      // is nullified by the hashes Astro appends there — so the allowance is
      // scoped to `style-src-attr`, leaving <style> and <link> under the strict
      // policy.
      styleDirective: {
        resources: [{ resource: "'unsafe-inline'", kind: "attribute" }],
      },
    },
  },
  vite: { plugins: [tailwindcss()] },
});
