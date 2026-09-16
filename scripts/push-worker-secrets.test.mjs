// Tests for the guard rails on `push-worker-secrets.mjs`.
//
// ONLY the refusal paths, and that is a deliberate ceiling rather than a thin
// suite: every case below exits before `wrangler` is spawned. A test that got as
// far as the push would be a test that writes secrets to the Worker taking real
// money, which is exactly the accident this script now exists to prevent.
//
// The refusals that matter most are the ones about `--env`. `.test.vars.example`
// documents a rehearsal against a test-mode deployment, but `wrangler secret
// bulk` writes to the DEFAULT environment unless told otherwise — so following
// those instructions replaced the live webhook signing secret with a test-mode
// one, and every genuine payment was then refused as an invalid signature.
//
// Every fixture that could otherwise pass the checks carries a flaw that is
// refused, so nothing here is ever one bug away from a real push.

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

/**
 * Run the script and return what it said, never letting it reach wrangler.
 * `name` matters now that the file name is itself a check, so each run gets its
 * own directory and a `.prod.vars` in one cannot leak into another.
 */
const run = (contents, extra = [], name = "secrets.vars") => {
  const file = join(mkdtempSync(join(work, "case-")), name);
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

/**
 * What a real `.test.vars` looks like, and why the fixture above was not enough.
 * Stripe's test-mode webhook secret is `whsec_` and random characters, exactly
 * like a live one; the signing key is the production key by design; and there is
 * no API key. Nothing in it says "test", so the marker check waved it through
 * to the production Worker. Made-up values of the right shape, not real ones.
 */
const REALISTIC_TEST_MODE =
  "LICENSE_SIGNING_KEY=MC4CAQAwBQYDK2VwBCIEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n" +
  "STRIPE_WEBHOOK_SECRET=whsec_Zq3VbN8xKp2LmR7tYw4sHd9cJf6gUe1a\n";

describe("push-worker-secrets", () => {
  it("refuses test-mode credentials when no environment is named", () => {
    const { code, output } = run(TEST_MODE);
    assert.equal(code, 2);
    assert.match(output, /TEST-mode Stripe credentials and no --env/);
    // The message has to name the fix, not just the problem.
    assert.match(output, /--env test/);
  });

  it("refuses a realistic test-mode file, with no marker in it, when no environment is named", () => {
    const { code, output } = run(REALISTIC_TEST_MODE, [], ".test.vars");
    assert.equal(code, 2);
    assert.match(output, /not \.prod\.vars/);
    assert.match(output, /--env test/);
  });

  it("refuses any file but .prod.vars without --env, whatever it holds", () => {
    const { code, output } = run(REALISTIC_TEST_MODE, [], "prod.vars.backup");
    assert.equal(code, 2);
    assert.match(output, /not \.prod\.vars/);
  });

  // Still refused when the file IS .prod.vars: the marker check is the second
  // line, for test credentials pasted into the production file itself.
  it("refuses test-mode markers in .prod.vars", () => {
    const { code, output } = run(TEST_MODE, [], ".prod.vars");
    assert.equal(code, 2);
    assert.match(output, /TEST-mode Stripe credentials/);
  });

  // Judged as wrangler reads the file, which is dotenv. Both of these used to
  // pass the empty check here and went up as an empty secret.
  it('refuses a value that is only quotes, KEY=""', () => {
    const { code, output } = run(
      'LICENSE_SIGNING_KEY=k\nSTRIPE_WEBHOOK_SECRET=""\n',
      [],
      ".prod.vars",
    );
    assert.equal(code, 2);
    assert.match(output, /STRIPE_WEBHOOK_SECRET is empty/);
  });

  it("refuses a value that is only an inline comment", () => {
    const { code, output } = run(
      "LICENSE_SIGNING_KEY=k\nSTRIPE_WEBHOOK_SECRET= # paste from the dashboard\n",
      [],
      ".prod.vars",
    );
    assert.equal(code, 2);
    assert.match(output, /STRIPE_WEBHOOK_SECRET is empty/);
  });

  it("sees an `export KEY=` line, as wrangler does", () => {
    const { code, output } = run(
      "export LICENSE_SIGNING_KEY=\nSTRIPE_WEBHOOK_SECRET=whsec_live\n",
      [],
      ".prod.vars",
    );
    assert.equal(code, 2);
    assert.match(output, /LICENSE_SIGNING_KEY is empty/);
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
