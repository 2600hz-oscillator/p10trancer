#!/usr/bin/env bash
# Pull /Documents/p10e.log and /Documents/screenshots/* from the iPad.
# Run this any time after the app has been running on device.
#
# Workflow:
#   1. You: ⌘R in Xcode to deploy + launch on iPad
#   2. Use the app for a bit
#   3. ./scripts/fetch.sh          # pulls log
#   4. ./scripts/fetch.sh --shots  # pulls log + screenshots

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE_ID="52E493BF-D921-50EE-A470-71F38C704E1F"
BUNDLE_ID="com.p10entrancer.app"
OUT_DIR="/tmp/p10e-fetch"
mkdir -p "$OUT_DIR"

WANT_SHOTS=0
[[ "${1:-}" == "--shots" ]] && WANT_SHOTS=1

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$*"; }

step "Fetching Documents/p10e.log from $BUNDLE_ID"
rm -f "$OUT_DIR/p10e.log"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Documents/p10e.log \
  --destination "$OUT_DIR/p10e.log" 2>&1 | grep -vE "Failed to load provisioning|devicectl manage create" | tail -3 || true

if [[ -s "$OUT_DIR/p10e.log" ]]; then
  step "Log content ($(wc -l < "$OUT_DIR/p10e.log") lines)"
  cat "$OUT_DIR/p10e.log"
else
  step "No log fetched (file may not exist yet)"
fi

if [[ "$WANT_SHOTS" -eq 1 ]]; then
  step "Fetching Documents/screenshots/"
  rm -rf "$OUT_DIR/screenshots"
  xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source Documents/screenshots \
    --destination "$OUT_DIR/screenshots" 2>&1 | grep -vE "Failed to load provisioning|devicectl manage create" | tail -3 || true

  if [[ -d "$OUT_DIR/screenshots" ]]; then
    count=$(find "$OUT_DIR/screenshots" -name "*.png" | wc -l | tr -d ' ')
    step "Pulled $count screenshot(s) to $OUT_DIR/screenshots/"
    ls -la "$OUT_DIR/screenshots/" | head -20
  else
    step "No screenshots directory yet"
  fi
fi
