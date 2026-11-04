#!/usr/bin/env bash
# SSO regression tests: log in to each Keycloak-backed service as the
# sso-regression user and check the result.
#
#   bash tests/sso/run.sh              all tests/sso/*.test.sh
#   bash tests/sso/run.sh grafana      only tests/sso/grafana.test.sh
#
# Run on ace as root. The test user is enabled only while this runs.
set -uo pipefail
cd "$(dirname "$0")"
# One run at a time: every run toggles the shared sso-regression user (and
# its groups), so overlapping runs break each other.
exec 8>/run/sso-tests.lock
if ! flock -n 8; then
  echo "another tests/sso run is in progress; waiting for it (up to 30 min)..." >&2
  flock -w 1800 8 || { echo "gave up waiting for the tests/sso lock" >&2; exit 1; }
fi

PATH=$(nix build --no-link --print-out-paths nixpkgs#jq.bin 2>/dev/null)/bin:$PATH
export PATH
. ./lib.sh

trap 'sso_user_enabled false || true; rm -rf "$SSO_TMP"' EXIT
sso_user_enabled true || exit 1

tests=()
if [ $# -gt 0 ]; then
  for t in "$@"; do tests+=("$t.test.sh"); done
else
  tests=(*.test.sh)
fi

for t in "${tests[@]}"; do
  [ -f "$t" ] || { echo "no such test: $t" >&2; SSO_FAIL=$((SSO_FAIL + 1)); continue; }
  echo "== ${t%.test.sh}"
  # shellcheck disable=SC1090
  . "./$t"
done

echo
echo "passed $SSO_PASS, failed $SSO_FAIL"
[ "$SSO_FAIL" -eq 0 ]
