#!/usr/bin/env bash

# Builds Mac Mobile Dev Helper from source and installs it into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/DawidMoza/mac-mobile-dev-helper/main/scripts/install.sh | bash
#
# Optional tag:
#   curl -fsSL .../install.sh | bash -s -- v0.1.3

set -euo pipefail

REPO_URL="https://github.com/DawidMoza/mac-mobile-dev-helper.git"
REPO_SLUG="DawidMoza/mac-mobile-dev-helper"
APP_NAME="Mac Mobile Dev Helper"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TAG="${1:-}"

require_command() {
  if ! command -v "$1" >/dev/null; then
    echo "'$1' is required. Install Xcode Command Line Tools, then retry." >&2
    exit 1
  fi
}

require_command git
require_command swift
require_command curl
require_command ditto

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/mac-mobile-dev-helper.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

resolve_tag() {
  if [[ -n "$TAG" ]]; then
    printf '%s\n' "$TAG"
    return
  fi

  if tag_name="$(
    curl -fsSL "https://api.github.com/repos/${REPO_SLUG}/releases/latest" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' \
      2>/dev/null
  )" && [[ -n "$tag_name" ]]; then
    printf '%s\n' "$tag_name"
    return
  fi

  git ls-remote --tags --refs "$REPO_URL" 'refs/tags/v*' \
    | awk -F/ '{print $3}' \
    | sort -V \
    | tail -n 1
}

TAG="$(resolve_tag)"
if [[ -z "$TAG" ]]; then
  echo "Could not resolve a release tag." >&2
  exit 1
fi

echo "Installing ${APP_NAME} ${TAG} from source…"
git clone --depth 1 --branch "$TAG" "$REPO_URL" "$tmpdir/src"
cd "$tmpdir/src"

VERSION="$TAG" BUNDLE_VERSION="1" ./scripts/build-app.sh

app_path="$tmpdir/src/dist/${APP_NAME}.app"
if [[ ! -d "$app_path" ]]; then
  echo "Build finished, but ${APP_NAME}.app was not found." >&2
  exit 1
fi

destination="${INSTALL_DIR}/${APP_NAME}.app"
echo "Installing to ${destination}…"
rm -rf "$destination"
ditto "$app_path" "$destination"

echo "Launching…"
open "$destination"
echo "Installed ${TAG}."
