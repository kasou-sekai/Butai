#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DEVELOPER_ROOT="${DEVELOPER_DIR:-/Volumes/Data/Applications/Xcode-beta.app/Contents/Developer}"
BUILD_ROOT="${BUTAI_BUILD_ROOT:-/private/tmp/ButaiReleaseBuild}"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/Butai.app"
ZIP_PATH="${DIST_DIR}/Butai-0.3.0-macOS.zip"
ARCHIVE_DIR="${DIST_DIR}/archive"

if [[ -e "${ZIP_PATH}" ]]; then
    print -u2 "Refusing to overwrite ${ZIP_PATH}."
    exit 2
fi

if [[ -e "${APP_PATH}" ]]; then
    mkdir -p "${ARCHIVE_DIR}"
    EXISTING_VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP_PATH}/Contents/Info.plist")"
    ARCHIVED_APP="${ARCHIVE_DIR}/Butai-${EXISTING_VERSION}.app"
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

swift build \
    --disable-sandbox \
    --configuration release \
    -debug-info-format none \
    --product Butai \
    --scratch-path "${BUILD_ROOT}/swiftpm"

BIN_DIR="$(swift build \
    --disable-sandbox \
    --configuration release \
    --scratch-path "${BUILD_ROOT}/swiftpm" \
    --show-bin-path)"

mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${PROJECT_DIR}/Packaging/Info.plist" "${APP_PATH}/Contents/Info.plist"
cp "${BIN_DIR}/Butai" "${APP_PATH}/Contents/MacOS/Butai"
chmod 755 "${APP_PATH}/Contents/MacOS/Butai"

codesign --force --sign - --timestamp=none "${APP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

plutil -lint "${APP_PATH}/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

print "Created ${APP_PATH}"
print "Created ${ZIP_PATH}"
