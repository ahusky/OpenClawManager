#!/bin/bash
set -euo pipefail

APP_NAME="OpenClaw"
EXECUTABLE="OpenClaw"
VERSION="1.0.0"
MIN_MACOS="13.0"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "🔨 Building ${APP_NAME} v${VERSION}..."

rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES}"

# ---------- 编译 ----------
echo "📦 Compiling Swift..."

ARCH=$(uname -m)
if [ "${ARCH}" = "arm64" ]; then
    TARGET="arm64-apple-macosx${MIN_MACOS}"
else
    TARGET="x86_64-apple-macosx${MIN_MACOS}"
fi

if [ "${UNIVERSAL:-0}" = "1" ]; then
    echo "  → Building universal binary (arm64 + x86_64)..."
    swiftc -O -whole-module-optimization \
        -target "arm64-apple-macosx${MIN_MACOS}" \
        -sdk "$(xcrun --show-sdk-path)" \
        -o "${BUILD_DIR}/${EXECUTABLE}-arm64" \
        "${SCRIPT_DIR}/Sources/main.swift"
    swiftc -O -whole-module-optimization \
        -target "x86_64-apple-macosx${MIN_MACOS}" \
        -sdk "$(xcrun --show-sdk-path)" \
        -o "${BUILD_DIR}/${EXECUTABLE}-x86_64" \
        "${SCRIPT_DIR}/Sources/main.swift"
    lipo -create \
        "${BUILD_DIR}/${EXECUTABLE}-arm64" \
        "${BUILD_DIR}/${EXECUTABLE}-x86_64" \
        -output "${MACOS_DIR}/${EXECUTABLE}"
    rm "${BUILD_DIR}/${EXECUTABLE}-arm64" "${BUILD_DIR}/${EXECUTABLE}-x86_64"
else
    echo "  → Building for ${ARCH}..."
    swiftc -O -whole-module-optimization \
        -target "${TARGET}" \
        -sdk "$(xcrun --show-sdk-path)" \
        -o "${MACOS_DIR}/${EXECUTABLE}" \
        "${SCRIPT_DIR}/Sources/main.swift"
fi

chmod +x "${MACOS_DIR}/${EXECUTABLE}"

# ---------- Info.plist ----------
echo "📋 Copying Info.plist..."
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS}/Info.plist"

# ---------- 图标 ----------
# 支持格式: png, jpg, jpeg, tiff, heic, gif, icns
ICON_SRC=""
ICON_DIRECT_ICNS=""

for candidate in "${SCRIPT_DIR}/icon" "${SCRIPT_DIR}/Assets/icon" "${SCRIPT_DIR}/AppIcon"; do
    if [ -f "${candidate}.icns" ]; then
        ICON_DIRECT_ICNS="${candidate}.icns"
        break
    fi
    for ext in png jpg jpeg tiff heic gif; do
        if [ -f "${candidate}.${ext}" ]; then
            ICON_SRC="${candidate}.${ext}"
            break 2
        fi
    done
done

if [ -n "${ICON_DIRECT_ICNS}" ]; then
    echo "🎨 Copying existing .icns: ${ICON_DIRECT_ICNS}"
    cp "${ICON_DIRECT_ICNS}" "${RESOURCES}/AppIcon.icns"
elif [ -n "${ICON_SRC}" ]; then
    echo "🎨 Generating AppIcon.icns from ${ICON_SRC}..."
    ICONSET="${BUILD_DIR}/AppIcon.iconset"
    mkdir -p "${ICONSET}"
    sips -z   16   16 "${ICON_SRC}" --out "${ICONSET}/icon_16x16.png"      > /dev/null 2>&1
    sips -z   32   32 "${ICON_SRC}" --out "${ICONSET}/icon_16x16@2x.png"   > /dev/null 2>&1
    sips -z   32   32 "${ICON_SRC}" --out "${ICONSET}/icon_32x32.png"      > /dev/null 2>&1
    sips -z   64   64 "${ICON_SRC}" --out "${ICONSET}/icon_32x32@2x.png"   > /dev/null 2>&1
    sips -z  128  128 "${ICON_SRC}" --out "${ICONSET}/icon_128x128.png"    > /dev/null 2>&1
    sips -z  256  256 "${ICON_SRC}" --out "${ICONSET}/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z  256  256 "${ICON_SRC}" --out "${ICONSET}/icon_256x256.png"    > /dev/null 2>&1
    sips -z  512  512 "${ICON_SRC}" --out "${ICONSET}/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z  512  512 "${ICON_SRC}" --out "${ICONSET}/icon_512x512.png"    > /dev/null 2>&1
    sips -z 1024 1024 "${ICON_SRC}" --out "${ICONSET}/icon_512x512@2x.png" > /dev/null 2>&1
    iconutil -c icns "${ICONSET}" -o "${RESOURCES}/AppIcon.icns"
    rm -rf "${ICONSET}"
    echo "  → AppIcon.icns created"
else
    echo "⚠️  No icon found. Supported: icon.png/jpg/jpeg/tiff/heic/gif/icns in project root"
fi

# ---------- 签名 ----------
if [ -n "${SIGN_IDENTITY}" ]; then
    echo "🔏 Signing with: ${SIGN_IDENTITY}..."
    codesign --force --deep --options runtime \
        --entitlements "${SCRIPT_DIR}/entitlements.plist" \
        --sign "${SIGN_IDENTITY}" \
        "${APP_DIR}"
else
    echo "🔏 Ad-hoc signing..."
    codesign --force --deep \
        --entitlements "${SCRIPT_DIR}/entitlements.plist" \
        --sign - \
        "${APP_DIR}"
fi

# ---------- 验证 ----------
echo "✅ Verifying..."
codesign --verify --verbose "${APP_DIR}" 2>&1 | head -3

APP_SIZE=$(du -sh "${APP_DIR}" | cut -f1)

echo ""
echo "✅ Build successful!"
echo "   ${APP_DIR}"
echo "   Size: ${APP_SIZE}"
echo ""
echo "📌 Run:     open \"${APP_DIR}\""
echo "📌 Install: cp -R \"${APP_DIR}\" /Applications/"
