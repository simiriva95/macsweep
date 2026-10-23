#!/bin/sh
# ./build.sh          -> compila build/MacSweep.app ed esegue il selftest
# ./build.sh install  -> come sopra + installa in /Applications
set -e
cd "$(dirname "$0")"
APP=build/MacSweep.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -O -swift-version 5 -target arm64-apple-macosx15.0 -o "$APP/Contents/MacOS/MacSweep" Sources/*.swift

swift scripts/icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacSweep</string>
  <key>CFBundleDisplayName</key><string>MacSweep</string>
  <key>CFBundleIdentifier</key><string>local.sriva.macsweep</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>MacSweep</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MacSweep usa il Finder per cestinare le app di sistema ed Eventi di Sistema per leggere gli elementi di login.</string>
</dict>
</plist>
EOF

# Firma col certificato locale (portachiavi) se c'è: firma stabile => l'Accesso completo al disco sopravvive alle ricompilazioni
SIGN=$(security find-identity -p codesigning | awk '/"MacSweep Local Signing"/ {print $2; exit}')
codesign --force -s "${SIGN:--}" "$APP"
"$APP/Contents/MacOS/MacSweep" --selftest

if [ "$1" = install ]; then
  rm -rf /Applications/MacSweep.app
  ditto "$APP" /Applications/MacSweep.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MacSweep.app
  echo "Installata in /Applications/MacSweep.app"
fi
