-- A refund or a dispute that arrives before the licence it revokes.
--
-- Fulfilment answers 500 until the key is mailed, and Stripe retries it for
-- days. A buyer refunded inside that window sent a `charge.refunded` that
-- matched no row: `revoke` changed nothing, answered 200, and the event was
-- marked handled. The fulfilment retry then minted and mailed a licence for
-- money already returned, and nothing ever revoked it.
--
-- So a revocation that finds no licence is written down here, by payment
-- intent, and fulfilment checks it: the licence is still recorded, so a won
-- dispute can restore it and the resend route can deliver it then, but it is
-- recorded revoked and not mailed.
--
-- Rows from another product's charges land here too, since this Worker and
-- cupertino-api share a Stripe account. They are rare, small and never read
-- except by a payment intent this Worker sold, so they are left alone.

CREATE TABLE early_revocations (
  payment_intent TEXT PRIMARY KEY,
  reason         TEXT NOT NULL,
  revoked_at     TEXT NOT NULL
);
