#!/usr/bin/env bash

# Installs the latest GitHub release into /Applications and clears Gatekeeper
# quarantine. Intended to be run from Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/DawidMoza/mac-mobile-dev-helper/main/scripts/install-release.sh | bash

set -euo pipefail

REPO="DawidMoza/mac-mobile-dev-helper"
APP_NAME="Mac Mobile Dev Helper"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TAG="${1:-}"

if ! command -v curl >/dev/null; then
  echo "curl is required." >&2
  exit 1
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/mac-mobile-dev-helper.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

api="https://api.github.com/repos/${REPO}/releases"
release_json_path="${tmpdir}/release.json"
if [[ -n "$TAG" ]]; then
  curl -fsSL "${api}/tags/${TAG}" -o "$release_json_path"
else
  curl -fsSL "${api}/latest" -o "$release_json_path"
fi

asset_url="$(
  python3 <<PY
import json
with open("${release_json_path}") as handle:
    release = json.load(handle)
for asset in release.get("assets", []):
    name = asset.get("name", "")
    if name.startswith("Mac-Mobile-Dev-Helper-") and name.endswith(".zip") and not name.endswith(".sha256"):
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit("No release zip found.")
PY
)"

tag_name="$(
  python3 <<PY
import json
with open("${release_json_path}") as handle:
    print(json.load(handle)["tag_name"])
PY
)"

echo "Downloading ${tag_name}…"
zip_path="${tmpdir}/release.zip"
curl -fL --progress-bar -o "$zip_path" "$asset_url"

echo "Unpacking…"
unzip -q "$zip_path" -d "$tmpdir/unpacked"

app_path="$(find "$tmpdir/unpacked" -name "${APP_NAME}.app" -type d | head -n 1)"
if [[ -z "$app_path" ]]; then
  echo "Could not find ${APP_NAME}.app inside the release zip." >&2
  exit 1
fi

echo "Clearing macOS quarantine…"
xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true

destination="${INSTALL_DIR}/${APP_NAME}.app"
echo "Installing to ${destination}…"
rm -rf "$destination"
ditto "$app_path" "$destination"
xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true

echo "Launching…"
open "$destination"
echo "Installed ${tag_name}."
