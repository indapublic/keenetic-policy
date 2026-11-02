#!/bin/bash
# Runs the CLI against tests/mock_router.py: no real router, no keychain.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN="$REPO_DIR/KeeneticPolicy.app/Contents/MacOS/KeeneticPolicy"
PORT=${PORT:-8766}
WORK=$(mktemp -d)
SERVER=

cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
expect() { case "$2" in *"$1"*) ;; *) fail "expected '$1' in: $2" ;; esac }

python3 "$REPO_DIR/tests/mock_router.py" "$PORT" &
SERVER=$!
sleep 1

mkdir -p "$WORK/.config/keenetic-policy"
printf '{"host":"127.0.0.1:%s","login":"admin","mac":"a0:78:17:a3:67:09","language":"en"}' \
  "$PORT" > "$WORK/.config/keenetic-policy/config.json"

export HOME="$WORK"
export KEENETIC_POLICY_PASSWORD=secret

out=$("$BIN" --check) || fail "--check exited non-zero"
expect "VPN" "$out"
expect "Policy0" "$out"
expect "Work" "$out"

[ "$("$BIN" --current)" = "Policy1" ] || fail "--current should be Policy1"

"$BIN" --set Policy2 >/dev/null || fail "--set Policy2"
[ "$("$BIN" --current)" = "Policy2" ] || fail "policy should be Policy2"

"$BIN" --set default >/dev/null || fail "--set default"
[ -z "$("$BIN" --current)" ] || fail "policy should be the default one"

out=$("$BIN" --set Policy0) || fail "--set Policy0"
expect "Policy0" "$out"

out=$("$BIN" --version) || fail "--version"
expect "KeeneticPolicy" "$out"

out=$("$BIN" --help) || fail "--help"
expect "--setup" "$out"

echo "ok"
