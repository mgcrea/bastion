/**
 * The dev.json a clone leaves in the Debug build: the node runtime, no checkout.
 *
 * A Debug build embeds no node — `make bundle` stages one into Release builds
 * only — so dev.json's `node` is the only runtime it can spawn a child with.
 * Its `repo` is the other half, the one a clone means to switch off: with it,
 * every server built in that checkout runs from there instead of the installed
 * tree the Release app runs. So the clone keeps the first and drops the second.
 *
 * `fallbackNode` is for a Debug build that never had a dev.json, or has one
 * that cannot be read; the clone passes the node on its PATH.
 *
 * @param {string | null} text the current dev.json, or null when there is none
 * @param {string} fallbackNode
 * @returns {string}
 */
export const runtimeOnlyDevConfig = (text, fallbackNode) => {
  let node = fallbackNode;
  try {
    const parsed = JSON.parse(text ?? "null");
    if (typeof parsed?.node === "string" && parsed.node !== "") node = parsed.node;
  } catch {
    // Unreadable, so the fallback.
  }
  return `${JSON.stringify({ node }, null, 2)}\n`;
};
