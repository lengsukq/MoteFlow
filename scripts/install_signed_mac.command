#!/bin/bash
set -euo pipefail

# Consistent Apple Development signature and installation path are essential
# for macOS Input Monitoring / Accessibility TCC permissions across rebuilds.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications"
TEAM="${MOTEFLOW_DEVELOPMENT_TEAM:-${GOOGLE_REMOTE_DEVELOPMENT_TEAM:-}}"
cd "$ROOT"

if [[ -z "$TEAM" ]]; then
  echo "Set MOTEFLOW_DEVELOPMENT_TEAM to your Apple Development Team ID."
  echo "Example: MOTEFLOW_DEVELOPMENT_TEAM=YOUR_TEAM_ID bash scripts/install_signed_mac.command"
  exit 2
fi

echo "Building MoteFlow using Apple Development signing..."
xcodebuild -project GoogleRemote.xcodeproj \
  -scheme GoogleRemote \
  -configuration Release \
  "DEVELOPMENT_TEAM=$TEAM" \
  'CODE_SIGN_IDENTITY=Apple Development' \
  CODE_SIGN_STYLE=Automatic \
  "CONFIGURATION_BUILD_DIR=$DEST" \
  build

echo "Signed app installed at: $DEST/MoteFlow.app"
echo "Close any previous MoteFlow instances before launching the signed app."
open "$DEST/MoteFlow.app"
