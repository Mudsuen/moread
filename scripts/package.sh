#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
bundle="$PWD/build/MudsReader.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/MudsReader "$bundle/Contents/MacOS/MudsReader"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MudsReader</string>
<key>CFBundleIdentifier</key><string>com.muds.reader</string>
<key>CFBundleName</key><string>MudsReader</string>
<key>CFBundleDisplayName</key><string>闲读</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>EPUB Book</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array><key>CFBundleTypeExtensions</key><array><string>epub</string></array></dict></array>
</dict></plist>
PLIST
swift scripts/icon.swift "$PWD/build"
iconutil -c icns build/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
echo "$bundle"
