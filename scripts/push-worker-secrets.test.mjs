// Tests for the guard rails on `push-worker-secrets.mjs`.
//
// ONLY the refusal paths, and that is a deliberate ceiling rather than a thin
// suite: every case below exits before `wrangler` is spawned. A test that got as
// far as the push would be a test that writes secrets to the Worker taking real
// money, which is exactly the accident this script now exists to prevent.
//
// The refusal that matters most is the last one. `.test.vars.example` documents
// a rehearsal against a test-mode deployment, but `wrangler secret bulk` writes
// to the DEFAULT environment unless told otherwise — so following those
// instructions replaced the live webhook signing secret with a test-mode one,
// and every genuine payment was then refused as an invalid signature.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "push-worker-secrets.mjs");
const work = mkdtempSync(join(tmpdir(), "bastion-secrets-"));
after(() => rmSync(work, { recursive: true, force: true }));

/** Run the script and return what it said, never letting it reach wrangler. */
const run = (contents, extra = []) => {
  const file = join(work, `${Math.random().toString(36).slice(2)}.vars`);
  writeFileSync(file, contents);
  try {
    execFileSync(process.execPath, [SCRIPT, file, ...extra], { encoding: "utf8" });
    return { code: 0, output: "" };
  } catch (error) {
    return { code: error.status, output: String(error.stderr ?? "") };
  }
};

const TEST_MODE =
  "LICENSE_SIGNING_KEY=k\nSTRIPE_WEBHOOK_SECRET=whsec_test_x\nSTRIPE_SECRET_KEY=sk_test_x\n";

describe("push-worker-secrets", () => {
  it("refuses test-mode credentials when no environment is named", () => {
    const { code, output } = run(TEST_MODE);
    assert.equal(code, 2);
    assert.match(output, /TEST-mode Stripe credentials and no --env/);
    // The message has to name the fix, not just the problem.
    assert.match(output, /--env test/);
  });

  it("refuses --env with no name after it", () => {
    const { code, output } = run(TEST_MODE, ["--env"]);
    assert.equal(code, 2);
    assert.match(output, /--env needs a name/);
  });

  it("refuses a set with an empty value", () => {
    const { code, output } = run("LICENSE_SIGNING_KEY=\nSTRIPE_WEBHOOK_SECRET=whsec_live\n");
    assert.equal(code, 2);
    assert.match(output, /LICENSE_SIGNING_KEY is empty/);
  });

  it("refuses a file that defines nothing", () => {
    const { code, output } = run("# just a comment\n");
    assert.equal(code, 2);
    assert.match(output, /defines no KEY=VALUE pairs/);
  });

  it("refuses a file that is not there", () => {
    let code = 0;
    let output = "";
    try {
      execFileSync(process.execPath, [SCRIPT, join(work, "absent.vars")], { encoding: "utf8" });
    } catch (error) {
      code = error.status;
      output = String(error.stderr ?? "");
    }
    assert.equal(code, 2);
    assert.match(output, /cannot read/);
  });
});
