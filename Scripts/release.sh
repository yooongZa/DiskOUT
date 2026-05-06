#!/usr/bin/env bash
# EjectDrives 릴리스 스크립트
#
# 첫 사용 1회만:
#   xcrun notarytool store-credentials EJECT_NOTARY \
#     --apple-id sukmack@gmail.com \
#     --team-id 495S4FVMCB \
#     --password <앱-암호>
#
# 매번 릴리스:
#   ./Scripts/release.sh 1.0.0
#
# 결과: build/release-out/EjectDrives-v1.0.0.zip (그대로 배포 가능)

set -euo pipefail

# ───── 설정 ─────────────────────────────────────────────
TEAM_ID="495S4FVMCB"
SIGN_ID="Developer ID Application: roh yongwook (495S4FVMCB)"
KEYCHAIN_PROFILE="EJECT_NOTARY"
PROJECT="EjectDrives.xcodeproj"
SCHEME="EjectDrives"
APP_NAME="EjectDrives"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build/release-derived"
OUT="$ROOT/build/release-out"
mkdir -p "$OUT"

# ───── 색상 ─────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\033[1;34m'; G=$'\033[1;32m'; R=$'\033[1;31m'
  Y=$'\033[1;33m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; G=""; R=""; Y=""; D=""; N=""
fi
step() { echo "${B}▶${N} $*"; }
ok()   { echo "${G}✓${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
die()  { echo "${R}✗${N} $*" >&2; exit 1; }

# ───── 인자 ─────────────────────────────────────────────
VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "사용법: ./Scripts/release.sh <버전>   예: ./Scripts/release.sh 1.0.0"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "버전 형식 이상함: '$VERSION' (예: 1.0.0)"

# 빌드 번호: git commit 갯수 (자동 증가, 신경 안 써도 됨)
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# ───── 사전 점검 ─────────────────────────────────────────
step "사전 점검"
command -v xcodegen   >/dev/null || die "xcodegen 없음 → brew install xcodegen"
command -v xcodebuild >/dev/null || die "xcodebuild 없음 → Xcode 설치 필요"

security find-identity -v -p codesigning | grep -q "$SIGN_ID" \
  || die "키체인에 '$SIGN_ID' 인증서 없음"
ok "Developer ID 인증서"

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  die "notarytool 자격증명 '$KEYCHAIN_PROFILE' 없음.
   이거 한 번만 실행하세요:
     xcrun notarytool store-credentials $KEYCHAIN_PROFILE \\
       --apple-id sukmack@gmail.com \\
       --team-id $TEAM_ID \\
       --password <앱-암호>
   앱-암호는 https://appleid.apple.com → '앱 암호' 에서 발급."
fi
ok "notarytool 자격증명"
ok "버전 v$VERSION (빌드 $BUILD_NUMBER)"

# ───── 빌드 ─────────────────────────────────────────────
step "xcodeproj 재생성"
xcodegen generate >/dev/null

step "Release 빌드 + Developer ID 서명"
rm -rf "$DERIVED"
BUILD_CMD=(xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -derivedDataPath "$DERIVED"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGN_ID"
  DEVELOPMENT_TEAM="$TEAM_ID"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
  clean build
)
if command -v xcbeautify >/dev/null; then
  "${BUILD_CMD[@]}" | xcbeautify
else
  "${BUILD_CMD[@]}"
fi

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "빌드 결과물 없음: $APP"
xattr -cr "$APP"   # iCloud xattr 가 codesign 깨는 이슈 방어
ok "빌드 완료"

# ───── 서명 검증 ─────────────────────────────────────────
step "서명 검증"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed "s/^/  ${D}/;s/$/${N}/"
ok "codesign verify 통과"

# ───── 노타리 ───────────────────────────────────────────
ZIP_NOTARY="$OUT/${APP_NAME}-notary.zip"
rm -f "$ZIP_NOTARY"
ditto -c -k --keepParent "$APP" "$ZIP_NOTARY"

step "Apple 노타리 제출 (보통 1~5분, 길면 30분)"
SUBMIT_LOG="$OUT/notary-submit.log"
if ! xcrun notarytool submit "$ZIP_NOTARY" \
       --keychain-profile "$KEYCHAIN_PROFILE" \
       --wait \
       2>&1 | tee "$SUBMIT_LOG"; then
  SUB_ID="$(awk '/id:/ {print $2; exit}' "$SUBMIT_LOG")"
  if [[ -n "$SUB_ID" ]]; then
    warn "노타리 거절. 상세 로그 보려면:"
    echo "    xcrun notarytool log $SUB_ID --keychain-profile $KEYCHAIN_PROFILE"
  fi
  die "노타리 실패"
fi
ok "노타리 통과"

# ───── 스테이플 ─────────────────────────────────────────
step "스테이플 (오프라인에서도 통과되도록 도장 박기)"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" >/dev/null
ok "스테이플 완료"

step "Gatekeeper 최종 검증"
spctl -a -t exec -vv "$APP" 2>&1 | sed "s/^/  ${D}/;s/$/${N}/"
ok "Gatekeeper accept"

# ───── 패키징 ───────────────────────────────────────────
ZIP_FINAL="$OUT/${APP_NAME}-v${VERSION}.zip"
rm -f "$ZIP_FINAL" "$ZIP_NOTARY"
ditto -c -k --keepParent "$APP" "$ZIP_FINAL"

SHA="$(shasum -a 256 "$ZIP_FINAL" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP_FINAL" | cut -f1)"

echo
echo "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo "${G}✅ EjectDrives v$VERSION 배포본 완성${N}"
echo "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo "  파일:    $ZIP_FINAL"
echo "  크기:    $SIZE"
echo "  sha256:  $SHA"
echo
echo "다음 단계:"
echo "  1) 다른 Mac/계정에서 zip 풀어 더블클릭 → 경고 없이 열리면 OK"
echo "  2) GitHub Releases 에 zip 업로드"
