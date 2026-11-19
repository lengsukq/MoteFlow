#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
TARGET="$HAL_DIR/MoteFlowMic.driver"

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "Uninstalling $TARGET ..."
  sudo rm -rf "$TARGET"
  sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod || true
  echo "MoteFlowMic.driver removed and CoreAudio restarted."
  exit 0
fi

DRIVER_SRC="${1:-$ROOT/.build/moteflow-mic-driver/MoteFlowMic.driver}"
if [[ ! -d "$DRIVER_SRC" ]]; then
  bash "$ROOT/Drivers/MoteFlowMic/build_driver.sh"
  DRIVER_SRC="$ROOT/.build/moteflow-mic-driver/MoteFlowMic.driver"
fi

echo "Installing $DRIVER_SRC -> $TARGET ..."
sudo mkdir -p "$HAL_DIR"
sudo rm -rf "$TARGET"
sudo ditto "$DRIVER_SRC" "$TARGET"
sudo chown -R root:wheel "$TARGET"
sudo chmod -R 755 "$TARGET"
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod || true
echo "MoteFlowMic.driver installed and CoreAudio restarted."
