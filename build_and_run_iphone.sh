#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Road Quality Mapper — Build & Run on iPhone
# Run this from the pothole_finder directory:
#   chmod +x build_and_run_iphone.sh && ./build_and_run_iphone.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

FLUTTER="$HOME/Desktop/Coding/flutter/bin/flutter"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "📱  Road Quality Mapper — iPhone Build"
echo "────────────────────────────────────────"
echo "Project: $PROJECT_DIR"
echo ""

cd "$PROJECT_DIR"

# 1. Ensure packages are up to date
echo "→ flutter pub get …"
"$FLUTTER" pub get

# 2. List connected devices so we can pick the iPhone
echo ""
echo "→ Scanning for connected devices …"
"$FLUTTER" devices

echo ""
echo "────────────────────────────────────────"
# 3. Find the first connected iPhone automatically
DEVICE_ID=$("$FLUTTER" devices --machine 2>/dev/null \
  | python3 -c "
import sys, json
devs = json.load(sys.stdin)
for d in devs:
    if d.get('targetPlatform','').startswith('ios') and not d.get('emulator', True):
        print(d['id'])
        break
" 2>/dev/null || echo "")

if [ -z "$DEVICE_ID" ]; then
  echo ""
  echo "⚠️  No iPhone found."
  echo ""
  echo "   1. Connect your iPhone via USB cable."
  echo "   2. Unlock it and tap 'Trust This Computer' if prompted."
  echo "   3. Re-run this script."
  echo ""
  exit 1
fi

echo "✅  Found device: $DEVICE_ID"
echo ""
echo "→ Building and installing on iPhone …"
echo "   (first build takes 2–5 minutes)"
echo ""

"$FLUTTER" run --release -d "$DEVICE_ID"
