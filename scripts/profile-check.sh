#!/usr/bin/env bash
# Would this profile let a build signed by this identity, with these
# entitlements, launch?
#
#   scripts/profile-check.sh <profile> <identity SHA-1> <entitlements>
#
# The four entitlements on the Release build are restricted, and the system
# validates them against the embedded profile at every launch. A build whose
# profile has expired, does not list the certificate that signed it, or does not
# grant one of its entitlement values is killed at launch, on a user's Mac,
# after `codesign --verify`, notarization and `spctl` have all passed — none of
# them asks. The likely way in is a renewed certificate: the Developer ID one
# expires 2031-08-21, a team can hold several, and `make sign` takes the first
# it finds. So `make sign` asks this before it signs.
#
# Fails closed: if the profile cannot be decoded or python3 cannot run, it
# refuses rather than passing.
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 <profile> <identity SHA-1> <entitlements>" >&2; exit 2; }
profile="$1" identity="$2" entitlements="$3"

decoded="$(security cms -D -i "$profile" 2>/dev/null)" \
  || { echo "  $profile could not be decoded as a provisioning profile" >&2; exit 1; }

printf '%s' "$decoded" | python3 -c '
import datetime, fnmatch, hashlib, plistlib, sys

identity, entitlements_path = sys.argv[1].upper(), sys.argv[2]
profile = plistlib.loads(sys.stdin.buffer.read())
with open(entitlements_path, "rb") as f:
    wanted = plistlib.load(f)
problems = []

expires = profile.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc)
if expires is None or expires.replace(tzinfo=datetime.timezone.utc) <= now:
    problems.append(f"the profile expired on {expires}")

listed = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
if identity not in listed:
    problems.append(
        f"the profile does not list the signing certificate {identity}; "
        "a renewed certificate needs a regenerated profile"
    )

granted = profile.get("Entitlements", {})
def covered(value, grant):
    grants = grant if isinstance(grant, list) else [grant]
    values = value if isinstance(value, list) else [value]
    return all(any(fnmatch.fnmatchcase(str(v), str(g)) for g in grants) for v in values)
for key, value in wanted.items():
    if key not in granted:
        problems.append(f"the profile does not grant {key}")
    elif not covered(value, granted[key]):
        problems.append(f"the profile grants {key} as {granted[key]}, which does not cover {value}")

for p in problems:
    print(f"  {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
' "$identity" "$entitlements" \
  || { echo "  $profile cannot validate this build — it would be killed at launch" >&2; exit 1; }

echo "  the profile lists the signing certificate, covers every entitlement, and has not expired"
