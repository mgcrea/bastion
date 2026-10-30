# Plan

Queued work that isn't started yet. Each entry says where it came from and
where it lands in the code.

## Bump the bundled Node from 24.20.0 to 24.22.1

- **Kind:** required change (security). Queued 2026-10-25 from
  `.idea/feature-scout/2026-10-24.md`.
- **Status:** the Makefile change is made, and `make bundle` passed on
  2026-10-25: pins verified, npm 11.19.1 staged, the install probe passed, and
  the signed node runs. Committed as cef72f1 on 2026-10-25, but not released
  yet. Remove this entry once it ships in a release.
- **Source:** Node.js security releases, 2026-10-21
  (nodejs.org/en/blog/vulnerability/october-2026-security-releases). The fixed
  24.x is v24.22.1, released 2026-10-20.
- **When it bites:** already. Every build shipped since 2026-10-21 runs a Node
  with public CVEs, under every credential a profile holds:
  - CVE-2026-111497 (High), Brotli out-of-bounds write that can lead to RCE;
  - CVE-2026-105483, CVE-2026-106069 and CVE-2026-106072, bypasses of the
    `tls.checkServerIdentity()` checks;
  - CVE-2026-105481, http keep-alive response confusion;
  - plus CA bundle, OpenSSL and undici updates.

  The fix only reaches users through a Sparkle release.
- **Where:**
  - `Makefile:25`: `NODE_VERSION ?= 24.20.0`.
  - `Makefile:212-213`: `NODE_PINS`. Add the line
    `24.22.1-arm64:89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7`
    (from `SHASUMS256.txt` for v24.22.1, read 2026-10-25; check it again
    against nodejs.org when making the change).
  - `Supervisor.swift:571-573` spawns this runtime for every child. No code
    change is needed there.
- **Constraints already checked:**
  - **arm64 only.** `Makefile:26` says arm64-only is deliberate, so there is no
    x64 pin to add.
  - **npm.** 24.22.1 ships npm 11.19.1, so it stays at or above the 11.19.0
    floor that `min-release-age-exclude` needs (`Makefile:20-24`).
- **Steps:** change the version and the pin, `make bundle`, `make smoke`, then
  release through the cut-a-release skill.
