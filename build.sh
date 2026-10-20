#!/bin/bash
set -euo pipefail

DERIVED_DATA="$PWD/build"
STAGING_DIR="$(mktemp -d)"
OUTPUT_IPA="$PWD/Jottre.ipa"
CLOUD_DIR="/Users/eden/Library/CloudStorage/Nextcloud-cloud.edenkim.mywire.org-gunhyeongkim/Documents/Development/apps/Test"

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
  MARKETING_VERSION=2.1.8 \
  CURRENT_PROJECT_VERSION=0 \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/Jottre.app"

mkdir -p "$STAGING_DIR/Payload"
ditto "$APP_PATH" "$STAGING_DIR/Payload/Jottre.app"

(
  cd "$STAGING_DIR"
  ditto -c -k --sequesterRsrc --keepParent Payload "$OUTPUT_IPA"
)

echo "Created: $OUTPUT_IPA"

cp "$OUTPUT_IPA" "$CLOUD_DIR/Jottre.ipa"