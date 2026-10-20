#!/usr/bin/env bash
# Installer package for 한녕 (Hannyeong) built from the release app (scripts/build-release.sh).
# Installs into the current user's ~/Library/Input Methods — the same place as earlier manual installs and
# the developer build — then registers and selects the input source as the logged-in user.
#
#   ./scripts/build-pkg.sh          # unsigned pkg for local testing
#   ./scripts/build-pkg.sh --sign   # productsign with Developer ID Installer, notarize, staple, verify
#   HANNYEONG_RELEASE_OUT=<dir with Hannyeong.app> ./scripts/build-pkg.sh --sign   # another release build
set -euo pipefail

TASK_SIGN=0
for TASK_ARGUMENT in "$@"; do
    case "$TASK_ARGUMENT" in
        --sign) TASK_SIGN=1 ;;
        *) echo "알 수 없는 옵션: $TASK_ARGUMENT" >&2; exit 2 ;;
    esac
done

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_OUT="${HANNYEONG_RELEASE_OUT:-$TASK_ROOT/dist/release}"
TASK_APP="$TASK_OUT/Hannyeong.app"
TASK_STAGE="$TASK_ROOT/.build/release-bundle/pkg"
TASK_INSTALLER_IDENTITY="${HANNYEONG_INSTALLER_IDENTITY:-Developer ID Installer: Sang Yeop Lim (79Q5RV23F9)}"
TASK_PROFILE="${HANNYEONG_NOTARY_PROFILE:-FlowClip-Notary}"

if [[ ! -d "$TASK_APP" ]]; then
    echo "릴리스 앱이 없습니다. 먼저 ./scripts/build-release.sh를 실행하세요: $TASK_APP" >&2
    exit 1
fi
/usr/bin/codesign --verify --strict --deep "$TASK_APP"
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")"
TASK_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TASK_APP/Contents/Info.plist")"
TASK_UNSIGNED="$TASK_STAGE/Hannyeong-$TASK_VERSION-arm64-unsigned.pkg"
TASK_PKG="$TASK_OUT/Hannyeong-$TASK_VERSION-arm64.pkg"

if [[ "$TASK_SIGN" == 1 ]] && ! /usr/bin/security find-identity -v | grep -Fq "\"$TASK_INSTALLER_IDENTITY\""; then
    cat >&2 <<TEXT
서명할 Installer 인증서가 이 키체인에 없습니다: $TASK_INSTALLER_IDENTITY
Apple Developer 계정 → Certificates → "+" → "Developer ID Installer"로 인증서를 만들고
내려받은 .cer를 열어 로그인 키체인에 추가한 뒤 다시 실행하세요. (서명 없는 pkg는 --sign 없이 만들 수 있습니다.)
TEXT
    exit 1
fi

rm -rf "$TASK_STAGE"
mkdir -p "$TASK_STAGE/root" "$TASK_STAGE/scripts" "$TASK_STAGE/resources"
/usr/bin/ditto "$TASK_APP" "$TASK_STAGE/root/Hannyeong.app"

# Without this, Installer "upgrades" any other copy with the same bundle ID it finds on disk
# (e.g. a build in dist/) instead of writing to Input Methods.
/usr/bin/pkgbuild --analyze --root "$TASK_STAGE/root" "$TASK_STAGE/components.plist"
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' -c 'Set :0:BundleOverwriteAction upgrade' "$TASK_STAGE/components.plist"

cat > "$TASK_STAGE/scripts/preinstall" <<'SCRIPT'
#!/bin/bash
# Replace the whole bundle so files from an older build never linger. User data in
# ~/Library/Application Support/Hannyeong is not touched.
TARGET="$2"
[[ -n "$TARGET" ]] || exit 0
/usr/bin/pkill -x Hannyeong 2>/dev/null || true
/bin/rm -rf "$TARGET/Hannyeong.app"
# Versions before 0.2.0 were installed as JevType.app; the new app disables that input source on registration.
/usr/bin/pkill -x JevType 2>/dev/null || true
/bin/rm -rf "$TARGET/JevType.app"
exit 0
SCRIPT

cat > "$TASK_STAGE/scripts/postinstall" <<'SCRIPT'
#!/bin/bash
# Register and select 한녕 in the logged-in user's GUI session.
TARGET="$2"
APP="$TARGET/Hannyeong.app"
BINARY="$APP/Contents/MacOS/Hannyeong"
LOG="/tmp/hannyeong-install.log"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
log "postinstall uid=$(id -u) target=$TARGET"
[[ -x "$BINARY" ]] || { log "binary missing: $BINARY"; exit 0; }

CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console)"
if [[ "$(id -u)" == 0 ]]; then
    if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == root || "$CONSOLE_USER" == loginwindow ]]; then
        log "no console user; registration happens at next login"; exit 0
    fi
    CONSOLE_UID="$(id -u "$CONSOLE_USER")"
    as_user() { /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"; }
else
    as_user() { "$@"; }
fi

as_user "$BINARY" --register-input-source >> "$LOG" 2>&1 || log "register failed"
as_user /usr/bin/killall TextInputMenuAgent >> "$LOG" 2>&1 || true
sleep 1
as_user "$BINARY" --select-input-source >> "$LOG" 2>&1 || log "select failed (macOS may need a logout/login first)"
# Registration never fails the install: the files are in place, and a logout/login completes it.
exit 0
SCRIPT
chmod 755 "$TASK_STAGE/scripts/preinstall" "$TASK_STAGE/scripts/postinstall"

/usr/bin/pkgbuild --root "$TASK_STAGE/root" --component-plist "$TASK_STAGE/components.plist" \
    --identifier com.yeop.inputmethod.Hannyeong.pkg --version "$TASK_VERSION.$TASK_BUILD" \
    --install-location "/Library/Input Methods" --scripts "$TASK_STAGE/scripts" \
    "$TASK_STAGE/Hannyeong-component.pkg"

cat > "$TASK_STAGE/resources/welcome.html" <<'HTML'
<html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body style="font-family:-apple-system;font-size:13px">
<h2>한녕 설치</h2>
<p>한녕(Hannyeong)을 이 사용자 계정의 <code>~/Library/Input Methods</code>에 설치하고 입력 소스로 등록합니다. 관리자 암호는 필요하지 않습니다.</p>
<p>모든 한·영 판별은 이 Mac 안에서만 이루어지며 네트워크 요청을 보내지 않습니다. 기존 교정 기록(<code>~/Library/Application Support/Hannyeong</code>)은 그대로 유지되고 적용됩니다. 비슷한 문맥으로 넓혀 주는 개인 보정값은 판별 모델마다 따로 저장되어, 업데이트로 모델이 바뀌면 새 모델에서 다시 쌓입니다. 이전 모델의 보정 파일은 지우지 않고 보관하며 새 모델에는 적용하지 않습니다.</p>
<p>요구 사항: Apple Silicon Mac, macOS 15.0 이상 (macOS 27.2에서 검증).</p>
</body></html>
HTML
cat > "$TASK_STAGE/resources/conclusion.html" <<'HTML'
<html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body style="font-family:-apple-system;font-size:13px">
<h2>설치를 마쳤습니다</h2>
<p>메뉴바의 입력 메뉴에서 <b>한녕</b>을 선택하세요.</p>
<p><b>메뉴에 한녕이 보이지 않으면</b> 작업을 저장하고 <b>로그아웃 후 다시 로그인</b>하세요. 최근 macOS는 새 입력 소스를 로그아웃 전까지 목록에 반영하지 않는 경우가 있습니다(Apple에서 확인한 동작). 그래도 없으면 시스템 설정 → 키보드 → 텍스트 입력 → 입력 소스 → 편집 → + → 한국어 → 한녕을 추가하세요.</p>
<p>Finder에서는 앱이 “한녕”으로 보이지만 실제 파일 이름은 <code>Hannyeong.app</code>입니다.</p>
</body></html>
HTML
cat > "$TASK_STAGE/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>한녕 $TASK_VERSION</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
    <volume-check><allowed-os-versions><os-version min="15.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="default"><line choice="com.yeop.inputmethod.Hannyeong.pkg"/></line></choices-outline>
    <choice id="default"/>
    <choice id="com.yeop.inputmethod.Hannyeong.pkg" visible="false"><pkg-ref id="com.yeop.inputmethod.Hannyeong.pkg"/></choice>
    <pkg-ref id="com.yeop.inputmethod.Hannyeong.pkg" version="$TASK_VERSION.$TASK_BUILD" onConclusion="none">Hannyeong-component.pkg</pkg-ref>
</installer-gui-script>
XML
/usr/bin/productbuild --distribution "$TASK_STAGE/distribution.xml" --resources "$TASK_STAGE/resources" \
    --package-path "$TASK_STAGE" "$TASK_UNSIGNED"
echo "서명 전 pkg: $TASK_UNSIGNED ($(du -h "$TASK_UNSIGNED" | cut -f1))"

if [[ "$TASK_SIGN" == 1 ]]; then
    rm -f "$TASK_PKG"
    /usr/bin/productsign --sign "$TASK_INSTALLER_IDENTITY" --timestamp "$TASK_UNSIGNED" "$TASK_PKG"
    /usr/sbin/pkgutil --check-signature "$TASK_PKG"
    xcrun notarytool submit "$TASK_PKG" --keychain-profile "$TASK_PROFILE" --wait
    xcrun stapler staple "$TASK_PKG"
    xcrun stapler validate "$TASK_PKG"
    /usr/sbin/spctl --assess --type install --verbose=2 "$TASK_PKG"
    echo "공증된 pkg: $TASK_PKG"
fi
