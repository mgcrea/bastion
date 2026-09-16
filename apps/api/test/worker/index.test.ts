// The handlers, in workerd, against a real D1.
//
// Every test builds its own `env` on top of the pool's: the real database, a
// stub in place of Email Service that records what it was asked to send, a
// keypair minted for the run, and the webhook secret the signatures below use.
// The table is emptied before each test, so each one seeds what it needs.
import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import worker from "../../src/index";

const SECRET = "whsec_test";
const SESSION = "cs_test_1";
const INTENT = "pi_test_1";

// The pool shares one D1 across the file, so every test starts from an empty
// table rather than from whatever the previous one left.
beforeEach(async () => {
  await env.DB.prepare("DELETE FROM licenses").run();
  await env.DB.prepare("DELETE FROM stripe_events").run();
});

// Several tests spy on `console.error` or stub `fetch`; none may leak into the next.
afterEach(() => {
  vi.restoreAllMocks();
});

// Every event needs its own id, because the Worker now refuses to handle the
// same one twice. Stamped rather than hardcoded so each builder call is a
// distinct delivery, which is what these tests have always meant; a test about
// redelivery passes an explicit id and overrides this.
let eventSeq = 0;
const stamped = <T extends object>(event: T): T & { id: string } => ({
  id: `evt_test_${++eventSeq}`,
  ...event,
});

let privateKey = "";
beforeAll(async () => {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array(
    (await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer,
  );
  privateKey = btoa(String.fromCharCode(...der));
});

type Mail = { to: string; key: string };

/** The Worker's env, with the pieces a test controls swapped in. */
const testEnv = (overrides: Partial<Env> = {}, sender?: () => Promise<void>) => {
  const sent: Mail[] = [];
  const EMAIL = {
    send: async (message: { to: string; text: string }) => {
      if (sender) await sender();
      sent.push({ to: message.to, key: message.text.split("\n")[2] ?? "" });
    },
  } as unknown as SendEmail;
  const built: Env = {
    ...env,
    EMAIL,
    LICENSE_SIGNING_KEY: privateKey,
    STRIPE_WEBHOOK_SECRET: SECRET,
    ...overrides,
  };
  return { env: built, sent };
};

const limiter = (success: boolean): RateLimit => ({ limit: async () => ({ success }) });

/** A request, and everything it handed to `waitUntil`, run to completion. */
const call = async (request: Request, forEnv: Env): Promise<Response> => {
  const context = createExecutionContext();
  const response = await worker.fetch(request, forEnv, context);
  await waitOnExecutionContext(context);
  return response;
};

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

const recorded = async (forEnv: Env, id: string): Promise<boolean> =>
  (await forEnv.DB.prepare("SELECT id FROM stripe_events WHERE id = ?").bind(id).first()) !== null;

/** What was logged through `console.error`, joined, for a test to match on. */
const errorLog = () => {
  const spy = vi.spyOn(console, "error").mockImplementation(() => {});
  return () => spy.mock.calls.map((args) => args.join(" ")).join("\n");
};

const hmacHex = async (secret: string, message: string): Promise<string> => {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(mac)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
};

const webhook = async (
  forEnv: Env,
  event: unknown,
  options: { secret?: string; body?: string } = {},
): Promise<Response> => {
  const body = options.body ?? JSON.stringify(event);
  const t = Math.floor(Date.now() / 1000);
  const header = `t=${t},v1=${await hmacHex(options.secret ?? SECRET, `${t}.${body}`)}`;
  return call(
    new Request("https://api.test/stripe/webhook", {
      method: "POST",
      body,
      headers: { "stripe-signature": header },
    }),
    forEnv,
  );
};

const completed = (session: Record<string, unknown> = {}, livemode = false) =>
  stamped({
    type: "checkout.session.completed",
    livemode,
    data: {
      object: {
        id: SESSION,
        payment_intent: INTENT,
        amount_total: 1499,
        currency: "eur",
        payment_status: "paid",
        customer_details: { email: " Buyer@Example.com " },
        metadata: { price_id: "price_test" },
        ...session,
      },
    },
  });

const chargeEvent = (type: string, charge: Record<string, unknown> = {}) =>
  stamped({
    type,
    data: { object: { id: "ch_1", payment_intent: INTENT, amount: 1499, ...charge } },
  });

const disputeEvent = (type: string, dispute: Record<string, unknown> = {}) =>
  stamped({
    type,
    data: { object: { id: "dp_1", payment_intent: INTENT, ...dispute } },
  });

type Row = {
  email: string;
  key: string;
  price_id: string;
  livemode: number;
  revoked_at: string | null;
  revoked_reason: string | null;
  last_sent_at: string | null;
};

const row = (forEnv: Env): Promise<Row | null> =>
  forEnv.DB.prepare(
    "SELECT email, key, price_id, livemode, revoked_at, revoked_reason, last_sent_at FROM licenses WHERE stripe_session_id = ?",
  )
    .bind(SESSION)
    .first<Row>();

const count = async (forEnv: Env): Promise<number> =>
  (await forEnv.DB.prepare("SELECT COUNT(*) AS n FROM licenses").first<{ n: number }>())?.n ?? -1;

/** The webhook just mailed the key, so the cooldown is live; clear it. */
const cooled = async (forEnv: Env) => {
  await forEnv.DB.prepare("UPDATE licenses SET last_sent_at = NULL").run();
};

/** A paid session through the webhook, so a test can start from a licence. */
const fulfilled = async () => {
  const built = testEnv();
  const response = await webhook(built.env, completed());
  expect(response.status).toBe(200);
  return built;
};

describe("the router", () => {
  it("answers /health", async () => {
    const response = await call(new Request("https://api.test/health"), testEnv().env);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it("404s everything else, as HTML", async () => {
    const response = await call(new Request("https://api.test/nope"), testEnv().env);
    expect(response.status).toBe(404);
    expect(response.headers.get("content-type")).toContain("text/html");
  });

  it("escapes SITE_URL on the 404 page", async () => {
    const hostile = 'https://bastion.test/"><script>alert(1)</script>';
    // Cast: the generated `Env` types SITE_URL as the literal in wrangler.jsonc.
    const hostileEnv = { ...testEnv().env, SITE_URL: hostile } as unknown as Env;
    const response = await call(new Request("https://api.test/nope"), hostileEnv);
    const page = await response.text();
    expect(page).not.toContain("<script>");
    expect(page).toContain('href="https://bastion.test/&quot;&gt;&lt;script&gt;');
  });
});

describe("the webhook", () => {
  it("refuses a body signed with another secret, and mints nothing", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed(), { secret: "whsec_other" });
    expect(response.status).toBe(400);
    // Bare: the reason is for the log, not for whoever sent an unsigned body.
    expect(await response.text()).toBe("invalid signature");
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  it("refuses a body over the cap before reading it", async () => {
    const built = testEnv();
    const body = JSON.stringify({ type: "x", data: { object: { pad: "a".repeat(300 * 1024) } } });
    const response = await webhook(built.env, null, { body });
    expect(response.status).toBe(413);
  });

  it("mints, records and mails a key for a paid session", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");

    const stored = await row(built.env);
    expect(stored?.email).toBe("buyer@example.com");
    expect(stored?.price_id).toBe("price_test");
    expect(stored?.livemode).toBe(0);
    expect(stored?.last_sent_at).not.toBeNull();
    expect(built.sent).toHaveLength(1);
    expect(built.sent[0]?.to).toBe("buyer@example.com");
    expect(built.sent[0]?.key).toBe(stored?.key);
  });

  it("treats a redelivery as already done: one row, one mail", async () => {
    const built = testEnv();
    await webhook(built.env, completed());
    const again = await webhook(built.env, completed());
    expect(again.status).toBe(200);
    expect(await again.text()).toBe("already sent");
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  it("does nothing for a session that is not paid", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ payment_status: "unpaid" }));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("not paid yet");
    expect(await count(built.env)).toBe(0);
  });

  // 200, not 4xx: Stripe retries every non-2xx, and this payload will be the
  // same on every attempt. Recorded, so a redelivery is a duplicate, not a
  // second log line.
  it("drops a session with no payment status rather than guessing, and records it", async () => {
    const built = testEnv();
    const log = errorLog();
    const event = completed({ payment_status: undefined });
    const response = await webhook(built.env, event);
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("payment_status");
    expect(log()).toContain("payment_status");
    expect(await count(built.env)).toBe(0);
    expect(await recorded(built.env, event.id)).toBe(true);
    expect(await (await webhook(built.env, event)).text()).toBe("duplicate");
  });

  it("drops a session with no email", async () => {
    const built = testEnv();
    errorLog();
    const response = await webhook(built.env, completed({ customer_details: {} }));
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("no email");
    expect(await count(built.env)).toBe(0);
  });

  it("drops a signed body that is not JSON, with a 200", async () => {
    const built = testEnv();
    const log = errorLog();
    const response = await webhook(built.env, null, { body: "{not json" });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("body is not JSON");
    expect(log()).toContain("body is not JSON");
  });

  it("drops a signed charge it cannot parse, and records it", async () => {
    const built = testEnv();
    errorLog();
    const event = stamped({ type: "charge.refunded", data: { object: { amount: 1499 } } });
    const response = await webhook(built.env, event);
    expect(response.status).toBe(200);
    expect(await response.text()).toMatch(/^charge:/);
    expect(await recorded(built.env, event.id)).toBe(true);
  });

  it("returns 500 when the mail fails, keeps the row, and sends on the retry", async () => {
    let broken = true;
    const built = testEnv({}, async () => {
      if (broken) throw new Error("E_SENDER_NOT_VERIFIED");
    });
    const first = await webhook(built.env, completed());
    expect(first.status).toBe(500);
    expect(await first.text()).toMatch(/^email:/);
    expect(await count(built.env)).toBe(1);
    expect((await row(built.env))?.last_sent_at).toBeNull();

    broken = false;
    const retry = await webhook(built.env, completed());
    expect(retry.status).toBe(200);
    expect(built.sent).toHaveLength(1);
    expect(await count(built.env)).toBe(1);
  });

  it("ignores an event type it does not handle", async () => {
    const response = await webhook(
      testEnv().env,
      stamped({ type: "payment_intent.succeeded", data: { object: {} } }),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ignored");
  });
});

describe("overlapping deliveries", () => {
  // A retry landing while a slow first attempt is still sending, or a "Resend"
  // clicked in the dashboard at the wrong moment. Both used to read "not seen"
  // and "not sent" before either wrote anything, and both mailed the key.
  it("sends one mail when the same event arrives twice at once", async () => {
    const built = testEnv({}, () => pause(25));
    const event = { ...completed(), id: "evt_twice" };
    const answers = await Promise.all([webhook(built.env, event), webhook(built.env, event)]);
    expect(answers.map((answer) => answer.status)).toEqual([200, 200]);
    const texts = await Promise.all(answers.map((answer) => answer.text()));
    expect(texts).toHaveLength(2);
    expect(texts).toEqual(expect.arrayContaining(["duplicate", "ok"]));
    expect(built.sent).toHaveLength(1);
    expect(await count(built.env)).toBe(1);
  });

  // Two different events for one session, which the event gate cannot see as
  // the same thing. The claim on `last_sent_at` is what holds here.
  it("sends one mail when two events for one session arrive at once", async () => {
    const built = testEnv({}, () => pause(25));
    await Promise.all([
      webhook(built.env, completed()),
      webhook(built.env, { ...completed(), type: "checkout.session.async_payment_succeeded" }),
    ]);
    expect(built.sent).toHaveLength(1);
    expect(await count(built.env)).toBe(1);
  });

  it("gives the event back when the handler throws, so the retry is handled", async () => {
    const log = errorLog();
    const built = testEnv();
    // D1 failing mid-fulfilment: the licence insert throws, nothing else does.
    const flaky = {
      ...built.env,
      DB: {
        prepare: (sql: string) => {
          if (sql.includes("INSERT INTO licenses")) throw new Error("D1 is down");
          return built.env.DB.prepare(sql);
        },
      } as unknown as D1Database,
    };
    const event = { ...completed(), id: "evt_throws" };
    const first = await webhook(flaky, event);
    expect(first.status).toBe(500);
    expect(log()).toContain("D1 is down");
    expect(await recorded(built.env, event.id)).toBe(false);

    const retry = await webhook(built.env, event);
    expect(await retry.text()).toBe("ok");
    expect(built.sent).toHaveLength(1);
  });
});

describe("configuration", () => {
  // Every one of these used to throw from inside WebCrypto or `atob` and reach
  // Stripe as workerd's bare 500, with nothing in the log naming the secret.
  const cases: [string, Partial<Env>, RegExp][] = [
    ["an unset webhook secret", { STRIPE_WEBHOOK_SECRET: "" }, /STRIPE_WEBHOOK_SECRET is not set/],
    [
      "a webhook secret that is not one",
      { STRIPE_WEBHOOK_SECRET: "sk_live_pasted_in_the_wrong_slot" },
      /STRIPE_WEBHOOK_SECRET does not start with whsec_/,
    ],
    ["an unset signing key", { LICENSE_SIGNING_KEY: "" }, /LICENSE_SIGNING_KEY is not set/],
    [
      "a signing key that is not base64",
      { LICENSE_SIGNING_KEY: "not base64 at all!" },
      /LICENSE_SIGNING_KEY is not a base64 PKCS#8 Ed25519 private key/,
    ],
    [
      "a signing key that is base64 but not a key",
      { LICENSE_SIGNING_KEY: btoa("truncated") },
      /LICENSE_SIGNING_KEY is not a base64 PKCS#8 Ed25519 private key/,
    ],
  ];

  for (const [label, overrides, named] of cases) {
    it(`answers 500 and names the secret for ${label}`, async () => {
      const log = errorLog();
      const broken = testEnv(overrides);
      const event = { ...completed(), id: `evt_config_${label.length}` };
      const response = await webhook(broken.env, event);
      expect(response.status).toBe(500);
      const body = await response.text();
      expect(body).toBe("misconfigured");
      expect(log()).toMatch(named);
      // The log names the secret; it never carries a value.
      for (const value of Object.values(overrides)) {
        if (value) expect(log()).not.toContain(value);
      }
      expect(await count(broken.env)).toBe(0);
      expect(await recorded(broken.env, event.id)).toBe(false);

      // 500 so Stripe retries, and the retry works once the secret is fixed.
      const fixed = testEnv();
      expect(await (await webhook(fixed.env, event)).text()).toBe("ok");
      expect(fixed.sent).toHaveLength(1);
    });
  }
});

describe("the product guard", () => {
  // The mix-up this exists to stop: bastion-api and cupertino-api are two
  // webhook endpoints on ONE Stripe account, so every checkout event reaches
  // both. A Bastion buyer was mailed a Cupertino key by the other Worker.
  it("ignores a sale at another product's price, and mints nothing", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ metadata: { price_id: "price_other" } }));
    // 200, so Stripe stops. A 4xx would have it retrying a valid event for days.
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("not this product");
    expect(await count(built.env)).toBe(0);
    expect(built.sent).toEqual([]);
  });

  // The deliberate hole. A link made by hand carries no metadata and
  // `priceIdFor` returns "" on every failure including a timeout, so refusing
  // these would refund a real sale to protect a column.
  it("still fulfils a sale whose price cannot be resolved", async () => {
    const built = testEnv({ STRIPE_SECRET_KEY: "" });
    const response = await webhook(built.env, completed({ metadata: {} }));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  // With a key configured, a lookup that FAILS is not the same as one that finds
  // no price. Letting it through skipped the guard whenever Stripe was slow or
  // the key was wrong; 500 has Stripe retry until the lookup can answer.
  it("answers 500 when the price lookup fails, and mints nothing", async () => {
    errorLog();
    const fetched = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}", { status: 401 }));
    const built = testEnv({ STRIPE_SECRET_KEY: "rk_test_x" });
    const event = completed({ metadata: {} });
    const response = await webhook(built.env, event);
    expect(fetched).toHaveBeenCalledOnce();
    expect(response.status).toBe(500);
    expect(await count(built.env)).toBe(0);
    expect(await recorded(built.env, event.id)).toBe(false);
    expect(built.sent).toEqual([]);
  });

  it("guards a sale whose price came from the lookup", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      Response.json({ data: [{ price: { id: "price_other" } }] }),
    );
    const built = testEnv({ STRIPE_SECRET_KEY: "rk_test_x" });
    const response = await webhook(built.env, completed({ metadata: {} }));
    expect(await response.text()).toBe("not this product");
    expect(await count(built.env)).toBe(0);
  });

  // Unset means unguarded, which is what makes this safe to deploy before the
  // var is configured, and what the test environment runs as.
  it("fulfils any price when none is configured", async () => {
    const built = testEnv({ EXPECTED_PRICE_ID: "" });
    const response = await webhook(built.env, completed({ metadata: { price_id: "price_other" } }));
    expect(response.status).toBe(200);
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });
});

describe("refunds and disputes", () => {
  it("leaves a licence alone on a partial refund", async () => {
    const built = await fulfilled();
    const response = await webhook(
      built.env,
      chargeEvent("charge.refunded", { amount_refunded: 200 }),
    );
    expect(await response.text()).toContain("partial refund");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  it("revokes on a full refund, once", async () => {
    const built = await fulfilled();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    const when = (await row(built.env))?.revoked_at;
    expect(when).not.toBeNull();
    const again = await webhook(
      built.env,
      chargeEvent("charge.refunded", { amount_refunded: 1499 }),
    );
    expect(await again.text()).toBe("refunded: revoked 0");
    expect((await row(built.env))?.revoked_at).toBe(when);
  });

  it("says so when a refund names no payment intent", async () => {
    const built = await fulfilled();
    const response = await webhook(
      built.env,
      chargeEvent("charge.refunded", { amount_refunded: 1499, payment_intent: null }),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("nothing revoked");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  it("revokes on a dispute and restores it when the dispute is won", async () => {
    const built = await fulfilled();
    await webhook(built.env, disputeEvent("charge.dispute.created"));
    expect((await row(built.env))?.revoked_at).not.toBeNull();
    const lost = await webhook(
      built.env,
      disputeEvent("charge.dispute.closed", { status: "lost" }),
    );
    expect(await lost.text()).toContain("stays revoked");
    expect((await row(built.env))?.revoked_at).not.toBeNull();
    const won = await webhook(built.env, disputeEvent("charge.dispute.closed", { status: "won" }));
    expect(await won.text()).toBe("dispute won: restored 1");
    expect((await row(built.env))?.revoked_at).toBeNull();
  });

  // The asymmetry that used to bite: `revoke` is guarded on `revoked_at IS
  // NULL`, and the restore had no matching guard. A refunded licence whose
  // charge was later disputed and won came back to life, and the next
  // `make revocations` then dropped it from the baked-in list.
  it("does not restore a refunded licence when a later dispute is won", async () => {
    const built = await fulfilled();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    const when = (await row(built.env))?.revoked_at;
    expect(when).not.toBeNull();
    expect((await row(built.env))?.revoked_reason).toBe("refunded");

    const won = await webhook(built.env, disputeEvent("charge.dispute.closed", { status: "won" }));
    expect(await won.text()).toBe("dispute won: restored 0");
    expect((await row(built.env))?.revoked_at).toBe(when);
  });

  it("does not re-send a revoked licence", async () => {
    const built = await fulfilled();
    expect(built.sent).toHaveLength(1);
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    await cooled(built.env);

    // A "Resend" of the original event from the Stripe dashboard, past the
    // cooldown. It used to mail the dead key again, under a note promising a
    // refund that had already been paid.
    const again = await webhook(built.env, completed());
    expect(again.status).toBe(200);
    expect(await again.text()).toBe("revoked, not re-sent");
    expect(built.sent).toHaveLength(1);
  });
});

// Not a behaviour test: a claim that the bindings in wrangler.jsonc actually
// arrive. Every other test in this file injects its own limiter stub, so
// renaming or dropping one of these would leave the suite green and both public
// routes unlimited, with nothing anywhere saying so.
describe("bindings", () => {
  it("binds both rate limiters from wrangler.jsonc", () => {
    expect(typeof env.RESEND_LIMIT?.limit).toBe("function");
    expect(typeof env.THANKS_LIMIT?.limit).toBe("function");
  });
});

describe("event idempotency", () => {
  it("handles the same event id only once", async () => {
    const built = testEnv();
    const event = { ...completed(), id: "evt_fixed" };
    expect((await webhook(built.env, event)).status).toBe(200);
    expect(built.sent).toHaveLength(1);
    await cooled(built.env);

    const second = await webhook(built.env, event);
    expect(second.status).toBe(200);
    expect(await second.text()).toBe("duplicate");
    expect(built.sent).toHaveLength(1);
    expect(await count(built.env)).toBe(1);
  });

  // The retry path fulfilment depends on: a 500 must stay retryable, so a
  // failed send must NOT record the event as handled.
  it("does not record an event whose handling failed", async () => {
    let broken = true;
    const built = testEnv({}, async () => {
      if (broken) throw new Error("smtp is down");
    });
    const event = { ...completed(), id: "evt_retry" };
    expect((await webhook(built.env, event)).status).toBe(500);

    broken = false;
    const retry = await webhook(built.env, event);
    expect(retry.status).toBe(200);
    expect(await retry.text()).not.toBe("duplicate");
    expect(built.sent).toHaveLength(1);
  });
});

describe("delayed payment methods", () => {
  // SEPA and friends send `completed` with `payment_status: "unpaid"`, then
  // settle later with this. It used to fall through to "ignored": the customer
  // was charged and no key was ever minted.
  it("fulfils on async_payment_succeeded", async () => {
    const built = testEnv();
    const pending = await webhook(built.env, completed({ payment_status: "unpaid" }));
    expect(await pending.text()).toBe("not paid yet");
    expect(await count(built.env)).toBe(0);

    const settled = await webhook(built.env, {
      ...completed(),
      type: "checkout.session.async_payment_succeeded",
    });
    expect(settled.status).toBe(200);
    expect(await count(built.env)).toBe(1);
    expect(built.sent).toHaveLength(1);
  });

  it("records an async payment failure without minting anything", async () => {
    const built = testEnv();
    const failed = await webhook(built.env, {
      ...completed(),
      type: "checkout.session.async_payment_failed",
    });
    expect(failed.status).toBe(200);
    expect(await count(built.env)).toBe(0);
  });
});

describe("/thanks", () => {
  const thanks = (forEnv: Env, query = `?session_id=${SESSION}`) =>
    call(new Request(`https://api.test/thanks${query}`), forEnv);

  it("404s without a session id", async () => {
    expect((await thanks(testEnv().env, "")).status).toBe(404);
  });

  it("shows the pending page for a session the webhook has not reached yet", async () => {
    const response = await thanks(testEnv().env);
    expect(response.status).toBe(202);
    expect(await response.text()).toContain("Payment received");
  });

  it("shows the key once the licence exists", async () => {
    const built = await fulfilled();
    const response = await thanks(built.env);
    expect(response.status).toBe(200);
    const page = await response.text();
    expect(page).toContain((await row(built.env))?.key);
    expect(page).toContain("buyer@example.com");
  });

  // The page carries a licence key, addressed by a session id that never
  // expires on Stripe's side and that lands in browser history and in `Referer`.
  // The seven-day window bounds what this origin will serve; it says nothing
  // about what a proxy or a disk cache has already kept.
  it("tells caches not to keep the page with the key on it", async () => {
    const built = await fulfilled();
    const response = await thanks(built.env);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
  });

  it("stops showing the key a week after it was issued", async () => {
    const built = await fulfilled();
    const eightDaysAgo = new Date(Date.now() - 8 * 86_400_000).toISOString();
    await built.env.DB.prepare("UPDATE licenses SET issued_at = ? WHERE stripe_session_id = ?")
      .bind(eightDaysAgo, SESSION)
      .run();
    const response = await thanks(built.env);
    expect(response.status).toBe(200);
    const page = await response.text();
    expect(page).toContain("Already sent");
    expect(page).not.toContain((await row(built.env))?.key);
  });

  // `fulfil` and the resend route stopped handing out a revoked key; this page
  // kept showing it for a week to anyone holding the session id.
  it("does not show a refunded licence's key", async () => {
    const built = await fulfilled();
    const key = (await row(built.env))?.key ?? "";
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    const response = await thanks(built.env);
    expect(response.status).toBe(200);
    const page = await response.text();
    expect(page).toContain("Licence revoked");
    expect(page).not.toContain(key);
    expect(page).not.toContain("—");
  });

  it("answers the pending page when the address is over its limit", async () => {
    const built = await fulfilled();
    const limited = { ...built.env, THANKS_LIMIT: limiter(false) };
    const response = await thanks(limited);
    expect(response.status).toBe(429);
    expect(await response.text()).not.toContain((await row(built.env))?.key);
  });
});

describe("/license/resend", () => {
  const resend = (forEnv: Env, body: string, headers: Record<string, string> = {}) =>
    call(
      new Request("https://api.test/license/resend", {
        method: "POST",
        body,
        headers: { "content-type": "application/json", ...headers },
      }),
      forEnv,
    );

  it("answers ok and sends nothing for an address that is not a customer", async () => {
    const built = testEnv();
    const response = await resend(built.env, JSON.stringify({ email: "nobody@example.com" }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(built.sent).toEqual([]);
  });

  it("re-sends to a customer, and not again inside the cooldown", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    await resend(built.env, JSON.stringify({ email: "Buyer@Example.com " }));
    expect(built.sent).toHaveLength(2);
    expect(built.sent[1]?.to).toBe("buyer@example.com");
    await resend(built.env, JSON.stringify({ email: "buyer@example.com" }));
    expect(built.sent).toHaveLength(2);
  });

  it("does not re-send a revoked licence", async () => {
    const built = await fulfilled();
    await webhook(built.env, chargeEvent("charge.refunded", { amount_refunded: 1499 }));
    await cooled(built.env);
    await resend(built.env, JSON.stringify({ email: "buyer@example.com" }));
    expect(built.sent).toHaveLength(1);
  });

  it("answers identically, and sends nothing, when the address is over its limit", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    const limited = { ...built.env, RESEND_LIMIT: limiter(false) };
    const response = await resend(limited, JSON.stringify({ email: "buyer@example.com" }));
    expect(await response.json()).toEqual({ ok: true });
    expect(built.sent).toHaveLength(1);
  });

  // No CORS on this route, so a browser on another origin can only reach it
  // with a request that needs no preflight: `text/plain`, or a form.
  // Requiring JSON is what closes that.
  // The tests below that expect a send stub the limiter open. The pool's real
  // RESEND_LIMIT keys every request here on "unknown", and the tests above have
  // already spent most of its five a minute.
  it("answers 415 and sends nothing unless the body is declared JSON", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    built.env.RESEND_LIMIT = limiter(true);
    const body = JSON.stringify({ email: "buyer@example.com" });
    expect((await resend(built.env, body, { "content-type": "text/plain" })).status).toBe(415);
    expect(
      (await resend(built.env, body, { "content-type": "application/x-www-form-urlencoded" }))
        .status,
    ).toBe(415);
    expect(built.sent).toHaveLength(1);

    const declared = await resend(built.env, body, {
      "content-type": "Application/JSON; charset=utf-8",
    });
    expect(declared.status).toBe(200);
    expect(built.sent).toHaveLength(2);
  });

  it("limits by address as well as by client, and sends nothing past it", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    const keys: string[] = [];
    const byAddress: RateLimit = {
      limit: async ({ key }) => {
        keys.push(key);
        return { success: !key.startsWith("address:") };
      },
    };
    const response = await resend(
      { ...built.env, RESEND_LIMIT: byAddress },
      JSON.stringify({ email: "Buyer@Example.com" }),
      { "cf-connecting-ip": "203.0.113.7" },
    );
    expect(await response.json()).toEqual({ ok: true });
    expect(keys).toEqual(["203.0.113.7", "address:buyer@example.com"]);
    expect(built.sent).toHaveLength(1);
  });

  it("sends one mail when the same address asks several times at once", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    const slow = testEnv({ RESEND_LIMIT: limiter(true) }, () => pause(25));
    const body = JSON.stringify({ email: "buyer@example.com" });
    await Promise.all([resend(slow.env, body), resend(slow.env, body), resend(slow.env, body)]);
    expect(slow.sent).toHaveLength(1);
  });

  // The body and status were always the same; the time was not. A customer's
  // request used to wait on a D1 lookup and a mail send before answering.
  it("answers before the send, so the timing says nothing either", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const held = testEnv({ RESEND_LIMIT: limiter(true) }, () => gate);
    const context = createExecutionContext();
    const response = await worker.fetch(
      new Request("https://api.test/license/resend", {
        method: "POST",
        body: JSON.stringify({ email: "buyer@example.com" }),
        headers: { "content-type": "application/json" },
      }),
      held.env,
      context,
    );
    expect(await response.json()).toEqual({ ok: true });
    expect(held.sent).toEqual([]);
    release?.();
    await waitOnExecutionContext(context);
    expect(held.sent).toHaveLength(1);
  });

  it("answers identically to a body that is not JSON, or is too large", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    expect(await (await resend(built.env, "not json")).json()).toEqual({ ok: true });
    const large = JSON.stringify({ email: `${"a".repeat(5000)}@example.com` });
    expect(await (await resend(built.env, large)).json()).toEqual({ ok: true });
    expect(built.sent).toHaveLength(1);
  });
});
