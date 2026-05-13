#!/usr/bin/env bash
# audio-self-test.sh
#
# End-to-end audio diagnostic loop: build, deploy, launch with the
# self-test arg, wait for the JSON report, pull it, terminate the app,
# print the report.
#
# Requires: iPad attached, com.p10entrancer.app already provisioned.

set -euo pipefail

DEVICE="${P10E_DEVICE:-52E493BF-D921-50EE-A470-71F38C704E1F}"
BUNDLE="com.p10entrancer.app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH=$(ls -td "$HOME/Library/Developer/Xcode/DerivedData/P10Entrancer-"*/Build/Products/Debug-iphoneos/P10Entrancer.app 2>/dev/null | head -1)
OUT="$ROOT/diagnostics/audio-self-test.json"

mkdir -p "$ROOT/diagnostics"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Building first…"
  (cd "$ROOT" && flox activate -- xcodebuild -project P10Entrancer.xcodeproj \
    -scheme P10Entrancer -sdk iphoneos -destination 'generic/platform=iOS' \
    -configuration Debug build >/dev/null)
  APP_PATH=$(ls -td "$HOME/Library/Developer/Xcode/DerivedData/P10Entrancer-"*/Build/Products/Debug-iphoneos/P10Entrancer.app | head -1)
fi

echo "Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH" >/dev/null

# Remove any stale report from the previous run so we don't read it back.
rm -f "$OUT"
xcrun devicectl device copy to --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --destination "Documents/audio-self-test.json" \
  --source /dev/null 2>/dev/null || true

echo "Launching with -AudioSelfTest"
xcrun devicectl device process launch \
  --device "$DEVICE" \
  -- "$BUNDLE" -AudioSelfTest YES >/dev/null

# Probe runs ~6 categories x ~0.6s each + boot overhead. Wait up to 20s
# for a *fresh* JSON report (timestamp newer than our launch time).
LAUNCH_EPOCH=$(date +%s)
echo -n "Waiting for report"
for _ in $(seq 1 40); do
  if xcrun devicectl device copy from \
       --device "$DEVICE" \
       --domain-type appDataContainer \
       --domain-identifier "$BUNDLE" \
       --source "Documents/audio-self-test.json" \
       --destination "$OUT" 2>/dev/null; then
    REPORT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" \
      "$(grep -o '"timestamp"[^,]*' "$OUT" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')" \
      +%s 2>/dev/null || echo 0)
    if [[ "$REPORT_EPOCH" -ge "$LAUNCH_EPOCH" ]]; then
      echo " — got it."
      break
    fi
    rm -f "$OUT"
  fi
  echo -n "."
  sleep 0.5
done

if [[ ! -f "$OUT" ]]; then
  echo
  echo "Report did not appear at $OUT — was the app launched with the arg?"
  exit 1
fi

# App likely exited itself; ignore failure.
xcrun devicectl device process terminate --device "$DEVICE" --bundle-id "$BUNDLE" 2>/dev/null || true

echo
echo "===== $OUT ====="
cat "$OUT"
