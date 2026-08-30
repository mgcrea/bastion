-- One table. It is the whole of what this project knows about anyone.
--
-- Stripe already records who paid, how much and what tax; duplicating that here
-- would mean two systems of record disagreeing eventually. What Stripe does NOT
-- know is which key was issued, and that is the only reason this exists.
--
-- `key` is stored rather than re-derived from the payment on demand. Derivation
-- looks elegant until the payload format changes once, and then no old key can
-- be reproduced and every re-send is subtly wrong.
--
-- `price_id` and `amount_paid` are recorded from the very first sale because the
-- price ladder rises: offering fair upgrade pricing at 2.0 is impossible without
-- knowing what people actually paid, and that number cannot be reconstructed
-- after the fact.
--
-- One migration, not the three cupertino's schema arrived in. Its `payment_intent`
-- and `livemode` columns were ALTERs against a table that already held real
-- sales; this database holds none yet, so replaying that history would be
-- inheriting somebody else's accidents. The columns are the same and the schema
-- ends up identical.

CREATE TABLE licenses (
  id                TEXT    PRIMARY KEY,
  email             TEXT    NOT NULL,
  major             INTEGER NOT NULL,
  key               TEXT    NOT NULL,
  -- The idempotency key. Stripe redelivers a webhook for days, and a second
  -- delivery must not mean a second licence.
  stripe_session_id TEXT    NOT NULL UNIQUE,
  -- How a refund or a dispute finds its way back to the licence. A charge knows
  -- its payment intent, never the checkout session that created it, so without
  -- this the only route back would be a Stripe API call on the one path that
  -- most needs to keep working when the network does not.
  payment_intent    TEXT    NOT NULL DEFAULT '',
  price_id          TEXT    NOT NULL DEFAULT '',
  amount_paid       INTEGER NOT NULL,
  currency          TEXT    NOT NULL,
  issued_at         TEXT    NOT NULL,
  -- Which Stripe mode minted it. The Worker signs with the real key whatever
  -- mode the event came from, because there is one signing key and one database
  -- — so a test purchase produces a licence that genuinely unlocks the shipped
  -- app. That is what makes a rehearsal meaningful, and a hole if it goes
  -- unrecorded: recorded, those keys can be found and revoked afterwards.
  livemode          INTEGER NOT NULL DEFAULT 1,
  -- Set on refund or chargeback. Read by `make revocations`, which bakes the
  -- list into the next build — revocation lands at build time, never at run
  -- time, because the app is not allowed to ask anyone anything.
  revoked_at        TEXT,
  -- Rate-limits the resend route without needing a second table.
  last_sent_at      TEXT
);

CREATE INDEX licenses_email ON licenses (email);
CREATE INDEX licenses_payment_intent ON licenses (payment_intent);
CREATE INDEX licenses_livemode ON licenses (livemode) WHERE livemode = 0;
