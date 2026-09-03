// The handlers, in workerd, against a real D1.
//
// Every test builds its own `env` on top of the pool's: the real database, a
// stub in place of Email Service that records what it was asked to send, a
// keypair minted for the run, and the webhook secret the signatures below use.
// The table is emptied before each test, so each one seeds what it needs.
import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

import worker from "../../src/index";

const SECRET = "whsec_test";
const SESSION = "cs_test_1";
const INTENT = "pi_test_1";

// The pool shares one D1 across the file, so every test starts from an empty
// table rather than from whatever the previous one left.
beforeEach(async () => {
  await env.DB.prepare("DELETE FROM licenses").run();
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

const call = async (request: Request, forEnv: Env): Promise<Response> => {
  const context = createExecutionContext();
  const response = await worker.fetch(request, forEnv);
  await waitOnExecutionContext(context);
  return response;
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

const completed = (session: Record<string, unknown> = {}, livemode = false) => ({
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

const chargeEvent = (type: string, charge: Record<string, unknown> = {}) => ({
  type,
  data: { object: { id: "ch_1", payment_intent: INTENT, amount: 1499, ...charge } },
});

const disputeEvent = (type: string, dispute: Record<string, unknown> = {}) => ({
  type,
  data: { object: { id: "dp_1", payment_intent: INTENT, ...dispute } },
});

type Row = {
  email: string;
  key: string;
  price_id: string;
  livemode: number;
  revoked_at: string | null;
  last_sent_at: string | null;
};

const row = (forEnv: Env): Promise<Row | null> =>
  forEnv.DB.prepare(
    "SELECT email, key, price_id, livemode, revoked_at, last_sent_at FROM licenses WHERE stripe_session_id = ?",
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
});

describe("the webhook", () => {
  it("refuses a body signed with another secret, and mints nothing", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed(), { secret: "whsec_other" });
    expect(response.status).toBe(400);
    expect(await response.text()).toMatch(/^signature:/);
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

  it("refuses a session with no payment status rather than guessing", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ payment_status: undefined }));
    expect(response.status).toBe(400);
    expect(await response.text()).toContain("payment_status");
    expect(await count(built.env)).toBe(0);
  });

  it("refuses a session with no email", async () => {
    const built = testEnv();
    const response = await webhook(built.env, completed({ customer_details: {} }));
    expect(response.status).toBe(400);
    expect(await count(built.env)).toBe(0);
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
    const response = await webhook(testEnv().env, {
      type: "payment_intent.succeeded",
      data: { object: {} },
    });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ignored");
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

  it("answers identically to a body that is not JSON, or is too large", async () => {
    const built = await fulfilled();
    await cooled(built.env);
    expect(await (await resend(built.env, "not json")).json()).toEqual({ ok: true });
    const large = JSON.stringify({ email: `${"a".repeat(5000)}@example.com` });
    expect(await (await resend(built.env, large)).json()).toEqual({ ok: true });
    expect(built.sent).toHaveLength(1);
  });
});
