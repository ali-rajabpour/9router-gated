#!/usr/bin/env bash
# Post-deploy security checks. Run from a client machine, against whichever
# access mode you deployed.
#
# The first check matters most. Both access modes reach 9router over a
# loopback hop, and 9router grants local requests privileged access: keyless
# /v1, password reset, and the process-spawning routes. These assert that the
# hop did not leak those privileges.
#
# Usage:
#   ./verify.sh https://9router.<your-tailnet>.ts.net   # Tailscale mode
#   ./verify.sh http://127.0.0.1:20128                  # SSH mode, tunnel up
#   ./verify.sh http://100.64.0.1                       # Headscale mode, router mesh IP

set -uo pipefail

# Bare hostname is accepted for convenience; assume Tailscale mode.
normalize() {
  case "$1" in
    http://*|https://*) printf '%s' "${1%/}" ;;
    *) printf '%s' "https://${1%/}" ;;
  esac
}

# ./verify.sh --self-test exercises the normalization without touching a server.
if [ "${1:-}" = "--self-test" ]; then
  t() { [ "$(normalize "$1")" = "$2" ] || { echo "self-test FAIL: $1 -> $(normalize "$1"), want $2"; exit 1; }; }
  t "9router.example.ts.net"        "https://9router.example.ts.net"
  t "https://9router.example.ts.net/" "https://9router.example.ts.net"
  t "http://127.0.0.1:20128"        "http://127.0.0.1:20128"
  t "http://127.0.0.1:20128/"       "http://127.0.0.1:20128"
  echo "self-test ok"; exit 0
fi

BASE="${1:-}"
[ -z "$BASE" ] && { echo "usage: $0 <base-url>   ($0 --self-test)"; exit 2; }
BASE="$(normalize "$BASE")"

fails=0

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok    $label ($got)"
  else
    echo "  FAIL  $label: expected $want, got $got"
    fails=$((fails + 1))
  fi
}

# curl already prints 000 when it cannot connect, so do not append another.
code() {
  local c
  c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null)"
  printf '%s' "${c:-000}"
}

echo "checking $BASE"

# Unauthenticated LLM API must be rejected. If this returns 200, 9router
# thinks the request is local and your provider tokens are usable by anyone
# who can reach it.
check "/v1/models without API key" 401 "$(code "$BASE/v1/models")"

# Local-only route: spawns child processes / reads host secrets.
check "/api/mcp/ blocked" 403 "$(code "$BASE/api/mcp/")"

# Deny-by-default on /api/*.
check "/api/settings unauthenticated" 401 "$(code "$BASE/api/settings")"

# Dashboard should redirect to login rather than render.
check "/dashboard redirects" 307 "$(code "$BASE/dashboard")"

echo
echo "on the VPS, confirm what is published to the host:"
echo "  ss -tlnp | grep -E '20128|8787'"
echo "  Tailscale mode: expect no output."
echo "  SSH mode:       expect 127.0.0.1:20128 only, never 0.0.0.0."
echo "  Headscale mode: expect no output (9router in sidecar netns)."

[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
