#!/bin/bash
read -sp "Mac Password: " MAC_PASSWORD
echo "" # 줄바꿈 처리

KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"

# 2. 시스템/사용자 키체인 검색 경로 지정
security list-keychains -s "$KEYCHAIN_PATH" /Library/Keychains/System.keychain /System/Library/Keychains/SystemRootCertificates.keychain

# 3. 키체인 잠금 해제 및 서명 권한 적용
security unlock-keychain -p "$MAC_PASSWORD" "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MAC_PASSWORD" "$KEYCHAIN_PATH" > /dev/null 2>&1

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
  MARKETING_VERSION=2.4.3 \
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