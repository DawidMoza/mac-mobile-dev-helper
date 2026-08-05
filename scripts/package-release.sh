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

cat > "$STAGE_DIR/Open First Time.command" <<'COMMAND'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="Mac Mobile Dev Helper.app"

if [[ ! -d "$APP" ]]; then
  osascript -e 'display alert "Mac Mobile Dev Helper" message "Could not find Mac Mobile Dev Helper.app next to this script." as critical'
  exit 1
fi

# Downloads from the internet get a quarantine flag. Ad-hoc signed open-source
# builds are not notarized by Apple, so macOS may refuse to open them until that
# flag is removed.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP"
COMMAND
chmod +x "$STAGE_DIR/Open First Time.command"

cat > "$STAGE_DIR/README.txt" <<'README'
Mac Mobile Dev Helper

If macOS says it cannot check for malicious software, or moves the app to Trash:

1. Double-click "Open First Time.command" and allow Terminal if prompted.
   or
2. In Terminal, run:
   xattr -dr com.apple.quarantine "Mac Mobile Dev Helper.app"
   open "Mac Mobile Dev Helper.app"
   or
3. Open System Settings → Privacy & Security → Open Anyway.

The release build is ad-hoc signed and not notarized by Apple. That is expected
for this open-source distribution. Builds you create locally with
./scripts/build-app.sh do not need this step.
README

rm -f "$ASSET_PATH"
(
  cd "$ROOT_DIR/dist"
  ditto -c -k --sequesterRsrc --keepParent "$STAGE_NAME" "$ASSET_NAME"
)

shasum -a 256 "$ASSET_PATH" > "${ASSET_PATH}.sha256"
echo "Packed $ASSET_PATH"
echo "Checksum ${ASSET_PATH}.sha256"
