#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DEVELOPER_ROOT="${DEVELOPER_DIR:-/Volumes/Data/Applications/Xcode-beta.app/Contents/Developer}"
SWIFT_EXEC="${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SDK_PATH="$(DEVELOPER_DIR="${DEVELOPER_ROOT}" xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(DEVELOPER_DIR="${DEVELOPER_ROOT}" xcrun --sdk macosx --show-sdk-version)"
CLEAN_BUILD_ROOT=0
if [[ -n "${BUTAI_BUILD_ROOT:-}" ]]; then
    BUILD_ROOT="${BUTAI_BUILD_ROOT}"
else
    BUILD_ROOT="$(mktemp -d /private/tmp/ButaiReleaseBuild.XXXXXX)"
    CLEAN_BUILD_ROOT=1
fi
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/Butai.app"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "${PROJECT_DIR}/Packaging/Info.plist")"
ZIP_PATH="${DIST_DIR}/Butai-${APP_VERSION}-macOS.zip"
ARCHIVE_DIR="${DIST_DIR}/archive"

cleanup() {
    if [[ "${CLEAN_BUILD_ROOT:-0}" == 1 &&
          "${BUILD_ROOT}" == /private/tmp/ButaiReleaseBuild.* ]]; then
        rm -rf -- "${BUILD_ROOT}"
    fi
}
trap cleanup EXIT

if [[ -e "${ZIP_PATH}" ]]; then
    print -u2 "Refusing to overwrite ${ZIP_PATH}."
    exit 2
fi

if [[ -e "${APP_PATH}" ]]; then
    mkdir -p "${ARCHIVE_DIR}"
    EXISTING_VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP_PATH}/Contents/Info.plist")"
    ARCHIVED_APP="${ARCHIVE_DIR}/Butai-${EXISTING_VERSION}.app"
    if [[ -e "${ARCHIVED_APP}" ]]; then
        EXISTING_BUILD="$(plutil -extract CFBundleVersion raw "${APP_PATH}/Contents/Info.plist")"
        ARCHIVED_APP="${ARCHIVE_DIR}/Butai-${EXISTING_VERSION}-build${EXISTING_BUILD}.app"
    fi
    if [[ -e "${ARCHIVED_APP}" ]]; then
        print -u2 "Refusing to overwrite ${ARCHIVED_APP}."
        exit 2
    fi
    mv "${APP_PATH}" "${ARCHIVED_APP}"
fi

mkdir -p "${BUILD_ROOT}/module-cache" "${DIST_DIR}"

export DEVELOPER_DIR="${DEVELOPER_ROOT}"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_ROOT}/module-cache"

"${SWIFT_EXEC}" build \
    --disable-sandbox \
    --configuration release \
    -debug-info-format none \
    --product Butai \
    --scratch-path "${BUILD_ROOT}/swiftpm" \
    --sdk "${SDK_PATH}" \
    -Xlinker -platform_version \
    -Xlinker macos \
    -Xlinker 14.0 \
    -Xlinker "${SDK_VERSION}"

BIN_DIR="$("${SWIFT_EXEC}" build \
    --disable-sandbox \
    --configuration release \
    --scratch-path "${BUILD_ROOT}/swiftpm" \
    --sdk "${SDK_PATH}" \
    --show-bin-path)"

mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${PROJECT_DIR}/Packaging/Info.plist" "${APP_PATH}/Contents/Info.plist"
cp "${BIN_DIR}/Butai" "${APP_PATH}/Contents/MacOS/Butai"
chmod 755 "${APP_PATH}/Contents/MacOS/Butai"

# Keep the designated requirement stable across local builds. A plain ad-hoc
# signature defaults to a content hash, which makes macOS invalidate Butai's
# Accessibility permission after every update.
codesign \
    --force \
    --sign - \
    --timestamp=none \
    --requirements '=designated => identifier "com.butai.app"' \
    "${APP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

plutil -lint "${APP_PATH}/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

LINKED_SDK="$(vtool -show-build "${APP_PATH}/Contents/MacOS/Butai" | awk '/sdk / { print $2; exit }')"
if [[ "${LINKED_SDK}" != "${SDK_VERSION}" ]]; then
    print -u2 "Expected linked SDK ${SDK_VERSION}, got ${LINKED_SDK}."
    exit 3
fi

print "Created ${APP_PATH}"
print "Created ${ZIP_PATH}"
print "Linked against macOS SDK ${LINKED_SDK}"
