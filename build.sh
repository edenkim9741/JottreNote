#!/bin/bash
set -euo pipefail

DERIVED_DATA="$PWD/build"
STAGING_DIR="$(mktemp -d)"
OUTPUT_IPA="$PWD/Jottre.ipa"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

xcodebuild \
  -scheme Jottre \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  MARKETING_VERSION=2.1.2 \
  CURRENT_PROJECT_VERSION=4 \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/Jottre.app"

mkdir -p "$STAGING_DIR/Payload"
ditto "$APP_PATH" "$STAGING_DIR/Payload/Jottre.app"

(
  cd "$STAGING_DIR"
  ditto -c -k --sequesterRsrc --keepParent Payload "$OUTPUT_IPA"
)

echo "Created: $OUTPUT_IPA"