#!/bin/bash
# Builds "NODE Print.app" (universal, Release) and packs it as a zip and a dmg in dist/.
# SIGN_IDENTITY defaults to ad-hoc signing; a Developer ID identity also turns on the hardened runtime.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/NodePrintCore/Version.swift)
identity=${SIGN_IDENTITY:--}
dist=dist
app="$dist/NODE Print.app"

swift build -c release --arch arm64 --arch x86_64 --product NodePrintApp
binary="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/NodePrintApp"

rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/NODE Print"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
python3 scripts/compile-strings.py Resources/Localizable.xcstrings "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>NODE Print</string>
  <key>CFBundleExecutable</key><string>NODE Print</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>live.node.print</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>es</string></array>
  <key>CFBundleName</key><string>NODE Print</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.business</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"

if [ "$identity" = "-" ]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict "$app"

ditto -c -k --keepParent "$app" "$dist/NODE-Print-$version-macos.zip"
staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "NODE Print" -srcfolder "$staging" -ov -format UDZO "$dist/NODE-Print-$version-macos.dmg"
rm -rf "$staging"
echo "$version"
