#!/bin/bash
# Builds Yoman.app (universal, ad-hoc signed) into ./build.
#   ./build.sh           build, and restart Yoman if it's running
#   ./build.sh install   build, copy to /Applications, and run it from there
set -euo pipefail
cd "$(dirname "$0")"

# The macOS 27 SDK's SwiftUI needs a macro plugin that only ships with full Xcode;
# with Command Line Tools alone, build against the newest pre-27 SDK.
if [[ -z "${SDKROOT:-}" ]] && ! xcode-select -p | grep -q Xcode.app; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [[ -n "$SDK" ]] && export SDKROOT="$SDK"
fi

# The two "search path ... not found" linker warnings come from Command Line Tools themselves; hide them.
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -v "ld: warning: search path"
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Yoman

APP=build.noindex/Yoman.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Yoman"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Yoman</string>
  <key>CFBundleIdentifier</key><string>com.local.Yoman</string>
  <key>CFBundleName</key><string>Yoman</string>
  <key>CFBundleDisplayName</key><string>Yoman</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Yoman shows and edits events from all of your calendars.</string>
  <key>NSCalendarsUsageDescription</key><string>Yoman shows and edits events from all of your calendars.</string>
</dict></plist>
PLIST
# Ad-hoc signature, but with a designated requirement tied to the bundle ID (not the per-build hash),
# so macOS keeps the Calendar/Keychain permissions across rebuilds.
codesign --force --sign - -r='designated => identifier "com.local.Yoman"' "$APP"
echo "Built $APP"

restart() {
  if pgrep -x Yoman >/dev/null; then
    pkill -x Yoman
    while pgrep -x Yoman >/dev/null; do sleep 0.2; done
  fi
  open "$1"
}

if [[ "${1:-}" == "install" ]]; then
  # Same bundle ID and signature requirement, so calendar access and settings carry over.
  pkill -x Yoman 2>/dev/null || true
  while pgrep -x Yoman >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Yoman.app
  ditto "$APP" /Applications/Yoman.app
  restart /Applications/Yoman.app
  echo "Installed /Applications/Yoman.app"
elif pgrep -x Yoman >/dev/null; then
  # A running copy keeps the old binary; restart it so the new build takes effect.
  RUNNING=$(ps -o comm= -p "$(pgrep -x Yoman | head -1)" | sed 's#/Contents/MacOS/Yoman##')
  if [[ "$RUNNING" == /Applications/* ]]; then
    ditto "$APP" "$RUNNING"   # keep the installed copy in sync
  fi
  restart "$RUNNING"
  echo "Restarted Yoman"
fi
