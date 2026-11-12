#!/bin/bash
set -euo pipefail

# Consistent Apple Development signature and installation path are essential
# for macOS Input Monitoring / Accessibility TCC permissions across rebuilds.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${MOTEFLOW_INSTALL_DIR:-$HOME/Applications}"
TEAM="${MOTEFLOW_DEVELOPMENT_TEAM:-${GOOGLE_REMOTE_DEVELOPMENT_TEAM:-}}"
ALLOW_ADHOC="${MOTEFLOW_ALLOW_ADHOC:-0}"
cd "$ROOT"

if [[ -z "$TEAM" ]]; then
  TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' GoogleRemote.xcodeproj/project.pbxproj | head -n 1)"
fi

BUILD_DIR="$ROOT/.build/moteflow-signed-install"
APP="$DEST/MoteFlow.app"
STAGED="$BUILD_DIR/MoteFlow.app"
mkdir -p "$BUILD_DIR" "$DEST"

has_xcodebuild() {
  xcodebuild -version >/dev/null 2>&1
}

build_with_command_line_tools() {
  echo "Xcode.app not active; building Release MoteFlow.app via Swift Command Line Tools..."
  rm -rf "$STAGED"
  mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"

  local sdk_path=""
  if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    sdk_path="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
  else
    sdk_path="$(xcrun --show-sdk-path)"
  fi

  local plugin_args=()
  if [[ -d "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins" ]]; then
    plugin_args=(-plugin-path "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins")
  fi

  local arch
  arch="$(uname -m)"
  swiftc -O \
    -sdk "$sdk_path" \
    "${plugin_args[@]}" \
    -target "${arch}-apple-macos14.0" \
    GoogleRemote/Sources/*.swift \
    -o "$STAGED/Contents/MacOS/MoteFlow"

  # Package multi-resolution AppIcon.icns directly from PNG assets
  /usr/bin/python3 - "GoogleRemote/Assets.xcassets/AppIcon.appiconset" "$STAGED/Contents/Resources/AppIcon.icns" <<'PY'
import pathlib, struct, sys
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
chunks = []
for ostype, fname in [
    (b"ic11", "mote-flow-32.png"),
    (b"ic12", "mote-flow-64.png"),
    (b"ic07", "mote-flow-128.png"),
    (b"ic08", "mote-flow-256.png"),
    (b"ic09", "mote-flow-512.png"),
    (b"ic10", "mote-flow-1024.png"),
]:
    data = (src / fname).read_bytes()
    chunks.append(ostype + struct.pack(">I", 8 + len(data)) + data)
body = b"".join(chunks)
out.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)
PY

  # Copy image sets so Bundle.main resolves named SwiftUI / MenuBarExtra assets
  cp "GoogleRemote/Assets.xcassets/MoteFlowMark.imageset/mote-flow-mark.png" \
     "$STAGED/Contents/Resources/MoteFlowMark.png"
  cp "GoogleRemote/Assets.xcassets/MoteFlowStatusIcon.imageset/mote-flow-status-1x.png" \
     "$STAGED/Contents/Resources/MoteFlowStatusIcon.png"
  cp "GoogleRemote/Assets.xcassets/MoteFlowStatusIcon.imageset/mote-flow-status-2x.png" \
     "$STAGED/Contents/Resources/MoteFlowStatusIcon@2x.png"
  cp "GoogleRemote/Assets.xcassets/MoteFlowStatusIcon.imageset/mote-flow-status-3x.png" \
     "$STAGED/Contents/Resources/MoteFlowStatusIcon@3x.png"

  printf 'APPL????' > "$STAGED/Contents/PkgInfo"

  cat > "$STAGED/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>MoteFlow</string>
    <key>CFBundleExecutable</key>
    <string>MoteFlow</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.google-remote.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MoteFlow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>只在你确认安装或卸载 BlackHole 2ch 后打开终端运行对应 Homebrew 命令。</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>用于发现和连接蓝牙遥控器并启用语音服务。</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>用于在同一局域网自动发现另一台 Mac，并通过点击确认配对转发遥控器操作。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_moteflow._tcp</string>
    </array>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>经用户确认后，将遥控器的语音录音在本机转换为文字。</string>
</dict>
</plist>
PLIST
  plutil -lint "$STAGED/Contents/Info.plist" >/dev/null

  local sign_id=""
  sign_id="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
  if [[ -n "$sign_id" ]]; then
    echo "Signing with identity: $sign_id"
    codesign --force --deep --options runtime \
      --entitlements GoogleRemote/GoogleRemote.entitlements \
      --sign "$sign_id" "$STAGED"
  elif [[ "$ALLOW_ADHOC" == "1" ]]; then
    echo "No Apple Development identity accessible in current keychain; applying ad-hoc signature..."
    codesign --force --deep \
      --entitlements GoogleRemote/GoogleRemote.entitlements \
      --sign - "$STAGED"
  else
    echo "No Apple Development certificate found in accessible keychain; applying local ad-hoc signature so app can run."
    codesign --force --deep \
      --entitlements GoogleRemote/GoogleRemote.entitlements \
      --sign - "$STAGED"
  fi
}

if has_xcodebuild; then
  if [[ -z "$TEAM" ]]; then
    echo "Missing Development Team. Set MOTEFLOW_DEVELOPMENT_TEAM."
    exit 2
  fi
  echo "Building MoteFlow using Xcode Apple Development signing..."
  xcodebuild -project GoogleRemote.xcodeproj \
    -scheme GoogleRemote \
    -configuration Release \
    "DEVELOPMENT_TEAM=$TEAM" \
    'CODE_SIGN_IDENTITY=Apple Development' \
    CODE_SIGN_STYLE=Automatic \
    "CONFIGURATION_BUILD_DIR=$BUILD_DIR" \
    build
else
  build_with_command_line_tools
fi

# A failed build/signature check must not replace the installed app.
codesign --verify --deep --strict "$STAGED"

if [[ "${MOTEFLOW_BUILD_ONLY:-0}" == "1" ]]; then
  echo "Staged signed app ready at: $STAGED"
  exit 0
fi

if pgrep -x MoteFlow >/dev/null 2>&1; then
  echo "Closing the currently running MoteFlow..."
  osascript -e 'tell application id "app.google-remote.mac" to quit' || true
  for _ in {1..20}; do
    if ! pgrep -x MoteFlow >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
  if pgrep -x MoteFlow >/dev/null 2>&1; then
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
