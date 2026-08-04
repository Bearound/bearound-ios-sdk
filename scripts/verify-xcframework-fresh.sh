#!/bin/bash
#
# Fails the example's build when the linked XCFramework is older than the SDK sources.
#
# The example does NOT compile the SDK — it links the prebuilt
# ../build/BearoundSDK.xcframework. So editing SDK source and hitting Build produced an app
# with the OLD SDK inside, silently. A field test then "validated" a fix that was never in
# the binary. This guard makes that impossible: stale framework, no build.
#
# Runs as a Run Script build phase in BeAroundScan (see scripts/add-freshness-guard.rb).

set -u

REPO_ROOT="${SRCROOT}/.."
SDK_SRC="${REPO_ROOT}/BearoundSDK"
XCFRAMEWORK="${REPO_ROOT}/build/BearoundSDK.xcframework"
PLIST="${XCFRAMEWORK}/ios-arm64/BearoundSDK.framework/Info.plist"

if [ ! -d "$XCFRAMEWORK" ]; then
    echo "error: BearoundSDK.xcframework não existe em build/."
    echo "error: Rode ./build_framework.sh na raiz do repositório antes de buildar o example."
    exit 1
fi

if [ ! -f "$PLIST" ]; then
    echo "error: XCFramework corrompido — Info.plist não encontrado em ios-arm64/."
    echo "error: Rode ./build_framework.sh para regerá-lo."
    exit 1
fi

# -newer compara mtime: qualquer fonte do SDK mais recente que o artefato = artefato velho.
STALE_FILE=$(find "$SDK_SRC" -name '*.swift' -newer "$PLIST" -print -quit 2>/dev/null)

if [ -n "$STALE_FILE" ]; then
    echo "error: o XCFramework está DESATUALIZADO em relação ao fonte do SDK."
    echo "error: alterado depois do último build: ${STALE_FILE#${REPO_ROOT}/}"
    echo "error: Rode ./build_framework.sh na raiz do repositório e builde de novo."
    echo "error: (ou use ./install_example.sh, que faz os dois na ordem certa)"
    exit 1
fi

FW_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "?")
echo "note: BearoundSDK embarcado neste build: ${FW_VERSION}"
