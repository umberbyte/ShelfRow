#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---verify}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Always export Production entitlements, including during local performance checks.
xcodebuild -project ShelfRow.xcodeproj -scheme ShelfRow -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/Performance.xcarchive archive
xcodebuild -exportArchive -archivePath build/Performance.xcarchive \
  -exportPath build/PerformanceExport -exportOptionsPlist ExportOptions.plist
APP_PATH="$ROOT_DIR/build/PerformanceExport/ShelfRow.app"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" build/ShelfRow-performance.zip
if [[ "$MODE" == "--build-only" ]]; then exit 0; fi
pkill -TERM -x ShelfRow || true
case "$MODE" in
  --debug) lldb -- "$APP_PATH/Contents/MacOS/ShelfRow" ;;
  --logs|--telemetry)
    open -n "$APP_PATH"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.eureka.ShelfRow"'
    ;;
  --verify|run)
    open -n "$APP_PATH"
    sleep 1
    pgrep -x ShelfRow >/dev/null
    ;;
  *) echo "usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
