// Tests for the Revocations.swift renderer.
//
// The failure this guards against shipped once already: the generator split the
// file on `"\nenum Revocations"`, the declaration gained `nonisolated` in the
// same commit that created it, and the split never matched again. Nothing ran
// the generator against the real file, so the first refund would have written a
// second `enum Revocations` and a build that does not compile — with
// revocation, the only enforcement point, dead behind it.
//
// So every assertion here runs against the file the app actually compiles.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { renderRevocations, testDatabaseConfigured } from "./revocations.mjs";

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const source = readFileSync(join(root, "apps/apple/Bastion/Revocations.swift"), "utf8");

const declarations = (text) => text.match(/\benum Revocations\b/g)?.length ?? 0;

describe("renderRevocations", () => {
  it("leaves the committed file unchanged when the list is unchanged", () => {
    assert.equal(renderRevocations(source, []), source);
  });

  it("writes revoked ids into the one declaration, keeping its modifiers", () => {
    const next = renderRevocations(source, ["lic_b", "lic_a"]);
    assert.equal(declarations(next), 1);
    assert.match(next, /\nnonisolated enum Revocations \{/);
    assert.match(next, /"lic_a",\n {4}"lic_b",/);
  });

  it("round-trips: rendering its own output with the same ids changes nothing", () => {
    const once = renderRevocations(source, ["lic_a"]);
    assert.equal(renderRevocations(once, ["lic_a"]), once);
    assert.equal(renderRevocations(once, []), source);
  });

  it("escapes an id rather than emitting Swift that does not compile", () => {
    assert.match(renderRevocations(source, ['a"b\\c']), /"a\\"b\\\\c",/);
  });

  it("throws on a file with no declaration rather than appending one", () => {
    assert.throws(() => renderRevocations("import Foundation\n", []), /no `enum Revocations`/);
  });
});

// The test environment signs with the production key, so that a test purchase
// proves the shipped app accepts it. That makes every key it mints a real one,
// and the generator revokes all of them — but only once the database exists,
// which is when wrangler.jsonc gains its id. Before that there is nothing to
// read, and reading anyway would fail every run.
describe("testDatabaseConfigured", () => {
  const wrangler = readFileSync(join(root, "apps/api/wrangler.jsonc"), "utf8");

  it("is false for the committed config, whose test database has no id yet", () => {
    assert.equal(testDatabaseConfigured(wrangler), false);
  });

  it("is true once the test database's binding carries an id", () => {
    const configured = wrangler.replace(
      /("database_name":\s*"bastion-licenses-test",)/,
      '$1\n          "database_id": "00000000-0000-0000-0000-000000000000",',
    );
    assert.notEqual(configured, wrangler);
    assert.equal(testDatabaseConfigured(configured), true);
  });

  it("is not fooled by the production database's id", () => {
    assert.match(wrangler, /"database_id"\s*:\s*"[^"]+"/);
    assert.equal(testDatabaseConfigured(wrangler), false);
  });
});
