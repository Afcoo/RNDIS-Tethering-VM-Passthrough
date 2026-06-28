#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="RTVMP"
PROJECT_NAME="RNDIS Tethering VM Passthrough.xcodeproj"
SCHEME_NAME="RNDIS Tethering VM Passthrough"
BUILD_CONFIGURATION="Debug"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-/tmp/RTPVM-DerivedData}"
XCODEBUILD="${XCODEBUILD:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild}"
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)

if [[ ! -x "$XCODEBUILD" ]]; then
  XCODEBUILD="xcodebuild"
fi

APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

if [[ "$MODE" == "--runtime" || "$MODE" == "runtime" ]]; then
  SCHEME_NAME="RNDIS Tethering VM Passthrough Runtime"
  BUILD_CONFIGURATION="RuntimeDebug"
  APP_BUNDLE="$DERIVED_DATA/Build/Products/RuntimeDebug/$APP_NAME.app"
  SIGNING_ARGS=()
  MODE="run"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

"$XCODEBUILD" \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  -scheme "$SCHEME_NAME" \
  -configuration "$BUILD_CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  "${SIGNING_ARGS[@]}" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"${RTPVM_LOG_SUBSYSTEM:-com.example.rndis-tethering}\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--runtime|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
