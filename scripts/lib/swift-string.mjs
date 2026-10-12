// A Swift string literal, for the generators that write Swift source.
//
// JSON.stringify gets most of the way: JSON and Swift agree on `\"`, `\\`,
// `\n`, `\r` and `\t`, and non-ASCII (em dashes, «», typographic quotes) comes
// out literally as UTF-8. They disagree on the rest. JSON writes a control
// character as `\b`, `\f` or `\u00XX`, and Swift has no `\b` or `\f` and spells
// a scalar `\u{XX}`, so a stray control character in CHANGELOG.md or
// servers.json generated Swift that did not compile.

/**
 * @param {string} value
 * @returns {string}
 */
export const swiftString = (value) =>
  JSON.stringify(value).replace(
    // Left to right, so an escaped backslash is consumed as a pair and the
    // character after it is never read as the start of an escape.
    /\\(?:(\\)|b|f|u([0-9a-fA-F]{4}))/g,
    (match, backslash, hex) => {
      if (backslash) return match;
      if (match === "\\b") return "\\u{8}";
      if (match === "\\f") return "\\u{C}";
      return `\\u{${hex.toUpperCase().replace(/^0+(?=.)/, "")}}`;
    },
  );
