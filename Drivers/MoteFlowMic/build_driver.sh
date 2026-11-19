#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="${1:-$ROOT/.build/moteflow-mic-driver}"
BUNDLE="$OUT_DIR/MoteFlowMic.driver"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

echo "Building MoteFlowMic.driver ($ARCH)..."
clang -O2 -Wall -Wextra -Werror \
  -std=c11 \
  -bundle \
  -arch "$ARCH" \
  -mmacosx-version-min=14.0 \
  -isysroot "$SDK_PATH" \
  -framework CoreFoundation \
  -framework CoreAudio \
  "$SCRIPT_DIR/MoteFlowMic.c" \
  -o "$BUNDLE/Contents/MacOS/MoteFlowMic"

cp "$SCRIPT_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null

SIGN_ID="${MOTEFLOW_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi

if [[ -n "$SIGN_ID" ]]; then
  echo "Signing MoteFlowMic.driver with: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" "$BUNDLE"
else
  echo "Applying ad-hoc signature to MoteFlowMic.driver..."
  codesign --force --sign - "$BUNDLE"
fi

codesign --verify --strict "$BUNDLE"
echo "Built & verified: $BUNDLE"
