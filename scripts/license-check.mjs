#!/usr/bin/env node
// The cases `scripts/license-check.swift` runs through the real verifier.
//
// Emits JSON on stdout and nothing else, so `make license-check` can pipe it
// straight in. Every key here is minted for the check and thrown away; none is
// ever issued to anyone.
//
// The signing key is the real one, from `.env`, because that is the point:
// verifying a key signed by a throwaway keypair would prove the two languages
// agree about an algorithm while saying nothing about whether the public half
// compiled into the app matches the private half sitting on this machine. That
// mismatch is the one that refuses every key ever sold.
//
//   node --env-file-if-exists=.env scripts/license-check.mjs

import { KEY_PREFIX, mint, parse, PUBLIC_KEY, publicKeyOf } from "./lib/license.mjs";

const privateKey = process.env.LICENSE_SIGNING_KEY;
if (!privateKey) {
  console.error("FATAL: set LICENSE_SIGNING_KEY in .env (see scripts/mint-license.mjs --keygen)");
  process.exit(2);
}
if (publicKeyOf(privateKey) !== PUBLIC_KEY) {
  console.error("FATAL: LICENSE_SIGNING_KEY does not match PUBLIC_KEY in scripts/lib/license.mjs.");
  console.error("Every key signed with it would be refused by the app. Fix before issuing any.");
  process.exit(2);
}

const genuine = mint({ email: "buyer@example.com", major: 1, privateKey });

/** Re-encode claims without re-signing — what forging a key actually looks like. */
const tamper = (key, changes) => {
  const { claims, signature } = parse(key);
  const payload = Buffer.from(JSON.stringify({ ...claims, ...changes })).toString("base64url");
  return `${KEY_PREFIX}.${payload}.${signature}`;
};

console.log(
  JSON.stringify([
    { label: "a genuine key", key: genuine, major: 1, expect: true },
    {
      label: "the same key with whitespace around it",
      key: `\n  ${genuine}  \n`,
      major: 1,
      expect: true,
    },
    {
      label: "a forged email",
      key: tamper(genuine, { email: "thief@example.com" }),
      major: 1,
      expect: false,
      reason: "signature does not match",
    },
    {
      label: "a forged major",
      key: tamper(genuine, { major: 2 }),
      major: 1,
      expect: false,
      reason: "signature does not match",
    },
    {
      label: "a key for another major",
      key: mint({ email: "buyer@example.com", major: 2, privateKey }),
      major: 1,
      expect: false,
      reason: "key covers 2.x, this build is 1.x",
    },
    {
      label: "an unknown prefix",
      key: genuine.replace(/^bas1\./, "bas2."),
      major: 1,
      expect: false,
      reason: "unknown key format 'bas2'",
    },
    { label: "an empty key", key: "", major: 1, expect: false, reason: "no licence key" },
  ]),
);
