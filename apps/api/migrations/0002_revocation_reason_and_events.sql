-- Two gaps that both showed up the same way: the Worker could not tell one
-- event from another, or one revocation from another.
--
-- `revoked_reason` exists because `charge.dispute.closed` with status `won`
-- un-revoked a licence unconditionally. A licence revoked by a REFUND, whose
-- charge was later also disputed and won, was silently restored — and the next
-- `make revocations` then dropped it from the baked-in list, handing the key
-- back to someone who had already been paid back. Restoring now requires that
-- the dispute is what took it away.
--
-- `stripe_events` exists because the only idempotency key was
-- `licenses.stripe_session_id`, which stops a second LICENCE and nothing else.
-- Past the five-minute send cooldown, any redelivery or manual re-send from the
-- dashboard mailed the key again. The row is written only after the event has
-- been handled successfully, so a 500 still leaves Stripe free to retry — which
-- is the behaviour fulfilment depends on.

ALTER TABLE licenses ADD COLUMN revoked_reason TEXT;

CREATE TABLE stripe_events (
  id          TEXT PRIMARY KEY,
  type        TEXT NOT NULL,
  received_at TEXT NOT NULL
);
