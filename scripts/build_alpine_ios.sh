#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash scripts/build_ios_deps.sh
make -j"$(sysctl -n hw.ncpu)" ios-lib
xcodegen generate --spec ios/project.yml

bundle_id="${ALPINE_BUNDLE_ID:-local.alpineios.app}"
if [[ -n "${ALPINE_DEVELOPMENT_TEAM:-}" ]]; then
    signing=(DEVELOPMENT_TEAM="$ALPINE_DEVELOPMENT_TEAM" -allowProvisioningUpdates)
else
    signing=(CODE_SIGNING_ALLOWED=NO)
fi
image_source=()
if [[ -n "${ALPINE_IMAGE_MANIFEST_URL+x}" ]]; then
    image_source=(ALPINE_IMAGE_MANIFEST_URL="$ALPINE_IMAGE_MANIFEST_URL")
fi
xcodebuild -project ios/WindowsiOS.xcodeproj -scheme WindowsiOS \
    -configuration Release -sdk iphoneos -derivedDataPath build/DerivedData \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    "${image_source[@]}" "${signing[@]}" build

staging="$(mktemp -d "$ROOT/build/ipa.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
ditto build/DerivedData/Build/Products/Release-iphoneos/WindowsiOS.app "$staging/Payload/WindowsiOS.app"
(cd "$staging" && /usr/bin/zip -qry AlpineiOS.ipa Payload)
mv -f "$staging/AlpineiOS.ipa" build/AlpineiOS.ipa
echo "Created build/AlpineiOS.ipa for $bundle_id."
