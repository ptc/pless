#!/usr/bin/env bash
# Baut dist/Pless.app — ein startbares macOS-App-Bundle (Release, ad-hoc signiert).
# Nutzung: bash Scripts/make-app.sh   →   dist/Pless.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Pless.app"
STAGE="$ROOT/.build/app-stage/Pless.app"

echo "==> Release-Build"
swift build --package-path "$ROOT" -c release
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
BIN="$BIN_DIR/Pless"
[ -x "$BIN" ] || { echo "Binary nicht gefunden: $BIN" >&2; exit 1; }

echo "==> Bundle aufbauen: $APP"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BIN" "$STAGE/Contents/MacOS/Pless"

cat > "$STAGE/Contents/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Pless</string>
	<key>CFBundleIdentifier</key>
	<string>dev.pless.app</string>
	<key>CFBundleName</key>
	<string>Pless</string>
	<key>CFBundleDisplayName</key>
	<string>Pless</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>CFBundleIconFile</key>
	<string>pless</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>PDF-Dokument</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.adobe.pdf</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
XML
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

echo "==> Icon generieren (pless.icns via Scripts/make-icon.swift + iconutil)"
mkdir -p "$STAGE/Contents/Resources"
ICONSET="$ROOT/.build/icon/pless.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/pless.icns"

mkdir -p "$ROOT/dist"
if [ -d "$APP" ]; then rm -rf "$APP"; fi
mv "$STAGE" "$APP"

echo "==> Ad-hoc signieren (lokal ohne Developer-Account)"
codesign --force --deep --sign - "$APP"

echo "==> Verifizieren"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" | head -2
plutil -lint "$APP/Contents/Info.plist"

echo "==> Fertig: $APP"
echo "    Start:  open $APP   (oder Doppelklick im Finder, nach /Applications kopieren)"
echo "    MCP:    $APP/Contents/MacOS/Pless mcp --vault <pfad>"
