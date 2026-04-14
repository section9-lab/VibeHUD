#!/bin/bash
# Build VibeHUD for release
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/VibeHUD.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

echo "=== Building VibeHUD ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

echo "Archiving..."
set +e
xcodebuild archive \
    -scheme VibeHUD \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic
ARCHIVE_EXIT=$?
set -e

if [ "$ARCHIVE_EXIT" -ne 0 ]; then
    echo "ERROR: Archive failed."
    exit 1
fi

# Create ExportOptions.plist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting..."
set +e
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"
EXPORT_EXIT=$?
set -e

if [ "$EXPORT_EXIT" -ne 0 ]; then
    echo "ERROR: Export failed."
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/VibeHUD.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
