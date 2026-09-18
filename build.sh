#!/bin/zsh
# Builds build/simpleBackup.app.
#   ./build.sh            build only
#   ./build.sh install    build, copy to /Applications and launch
# Sign with your own certificate (then the Keychain won't ask again after every rebuild):
#   SIGN_ID="Apple Development: …" ./build.sh
set -euo pipefail
cd "${0:A:h}"

APP=simpleBackup
VERSION=1.0.0
BUNDLE_ID=local.simplebackup
SIGN_ID=${SIGN_ID:--}

# only generate the icon if there isn't one yet
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ Icon"
  ICONSET=build/AppIcon.iconset
  mkdir -p $ICONSET Resources
  swift Icon/MakeIcon.swift build/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o Resources/AppIcon.icns
fi

echo "▸ Compiling"
CONTENTS=build/$APP.app/Contents
rm -rf build/$APP.app
mkdir -p $CONTENTS/MacOS $CONTENTS/Resources
swiftc -O -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -o $CONTENTS/MacOS/$APP Sources/*.swift

echo "▸ Resources"
plutil -lint -s Resources/*.lproj/*.strings # a typo in a .strings file silently breaks all translations
cp -R Resources/AppIcon.icns Resources/*.lproj $CONTENTS/Resources/

cat > $CONTENTS/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y)</string>
</dict>
</plist>
EOF

echo "▸ Signing ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" build/$APP.app

echo "✓ build/$APP.app"

if [[ ${1:-} == install ]]; then
  if pgrep -qx $APP; then
    echo "$APP is still running – please quit it from the menu first."
    exit 1
  fi
  rm -rf /Applications/$APP.app
  cp -R build/$APP.app /Applications/
  open /Applications/$APP.app
  echo "✓ installed and launched: /Applications/$APP.app"
fi
