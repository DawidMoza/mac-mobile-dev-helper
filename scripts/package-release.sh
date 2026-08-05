#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Mac Mobile Dev Helper"
VERSION="${VERSION:-1.0.0}"
if [[ "$VERSION" != v* ]]; then
  VERSION="v${VERSION}"
fi

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
STAGE_NAME="Mac-Mobile-Dev-Helper-${VERSION}"
STAGE_DIR="$ROOT_DIR/dist/$STAGE_NAME"
ASSET_NAME="${STAGE_NAME}.zip"
ASSET_PATH="$ROOT_DIR/dist/$ASSET_NAME"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app bundle at $APP_DIR. Run ./scripts/build-app.sh first." >&2
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ditto "$APP_DIR" "$STAGE_DIR/$APP_NAME.app"

cat > "$STAGE_DIR/INSTALL.txt" <<EOF
Mac Mobile Dev Helper ${VERSION}

macOS blocks unsigned/ad-hoc apps downloaded from the internet. Double-clicking
the .app (or any helper script in this zip) can fail or send it to Trash.

Recommended install from Terminal:

  curl -fsSL https://raw.githubusercontent.com/DawidMoza/mac-mobile-dev-helper/main/scripts/install-release.sh | bash

That downloads the release, clears quarantine, installs to /Applications, and opens it.

If you already unpacked this zip, clear quarantine manually:

  xattr -dr com.apple.quarantine "${APP_NAME}.app"
  open "${APP_NAME}.app"

Or use System Settings → Privacy & Security → Open Anyway after macOS blocks it.
EOF

rm -f "$ASSET_PATH"
(
  cd "$ROOT_DIR/dist"
  ditto -c -k --sequesterRsrc --keepParent "$STAGE_NAME" "$ASSET_NAME"
)

shasum -a 256 "$ASSET_PATH" > "${ASSET_PATH}.sha256"
echo "Packed $ASSET_PATH"
echo "Checksum ${ASSET_PATH}.sha256"
