// Whether the secrets the webhook depends on are there, and usable.
//
// Both are secrets rather than vars, so nothing in wrangler.jsonc declares them
// and a deploy goes out green without either. Unchecked, an empty
// STRIPE_WEBHOOK_SECRET threw inside the HMAC `importKey`, and a truncated
// LICENSE_SIGNING_KEY threw inside `atob` or the Ed25519 import on the first
// sale. Either became workerd's bare 500, with nothing in the log naming the
// secret, on the one route where a failure is a customer who paid and got
// nothing.
//
// The answer is still 500, on purpose: Stripe retries it, so a payment that
// arrived while a secret was wrong is fulfilled once the secret is fixed. What
// changes is the log line. It names the secret and what is wrong with it, and
// never the value, which is the one thing a log must not hold.

import { importSigningKey } from "./license";

/** Each problem as a sentence naming its secret. Empty means configured. */
export const configProblems = async (env: Env): Promise<string[]> => {
  const problems: string[] = [];

  // Unset reads as `undefined` at run time, whatever the generated type says.
  const webhookSecret: string | undefined = env.STRIPE_WEBHOOK_SECRET;
  if (!webhookSecret) {
    problems.push("STRIPE_WEBHOOK_SECRET is not set");
  } else if (!webhookSecret.startsWith("whsec_")) {
    // Every endpoint secret Stripe issues, dashboard or `stripe listen`, has
    // this prefix. Without it the value is something else pasted into the wrong
    // slot (an API key, most likely), and every genuine payment would be refused
    // as a signature mismatch that reads like a bug in stripe.ts.
    problems.push("STRIPE_WEBHOOK_SECRET does not start with whsec_");
  }

  const signingKey: string | undefined = env.LICENSE_SIGNING_KEY;
  if (!signingKey) {
    problems.push("LICENSE_SIGNING_KEY is not set");
  } else {
    try {
      await importSigningKey(signingKey);
    } catch {
      // The error itself is not logged: it is WebCrypto's, and says nothing a
      // person can act on beyond this sentence.
      problems.push("LICENSE_SIGNING_KEY is not a base64 PKCS#8 Ed25519 private key");
    }
  }

  return problems;
};
