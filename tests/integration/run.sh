#!/bin/bash

# The integration tests: OmaVikunja's view of the Vikunja API v2, checked against
# a live server rather than recorded answers.
#
# Point it at a throwaway Vikunja (2.4.0 or newer, registration enabled) on this
# machine — .github/workflows/integration.yml starts one in Docker. It registers
# a user of its own, so it never needs an account or a token from you, and it
# refuses any server that is not local: these tests create users and tasks, and
# a real instance is nobody's test fixture.
#
#   tests/integration/run.sh [out-dir]       # VIKUNJA_URL, default http://localhost:3456
#
# out-dir receives fixtures/ (scrubbed v2 responses, for the client's tests)
# and token (0600, the throwaway token). Not under tests/ at the top level on
# purpose: CI and scripts/release.sh run every executable there, and this one
# needs a server they do not have.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URL="${VIKUNJA_URL:-http://localhost:3456}"
URL="${URL%/}"
OUT="${1:-$(mktemp -d)}"

host="${URL#*://}"
host="${host%%[/:]*}"
if [[ $host != localhost && $host != 127.0.0.1 ]]; then
  echo "run.sh: $URL is not on this machine — these tests only run against a throwaway local Vikunja" >&2
  exit 1
fi

# The server may still be migrating its database. /info needs no auth, so it
# answers as soon as the API is up.
echo "waiting for $URL ..."
for (( attempt = 0; attempt < 60; attempt++ )); do
  curl -fsS --noproxy '*' -o /dev/null "$URL/api/v2/info" 2>/dev/null && break
  sleep 1
done
if ! curl -fsS --noproxy '*' -o /dev/null "$URL/api/v2/info"; then
  echo "run.sh: no Vikunja API v2 at $URL after 60s" >&2
  exit 1
fi

mkdir -p "$OUT"
python3 -I "$ROOT/tests/integration/check.py" "$URL" "$OUT"
