// The page someone lands on straight after paying.
//
// Rendered here rather than on the marketing site because the key has to come
// from the database, and the site is static assets under a strict CSP that would
// block it fetching anything. One self-contained page, no external requests, so
// it needs no CSP relaxation of its own and cannot break when the site redeploys.
//
// The palette is the site's, by hand. It cannot import design/colors.json — this
// is a Worker bundle, and a build step to inline three hex values would cost more
// than it saves — so the one thing to keep true is the accent, which is the site's
// #f2895c.

const escapeHtml = (text: string): string =>
  text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

const shell = (title: string, inner: string): string => `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 48px 24px; background: #0d0d0f; color: #e8e6e3;
    font: 16px/1.6 ui-sans-serif, -apple-system, system-ui, sans-serif; }
  main { max-width: 620px; margin: 0 auto; }
  h1 { font-size: 24px; letter-spacing: -0.02em; margin: 0 0 8px; }
  p { color: #a9a5a0; }
  code { display: block; overflow-wrap: anywhere; background: #17171a;
    border: 1px solid #2a2a2e; border-radius: 10px; padding: 14px;
    font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #e8e6e3; }
  a { color: #f2895c; }
</style>
</head><body><main>${inner}</main></body></html>
`;

export const thanksPage = (key: string, email: string): string =>
  shell(
    "Your Bastion licence",
    `<h1>Thank you.</h1>
<p>Your licence key, also sent to ${escapeHtml(email)}:</p>
<code>${escapeHtml(key)}</code>
<p>Open Bastion, choose <strong>Settings ▸ Licence</strong> from the menu bar icon, and paste
it in. It covers every 1.x release, on every Mac you own, and does not expire.</p>
<p>Thirty days, any reason: reply to the email and it is refunded in full.</p>`,
  );

/**
 * The same URL, a week later.
 *
 * A checkout session id lands in browser history, in the Referer of the link
 * this page carries, and in support screenshots, and it never expires on
 * Stripe's side. Showing the key against it forever turns each of those into a
 * copy of the licence. After a week the buyer has long since read the mail, so
 * the page says where the key went instead of what it is.
 */
export const sentPage = (email: string): string =>
  shell(
    "Your Bastion licence",
    `<h1>Already sent.</h1>
<p>Your licence key was emailed to ${escapeHtml(email)} when you bought it, and this page
stopped showing it after a week.</p>
<p>Cannot find the message? Reply to your Stripe receipt and it will be re-sent.</p>`,
  );

/**
 * Stripe redirects the moment payment succeeds, which can outrun the webhook.
 * This is that gap, and it says so rather than showing an error for a purchase
 * that went through perfectly.
 */
export const pendingPage = (): string =>
  shell(
    "Your Bastion licence",
    `<h1>Payment received.</h1>
<p>Your key is being issued and will arrive by email in a moment. Refreshing this
page shortly will also show it.</p>
<p>If nothing arrives within a few minutes, reply to your Stripe receipt and it
will be sorted out by hand.</p>`,
  );

export const notFoundPage = (): string =>
  shell(
    "Not found",
    `<h1>Not found.</h1><p><a href="https://bastion.mgcrea.io">bastion.mgcrea.io</a></p>`,
  );
