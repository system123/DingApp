#!/bin/sh
# Builds Ding.app (menu bar only, no Dock icon). Run: ./build.sh && open Ding.app
set -e
cd "$(dirname "$0")"
# Universal binary (Apple silicon + Intel), macOS 14 or later.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 main.swift icon.swift -o Ding-$arch
done
lipo -create -output Ding Ding-arm64 Ding-x86_64 && rm Ding-arm64 Ding-x86_64
./Ding --selftest
rm -rf Ding.iconset && ./Ding --write-iconset Ding.iconset && iconutil -c icns Ding.iconset -o AppIcon.icns && rm -rf Ding.iconset
rm -rf Ding.app && mkdir -p Ding.app/Contents/MacOS Ding.app/Contents/Resources
mv AppIcon.icns Ding.app/Contents/Resources/
mv Ding Ding.app/Contents/MacOS/
cat > Ding.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Ding</string>
  <key>CFBundleIdentifier</key><string>local.ding</string>
  <key>CFBundleName</key><string>Ding</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-1.0.0}</string>
  <key>CFBundleVersion</key><string>${VERSION:-1.0.0}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - --force Ding.app
# Release zip: VERSION=1.0.0 ./build.sh zip
[ "$1" = zip ] && ditto -c -k --keepParent Ding.app Ding.zip || true
