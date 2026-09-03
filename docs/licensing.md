# Licensing

How Bastion is licensed, what a key actually buys, and why the check is shaped the
way it is. The two license files and the EULA are the terms; this is the reasoning
behind them.

## Short version

- The **source** is public and stays public. Read it, compile it, run your own build.
- The **signed build** is sold. $14.99 (€14.99 in the EU), one price, every 1.x release, every
  Mac you own.
- The check is **offline**. It cannot phone home, and that is asserted on every build.
- **Thirty days**, full refund, no reason required.

## Trust is auditability, not the licence

Bastion holds every credential you own. It keeps them in your Keychain, hands them
to child processes it spawns, and sits between your assistant and everything those
servers can reach. There is no version of that which is safe to take on faith.

So the source is readable, and the licence is written around keeping it readable
rather than around preventing copies. What is sold is the notarized artifact and
the maintenance behind it. Nothing is sold by being hidden.

This also decides an argument that would otherwise recur: any proposal to obscure,
pack or otherwise harden the licence check is refused by construction. The check is
a dozen readable lines in `Gateway.swift` and `License.swift`, and it stays that way.
Obscuring it would cost the audit exactly the readability the audit exists for, in
exchange for slowing down the one audience most able to route around it.

## What is licensed how

| Path                | Licence                                   | Why                                                                                             |
| ------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `apps/apple/`       | [Source-available](../apps/apple/LICENSE) | The app and the bridge. Readable and compilable; binary redistribution reserved.                |
| `apps/api/`         | [MIT](../LICENSE)                         | The fulfilment Worker. Nothing secret in it — the signing key is a Worker secret, never a file. |
| `apps/website/`     | [MIT](../LICENSE)                         | The marketing site.                                                                             |
| `scripts/`, `docs/` | [MIT](../LICENSE)                         | The audits in particular are more useful copied than reserved.                                  |
| The signed build    | [EULA](../apps/apple/EULA)                | A separate agreement, requiring a key. Independent of the source licence in both directions.    |

`scripts/` being MIT is deliberate rather than incidental. `audit-listener.sh` is
the script that checks the security claims this project makes about itself; a
licence that stopped someone lifting it into their own MCP gateway would be
protecting the wrong thing.

## What is actually being sold

The **relay** — the supervised, credential-holding, audited path from a client to
a server you configured. Unlicensed, Bastion refuses to relay and says why.

Three things sit outside that gate on purpose:

**Bastion's own MCP server.** It relays nothing, spawns nothing and holds no
credential. Charging for read access to your own configuration would be charging
for the window. The carve-out also buys the best possible trial: an unlicensed user
can have their assistant install servers, set credentials and wire clients, and the
first thing they hit afterwards is the sentence explaining what a licence is for —
at the moment they have something to lose by not having one.

**The write gates.** Making the free tier the safe one and the paid tier the
dangerous one would be an incentive nobody should design.

**Everything else.** There is no tier above the one you bought.

## The gate is one place, and it is early

`Gateway.swift` refuses at the point a request arrives and before the supervisor
may spawn a child. Refusing later would leave a process running, holding
credentials, for a request that was never served.

Every request is its own HTTP POST, which makes the gate immediate in a way
cupertino's could not be — there, one stdio connection opened when the editor
started and was held for days, so a gate on new connections was barely a gate.

## Offline validation, and what it costs

The key is an Ed25519 signature over a payload naming the licensee, the major
version and the issue date. The app carries the public half and checks it locally
in microseconds. There is no activation server, and there is no way to add one
without breaking the claim `scripts/audit-listener.sh` asserts on every build.

Three implementations of one format, none able to import the others:

| Where                                                                     | Runtime   | Role                    |
| ------------------------------------------------------------------------- | --------- | ----------------------- |
| [`scripts/lib/license.mjs`](../scripts/lib/license.mjs)                   | Node      | Mints by hand, verifies |
| [`apps/api/src/license.ts`](../apps/api/src/license.ts)                   | workerd   | Mints from a payment    |
| [`apps/apple/Bastion/License.swift`](../apps/apple/Bastion/License.swift) | CryptoKit | Verifies, offline       |

What keeps them honest is that the signature covers the **encoded** payload rather
than the parsed object, so JSON key order and whitespace never have to agree — only
the bytes do. `make license-check` compiles the real Swift verifier and feeds it
keys minted by the real signing key; `apps/api`'s tests assert the Worker and Node
produce byte-identical output from identical input.

The cost is revocation. A refunded key keeps working until the next release, when
`make revocations` bakes the list into the build. That is a real cost and the EULA
states it rather than leaving it to be discovered. The alternative was a program
that phones home on every launch for every honest user in order to inconvenience a
dishonest one.

## Why there is a trial at all

A refund answers "is this worth the money". It cannot answer "does this work on my
Mac, against my clients, with my credentials" — and that question is a fact about
your machine that you are entitled to before paying.

So: thirty minutes, full function, every server relaying, held in memory. Quitting
and reopening starts another one, and no machinery prevents that. Someone
relaunching the app every half hour to avoid $14.99 was never going to buy it, and
the code to stop them would cost more than they are worth. Saying so plainly is
cheaper than being found out.

## Price

**$14.99 / €14.99**, once. One price, one major version, every Mac you own or
control. No subscription, no seats, no activation count.

Both currencies are named explicitly on the Stripe price via `currency_options` —
the euro figure is not a conversion of the dollar one. Two reasons. Adaptive
Pricing only converts _out of_ a settlement currency, and this account settles in
euro alone, so a dollar-only price would put an FX conversion on the seller for
every sale, including euro ones; naming both keeps that cost in the presented
rate, where the buyer's bank would have charged it anyway. And EU consumer law
expects a VAT-inclusive total, which a figure converted at checkout cannot
promise in advance.

The two numbers are therefore not equal and are not meant to be. The account's
tax default is `inferred_by_currency`, so $14.99 is quoted tax-exclusive and
€14.99 VAT-inclusive, as each side is normally quoted — a US sale nets more than
an EU one at the same face value, because the EU figure has VAT taken out of it.
Worth remembering before reading regional variance as a pricing bug.

2.0 is a new purchase. `price_id` and `amount_paid` are recorded on every licence
row from the first sale precisely so that fair upgrade pricing is possible later —
that number cannot be reconstructed after the fact. Nothing is promised about it
here, because a promise about a price for software that does not exist yet is a
promise made with no information.

## Fulfilment

Stripe payment link → webhook → [`apps/api`](../apps/api) mints, records in D1, and
emails the key with a `.license` attachment. The `/thanks` page covers mail being
slow or filtered; the mail covers the far more common case of closing the tab. A
licence the buyer cannot find is indistinguishable from one they never received,
and that is the case that becomes a chargeback.

`/thanks` shows the key for a week, then says where it was sent. The checkout
session id in that URL never expires on Stripe's side and lands in browser
history, in the Referer of the page's own link, and in support screenshots;
showing the key against it forever would make each of those a copy of the
licence. Both public routes are rate-limited per address, and a limited request
answers exactly as an unlimited one does.

Idempotency is the unique constraint on `stripe_session_id`: Stripe redelivers for
days, and a redelivery must not mean a second licence. A failed email returns 500
on purpose, so Stripe retries and the send is attempted again.

Refunds and lost disputes mark `revoked_at`; a dispute **won** clears it, because
the claim failed and the customer did pay after all.

The mark beside the line item on the checkout page is `product.images` on the
Stripe product, pointing at `https://bastion.mgcrea.io/product-image.png` —
generated by the website's `pnpm icons`, and a URL Stripe fetches rather than an
upload. So the checkout follows a site deploy and the payment link never has to
be touched.

## Secrets, and what losing each one costs

Everything below is held by one person on one machine, and the first row is the
one with no recovery. `.env.example` says where each lives and how to make it.

| Secret                                   | Lives in                                                                               | Lost                                                                                                                 | Leaked                                                                                    |
| ---------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `LICENSE_SIGNING_KEY` (Ed25519, private) | repo-root `.env`; the Worker's secret store via `pnpm secrets:prod`                    | **No key can ever be issued for 1.x again**, replacements for lost keys included. Back it up off this machine.       | Anyone can mint keys. Rotating means a new major with a new public key compiled in.       |
| Sparkle EdDSA key (private)              | The login keychain, written by `generate_keys`; shared with Cupertino                  | No update can be signed; every installed copy stops updating and needs a manual reinstall of a build with a new key. | Anyone can push an update to both apps. Ship a signed release carrying the new key first. |
| `STRIPE_WEBHOOK_SECRET`                  | The Worker's secret store; the Stripe dashboard                                        | Rotate in Stripe and push again.                                                                                     | Forged webhooks mint licences until it is rotated.                                        |
| `STRIPE_SECRET_KEY` (optional)           | The Worker's secret store                                                              | Nothing: it is a fallback fulfilment never depends on.                                                               | Stripe account access. Rotate in Stripe.                                                  |
| Developer ID certificate; `AC_*` API key | The login keychain; the `.p8` at `AC_KEY_PATH`                                         | Cannot sign or notarize until re-issued at developer.apple.com.                                                      | Revoke at developer.apple.com; notarization ties every build to the account.              |
| Cloudflare API token                     | `wrangler login` on the deploying machine (`account_id` in `wrangler.jsonc` is public) | Deploys stop until a new token is made.                                                                              | Rotate in the Cloudflare dashboard.                                                       |

## Not decided

- Whether upgrade pricing exists at 2.0, and at what discount.
- Volume or organisation licensing beyond "one named user per key".
- Whether the revocation list is ever published, and in what form.
