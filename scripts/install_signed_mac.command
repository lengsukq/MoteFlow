#!/bin/bash
set -euo pipefail

# Consistent Apple Development signature and installation path are essential
# for macOS Input Monitoring / Accessibility TCC permissions across rebuilds.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications"
TEAM="${MOTEFLOW_DEVELOPMENT_TEAM:-${GOOGLE_REMOTE_DEVELOPMENT_TEAM:-}}"
cd "$ROOT"

if [[ -z "$TEAM" ]]; then
  # Use the same Development team as the checked-in Xcode project by default.
  # Callers may still override it when using a different signing identity.
  TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' GoogleRemote.xcodeproj/project.pbxproj | head -n 1)"
fi
if [[ -z "$TEAM" ]]; then
  echo "Missing Development Team. Set MOTEFLOW_DEVELOPMENT_TEAM."
  exit 2
fi

BUILD_DIR="$ROOT/.build/moteflow-signed-install"
APP="$DEST/MoteFlow.app"
STAGED="$BUILD_DIR/MoteFlow.app"
mkdir -p "$BUILD_DIR" "$DEST"

echo "Building MoteFlow using Apple Development signing..."
xcodebuild -project GoogleRemote.xcodeproj \
  -scheme GoogleRemote \
  -configuration Release \
  "DEVELOPMENT_TEAM=$TEAM" \
  'CODE_SIGN_IDENTITY=Apple Development' \
  CODE_SIGN_STYLE=Automatic \
  "CONFIGURATION_BUILD_DIR=$BUILD_DIR" \
  build

# A failed build/signature check must not replace the installed app.
codesign --verify --deep --strict "$STAGED"

if pgrep -x MoteFlow >/dev/null; then
  echo "Closing the currently running MoteFlow..."
  osascript -e 'tell application id "app.google-remote.mac" to quit' || true
  for _ in {1..20}; do
    if ! pgrep -x MoteFlow >/dev/null; then break; fi
    sleep 0.25
  done
  if pgrep -x MoteFlow >/dev/null; then
    echo "The old app is still running. Close it manually; installation was not changed."
    exit 3
  fi
fi

BACKUP="$DEST/.MoteFlow-install-backup.app"
if [[ -e "$BACKUP" ]]; then
  echo "A previous backup exists at $BACKUP; refusing to overwrite it."
  exit 4
fi
if [[ -d "$APP" ]]; then mv "$APP" "$BACKUP"; fi
if ! ditto "$STAGED" "$APP" || ! codesign --verify --deep --strict "$APP"; then
  rm -rf "$APP"
  if [[ -d "$BACKUP" ]]; then mv "$BACKUP" "$APP"; fi
  echo "Install failed; restored the previous MoteFlow."
  exit 5
fi
if [[ -d "$BACKUP" ]]; then rm -rf "$BACKUP"; fi
echo "Signed app installed at: $APP"
open "$APP"
