// Rendering apps/apple/Bastion/Revocations.swift from a list of revoked ids.
//
// The declaration is matched with whatever modifiers sit in front of it, and
// only its body is replaced. The first version split on `"\nenum Revocations"`;
// the file says `nonisolated enum Revocations`, so the split never matched and
// every render appended a second declaration — Swift that does not compile, on
// the one path a refund depends on. A file with no declaration at all throws
// rather than having one appended, for the same reason.
//
// Dependency-free, like everything else under scripts/lib.

const DECLARATION = /^((?:[a-z]+ +)*)enum Revocations \{[\s\S]*?^\}\n?/m;

// `JSON.stringify`, not string interpolation — the same escaper
// `generate-servers.mjs` uses for every value it writes into Swift. These ids
// come from a DATABASE rather than from servers.json, which makes this the one
// string in the release path nobody in this repo chose, and a quote or a
// backslash in one would emit Swift that does not compile.
const swiftString = (value) => JSON.stringify(value);

/**
 * `source` with the `Revocations` declaration's set replaced by `ids`, sorted.
 * Everything else in the file — the import, the doc comment, the modifiers —
 * comes through untouched.
 */
export function renderRevocations(source, ids) {
  const match = DECLARATION.exec(source);
  if (!match) throw new Error("Revocations.swift has no `enum Revocations` declaration");
  const sorted = ids.toSorted();
  const list =
    sorted.length === 0
      ? "[]"
      : `[\n${sorted.map((id) => `    ${swiftString(id)},`).join("\n")}\n  ]`;
  const declaration = `${match[1]}enum Revocations {\n  static let ids: Set<String> = ${list}\n}\n`;
  return source.slice(0, match.index) + declaration + source.slice(match.index + match[0].length);
}
