#!/bin/bash
# A scheme post-action runs after SPM embedding and the app's normal code signing.
set -euo pipefail
APP_BUNDLE="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
SPARKLE_EMBEDDED="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
/usr/bin/python3 "${SRCROOT:?}/BuildSupport/localize-sparkle.py" \
  "$SPARKLE_EMBEDDED" "$SRCROOT/Localizable.xcstrings"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  # Both resource seals cover the customized strings; restore them inside-out.
  for bundle in "$SPARKLE_EMBEDDED" "$APP_BUNDLE"; do
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
      --preserve-metadata=identifier,entitlements,flags,runtime "$bundle"
  done
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi
