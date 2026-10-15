#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# A stable certificate identity is required: ad-hoc cdhash requirements invalidate TCC
# permissions whenever app code changes. Reuse the same developer identity for updates.
reader_signing_identity="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development:/{print $2; exit}')}"
if [[ -z "$reader_signing_identity" || "$reader_signing_identity" == "-" ]]; then
  echo "A stable signing identity is required. Set CODE_SIGN_IDENTITY to a valid Apple Development identity." >&2
  exit 1
fi
swift build -c release
bundle="$PWD/build/moread.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/MudsReader "$bundle/Contents/MacOS/MudsReader"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MudsReader</string>
<key>CFBundleIdentifier</key><string>com.muds.reader</string>
<key>CFBundleName</key><string>moread</string>
<key>CFBundleDisplayName</key><string>moread</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.7</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>EPUB Book</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array><key>CFBundleTypeExtensions</key><array><string>epub</string></array></dict></array>
</dict></plist>
PLIST
swift scripts/icon.swift "$PWD/build"
iconutil -c icns build/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign "$reader_signing_identity" --timestamp=none "$bundle"
codesign --verify --deep --strict "$bundle"
echo "$bundle"
