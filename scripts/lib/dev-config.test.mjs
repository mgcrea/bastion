// Tests for the dev.json a clone leaves behind.
//
// The failure this guards against: `make dev-clone` moved dev.json into the
// backup so every server would run from its installed tree — but a Debug build
// embeds no node, and dev.json is the only place it finds one. After a clone,
// every child server failed with "this build has no embedded node runtime".

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { runtimeOnlyDevConfig } from "./dev-config.mjs";

describe("runtimeOnlyDevConfig", () => {
  it("keeps the node and drops the checkout", () => {
    const before = JSON.stringify({ node: "/opt/node/bin/node", repo: "/src/mgcrea-ai" });
    assert.deepEqual(JSON.parse(runtimeOnlyDevConfig(before, "/fallback/node")), {
      node: "/opt/node/bin/node",
    });
  });

  it("names the fallback node when there was no dev.json", () => {
    assert.deepEqual(JSON.parse(runtimeOnlyDevConfig(null, "/fallback/node")), {
      node: "/fallback/node",
    });
  });

  it("names the fallback node when dev.json is unreadable or has no node", () => {
    for (const text of ["{ not json", JSON.stringify({ repo: "/src" }), JSON.stringify([1])]) {
      assert.deepEqual(JSON.parse(runtimeOnlyDevConfig(text, "/fallback/node")), {
        node: "/fallback/node",
      });
    }
  });

  it("ends in a newline, like the file `make dev-config` writes", () => {
    assert.match(runtimeOnlyDevConfig(null, "/n"), /\}\n$/);
  });
});
