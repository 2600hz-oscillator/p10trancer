#!/usr/bin/env bash
# Build, install, launch on the paired iPad, and fetch the app's log.
# Run from the repo root (the script self-locates).
#
# Usage:
#   ./scripts/deploy.sh            # build + install + launch + fetch
#   ./scripts/deploy.sh --no-build # skip build (use existing .app), still install+launch+fetch
#   ./scripts/deploy.sh --launch   # just launch already-installed + fetch
#
# Requires: xcodegen + xcodebuild (Xcode), devicectl (built into Xcode).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

DEVICE_ID="52E493BF-D921-50EE-A470-71F38C704E1F"
BUNDLE_ID="com.p10entrancer.app"
SCHEME="P10Entrancer"
PROJECT="P10Entrancer.xcodeproj"
LOG_RUNTIME_SECS=8
OUT_DIR="/tmp/p10e-deploy"
mkdir -p "$OUT_DIR"

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$*"; }

case "${1:-}" in
  --launch)
    skip_build=1
    skip_install=1
    ;;
  --no-build)
    skip_build=1
    skip_install=0
    ;;
  *)
    skip_build=0
    skip_install=0
    ;;
esac

if [[ "$skip_build" -eq 0 ]]; then
  step "Regenerating Xcode project"
  xcodegen generate >/dev/null

  step "Building for iOS device"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -sdk iphoneos \
    -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -allowProvisioningUpdates \
    build 2>&1 | tail -8
fi

if [[ "$skip_install" -eq 0 ]]; then
  # Exclude Index.noindex — Xcode's indexer builds a stub .app there
  # without a final Info.plist; devicectl picks the wrong one if
  # `find` happens to return it first.
  APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug-iphoneos/${SCHEME}.app" -type d 2>/dev/null \
    | grep -v Index.noindex \
    | head -1)
  if [[ -z "$APP_PATH" ]]; then
    echo "Could not locate built .app in DerivedData"
    exit 1
  fi
  step "Installing $APP_PATH"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1 | grep -vE "Failed to load provisioning|devicectl manage create" | tail -10
fi

step "Terminating existing instance (if any)"
xcrun devicectl device process terminate \
  --device "$DEVICE_ID" \
  --json-output "$OUT_DIR/term.json" \
  "$BUNDLE_ID" 2>&1 | grep -vE "Failed to load provisioning|devicectl manage create" | tail -3 || true

step "Launching $BUNDLE_ID"
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --json-output "$OUT_DIR/launch.json" \
  "$BUNDLE_ID" 2>&1 | grep -vE "Failed to load provisioning|devicectl manage create" | tail -3

step "Letting app run for ${LOG_RUNTIME_SECS}s"
sleep "$LOG_RUNTIME_SECS"

step "Fetching Documents/p10e.log"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Documents/p10e.log \
  --destination "$OUT_DIR/p10e.log" 2>&1 | grep -vE "Failed to load provisioning|devicectl manage create" | tail -3 || echo "(log not yet present)"

if [[ -s "$OUT_DIR/p10e.log" ]]; then
  step "Log content"
  cat "$OUT_DIR/p10e.log"
else
  step "No log yet (app may not have run startIfNeeded, or crashed before logging)"
fi
