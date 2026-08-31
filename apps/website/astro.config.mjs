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
        "connect-src 'self'",
        "base-uri 'self'",
        "form-action 'self'",
        "object-src 'none'",
      ],
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
