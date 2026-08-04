#!/bin/bash
#
# Builds and installs the BeAroundScan example on a physical device, in the ONLY order that
# produces a correct binary.
#
# Why this script exists: the example does not compile the SDK. It links the prebuilt
# build/BearoundSDK.xcframework. Building the example after editing SDK source therefore
# ships the OLD SDK, silently — a field test once "validated" a fix that was never in the
# binary. This script rebuilds the framework whenever the sources moved, and prints the
# version that actually went onto the phone.
#
# Usage:
#   ./install_example.sh                 # first available device
#   ./install_example.sh <UDID>          # a specific device
#   ./install_example.sh --list          # show devices and exit

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XCFRAMEWORK="${REPO_ROOT}/build/BearoundSDK.xcframework"
PLIST="${XCFRAMEWORK}/ios-arm64/BearoundSDK.framework/Info.plist"
DERIVED="${REPO_ROOT}/BeAroundScan/build_device"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[0;31m%s\033[0m\n' "$1" >&2; exit 1; }

if [ "${1:-}" = "--list" ]; then
    xcrun devicectl list devices
    exit 0
fi

# ---------------------------------------------------------------- 1. framework
if [ ! -f "$PLIST" ] || [ -n "$(find "${REPO_ROOT}/BearoundSDK" -name '*.swift' -newer "$PLIST" -print -quit 2>/dev/null)" ]; then
    bold "==> XCFramework desatualizado (ou ausente) — reconstruindo do fonte"
    "${REPO_ROOT}/build_framework.sh"
else
    bold "==> XCFramework já está à frente do fonte — reaproveitando"
fi

FW_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
bold "    BearoundSDK ${FW_VERSION}"

# ---------------------------------------------------------------- 2. device
DEVICE_ID="${1:-}"
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
        | awk '/available/ {print $(NF-3)}' \
        | grep -E '^[0-9A-F-]{36}$' | head -1) || true
    [ -z "$DEVICE_ID" ] && fail "Nenhum aparelho disponível. Plugue um e rode ./install_example.sh --list"
fi
bold "==> Aparelho ${DEVICE_ID}"

# ---------------------------------------------------------------- 3. build
# clean: um bundle vindo de build incremental já chegou ao device SEM assinatura
# ("code object is not signed at all"), e o erro só aparece na instalação.
bold "==> Buildando o example (clean)"
rm -rf "$DERIVED"
xcodebuild \
    -project "${REPO_ROOT}/BeAroundScan/BeAroundScan.xcodeproj" \
    -scheme BeAroundScan \
    -configuration Debug \
    -destination "platform=iOS,id=${DEVICE_ID}" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    clean build > /tmp/beAroundScan-build.log 2>&1 \
    || { tail -40 /tmp/beAroundScan-build.log; fail "Build falhou — log completo em /tmp/beAroundScan-build.log"; }

APP="${DERIVED}/Build/Products/Debug-iphoneos/BeAroundScan.app"
[ -d "$APP" ] || fail "Build terminou mas o .app não apareceu em ${APP}"

# ---------------------------------------------------------------- 4. conferência
EMBEDDED=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "${APP}/Frameworks/BearoundSDK.framework/Info.plist" 2>/dev/null || echo "?")
[ "$EMBEDDED" = "$FW_VERSION" ] \
    || fail "O .app embarcou ${EMBEDDED}, mas o fonte gerou ${FW_VERSION}. Não instalando."

codesign -dv "$APP" >/dev/null 2>&1 \
    || fail "O .app saiu SEM assinatura — a instalação falharia com ApplicationVerificationFailed."

# ---------------------------------------------------------------- 5. install
bold "==> Instalando"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null \
    || fail "Instalação falhou. Aparelho desbloqueado? Rode ./install_example.sh --list"

bold "==> OK — BeAroundScan no ar com BearoundSDK ${FW_VERSION}"
echo "    Confira em Ajustes dentro do app: a versão exibida tem de ser ${FW_VERSION}."
