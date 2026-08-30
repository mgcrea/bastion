#!/usr/bin/env node
// Mint a licence key, or generate the keypair that signs them.
//
// This is the whole issuing lane for now. There is no payment webhook behind it
// — a comped licence, a support reply, a replacement for someone who lost
// theirs, and every test in scripts/lib/license.test.mjs need a key with no
// payment attached, and today so does every sale. Rare enough not to deserve a
// UI, frequent enough to deserve a command.
//
// The signing key is read from the environment rather than a flag on purpose:
// flags land in shell history and in `ps`, and this one is the only secret in
// the whole scheme. Losing it means no new keys can ever be issued for that
// major version; leaking it means anyone can issue their own.
//
//   node scripts/mint-license.mjs --keygen
//   LICENSE_SIGNING_KEY=… node scripts/mint-license.mjs --email=a@b.c --major=1
//   LICENSE_SIGNING_KEY=… node scripts/mint-license.mjs --email=a@b.c --out=./a.license

import { writeFileSync } from "node:fs";

import { generateKeypair, mint, parse, publicKeyOf } from "./lib/license.mjs";

const argv = process.argv.slice(2);
const has = (flag) => argv.includes(flag);
const valueOf = (name, fallback) =>
  argv.find((argument) => argument.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const json = has("--json");

if (has("--keygen")) {
  const keys = generateKeypair();
  if (json) {
    console.log(JSON.stringify(keys, null, 2));
    process.exit(0);
  }
  const L = [];
  L.push("KEYPAIR");
  L.push("  Generated once per major version. Generate it offline and back the");
  L.push("  private half up somewhere that is not this machine.");
  L.push("");
  L.push("  LICENSE_SIGNING_KEY — secret, never commit, never pass as a flag:");
  L.push(`    ${keys.privateKey}`);
  L.push("");
  L.push("  public key — paste into BOTH, they are asserted equal by the tests:");
  L.push("    scripts/lib/license.mjs              PUBLIC_KEY");
  L.push("    apps/apple/Bastion/License.swift     publicKey");
  L.push(`    ${keys.publicKey}`);
  console.log(L.join("\n"));
  process.exit(0);
}

const privateKey = process.env.LICENSE_SIGNING_KEY;
if (!privateKey) {
  console.error("FATAL: set LICENSE_SIGNING_KEY (see --keygen)");
  process.exit(2);
}

const email = valueOf("email", "");
if (!email.includes("@")) {
  console.error("FATAL: --email=<address> is required, and must look like one");
  process.exit(2);
}

const major = Number(valueOf("major", "1"));
if (!Number.isInteger(major) || major < 1) {
  console.error(`FATAL: --major must be a positive integer, got '${major}'`);
  process.exit(2);
}

const key = mint({ email, major, privateKey });
const { claims } = parse(key);
const out = valueOf("out", "");
if (out) writeFileSync(out, `${key}\n`);

if (json) {
  console.log(JSON.stringify({ claims, key, publicKey: publicKeyOf(privateKey) }, null, 2));
  process.exit(0);
}

const L = [];
L.push("LICENCE");
L.push(`  id      : ${claims.id}`);
L.push(`  email   : ${claims.email}`);
L.push(`  major   : ${claims.major}.x`);
L.push(`  issued  : ${claims.issuedAt}`);
L.push("");
L.push("KEY");
L.push(`  ${key}`);
if (out) {
  L.push("");
  L.push(`  written to ${out}`);
}
console.log(L.join("\n"));
