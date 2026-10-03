-- When an event was actually handled, beside when it was claimed.
--
-- A delivery claims its event by inserting this row, and a handler that fails
-- gives the claim back. What could never be given back is the claim of a
-- Worker that died between the insert and its answer: Stripe retried, found
-- the row, and was told "duplicate" for the rest of its retry window — so a
-- payment could end with no licence and nothing but this table saying why.
--
-- `handled_at` is set once the handler succeeds. A claim with none that is
-- more than a couple of minutes old was abandoned, and the next delivery may
-- take it over. Rows from before this column existed were all handled — a
-- failed handler deleted its row — so they are marked so.

ALTER TABLE stripe_events ADD COLUMN handled_at TEXT;
UPDATE stripe_events SET handled_at = received_at WHERE handled_at IS NULL;
