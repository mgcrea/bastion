// The generators' Swift string literals, checked against what Swift accepts.
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { swiftString } from "./swift-string.mjs";

describe("swiftString", () => {
  it("keeps the escapes JSON and Swift share", () => {
    assert.equal(swiftString('a"b\\c\nd\te\rf'), '"a\\"b\\\\c\\nd\\te\\rf"');
  });

  // JSON writes these as \b, \f and \u00XX, none of which Swift has: a stray
  // control character in the CHANGELOG or the catalog generated Swift that did
  // not compile.
  it("writes control characters the way Swift spells them", () => {
    assert.equal(swiftString("a\bb\fc\u0001d\u001fe"), '"a\\u{8}b\\u{C}c\\u{1}d\\u{1F}e"');
  });

  it("does not mistake an escaped backslash for an escape", () => {
    assert.equal(swiftString("\\b and \\u0041"), '"\\\\b and \\\\u0041"');
  });

  it("leaves non-ASCII literal", () => {
    assert.equal(swiftString("a — «b»"), '"a — «b»"');
  });
});
