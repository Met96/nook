#!/bin/zsh
# Builds Nook.app and installs it to /Applications.
#   ./build.sh            build + install + launch
#   ./build.sh --no-install   just build ./build/Nook.app
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Nook.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling"
swiftc -O main.swift -o "$APP/Contents/MacOS/Nook"

echo "→ Rendering icon"
if [[ ! -f AppIcon.icns ]]; then
  swift icon.swift && iconutil -c icns AppIcon.iconset && rm -rf AppIcon.iconset
fi
cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Nook</string>
  <key>CFBundleIdentifier</key><string>io.github.met96.nook</string>
  <key>CFBundleName</key><string>Nook</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Nook pauses Spotify and Music when a focus session ends.</string>
</dict></plist>
EOF

codesign --force -s - "$APP"   # ad-hoc signature, enough to run locally
echo "✓ Built $APP"

[[ "${1:-}" == "--no-install" ]] && exit 0

pkill -x Nook 2>/dev/null || true
rm -rf /Applications/Nook.app
cp -R "$APP" /Applications/
open /Applications/Nook.app
echo "✓ Installed to /Applications and launched"
