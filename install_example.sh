#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${REPO_ROOT}/scripts/adaptive-bench-build.py"
BENCH=false
BASELINE=false
BUILD_ONLY=false
ALLOW_PROVISIONING=false
LIST=false
DEVICE_ID=''
ENDPOINT=''
FIXTURE_TOKEN=''
FIXTURE_USER=''
ADAPTIVE=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bench) BENCH=true; shift ;;
        --baseline) BASELINE=true; shift ;;
        --build-only) BUILD_ONLY=true; shift ;;
        --allow-provisioning-updates) ALLOW_PROVISIONING=true; shift ;;
        --list) LIST=true; shift ;;
        --endpoint|--fixture-token|--fixture-user|--adaptive)
            [ "$#" -ge 2 ] || { echo 'Missing bench option value' >&2; exit 2; }
            case "$1" in
                --endpoint) ENDPOINT="$2" ;;
                --fixture-token) FIXTURE_TOKEN="$2" ;;
                --fixture-user) FIXTURE_USER="$2" ;;
                --adaptive) ADAPTIVE="$2" ;;
            esac
            shift 2 ;;
        --help) echo 'Usage: install_example.sh [UDID|--list|--build-only] [--bench --endpoint HTTPS --fixture-token fixture-* --fixture-user fixture-* --adaptive true|false [--baseline]] [--allow-provisioning-updates]'; exit 0 ;;
        --*) echo 'Unknown example build flag' >&2; exit 2 ;;
        *) [ -z "$DEVICE_ID" ] || { echo 'Only one device ID is allowed' >&2; exit 2; }; DEVICE_ID="$1"; shift ;;
    esac
done
fail() { echo "$1" >&2; exit 1; }
if [ "$LIST" = true ]; then
    [ "$BENCH" = false ] && [ "$BUILD_ONLY" = false ] && [ "$BASELINE" = false ] && [ -z "$DEVICE_ID$ENDPOINT$FIXTURE_TOKEN$FIXTURE_USER$ADAPTIVE" ] && [ "$ALLOW_PROVISIONING" = false ] || fail 'Device listing cannot be combined with build options'
    xcrun devicectl list devices
    exit 0
fi
[ "$BUILD_ONLY" = false ] || { [ -z "$DEVICE_ID" ] && [ "$ALLOW_PROVISIONING" = false ] || fail 'Build-only cannot install or update provisioning'; }
[ "$BASELINE" = false ] || [ "$BENCH" = true ] || fail 'Baseline requires bench mode'
CONFIGURATION=Release
FLAGS=()
FRAMEWORK_FLAGS=()
APP_FLAGS=DEBUG
HOST_SETTINGS=()
HOST_FLAGS=()
BUILD_DIR="${REPO_ROOT}/build"
if [ "$BENCH" = true ]; then
    [ -n "$ENDPOINT" ] && [ -n "$FIXTURE_TOKEN" ] && [ -n "$FIXTURE_USER" ] && [ -n "$ADAPTIVE" ] || fail 'Bench endpoint, synthetic token, user, and adaptive boolean are required'
    [ "$ADAPTIVE" = true ] || [ "$ADAPTIVE" = false ] || fail 'Adaptive value must be true or false'
    CONFIGURATION=Debug
    FLAGS+=(--bench)
    FRAMEWORK_FLAGS+=(--bench)
    APP_FLAGS+=' BEAROUND_ADAPTIVE_BENCH'
    if [ "$BASELINE" = true ]; then FLAGS+=(--baseline); HOST_FLAGS+=(--baseline); FRAMEWORK_FLAGS+=(--baseline); APP_FLAGS+=' BEAROUND_ADAPTIVE_BASELINE'; fi
    mkdir -p "${BUILD_DIR}/bench-host"
    python3 "$HELPER" host-info --input "${REPO_ROOT}/BeAroundScan/App-Info.plist" \
        --output "${BUILD_DIR}/bench-host/Info.plist" --endpoint "$ENDPOINT" \
        --fixture-token "$FIXTURE_TOKEN" --fixture-user "$FIXTURE_USER" --adaptive "$ADAPTIVE" ${HOST_FLAGS[@]+"${HOST_FLAGS[@]}"}
    HOST_SETTINGS+=("INFOPLIST_FILE=${BUILD_DIR}/bench-host/Info.plist" 'PRODUCT_BUNDLE_IDENTIFIER=io.bearound.BeAround-Scan.adaptivebench' 'CODE_SIGN_ENTITLEMENTS=')
else
    [ -z "$ENDPOINT$FIXTURE_TOKEN$FIXTURE_USER$ADAPTIVE" ] || fail 'Fixture options require explicit bench mode'
fi
FRAMEWORK="${BUILD_DIR}/BearoundSDK.xcframework/ios-arm64/BearoundSDK.framework"
MANIFEST="${BUILD_DIR}/framework-build-manifest.json"
if ! python3 "$HELPER" check-source --repo "$REPO_ROOT" --configuration "$CONFIGURATION" ${FLAGS[@]+"${FLAGS[@]}"} \
    --framework "$FRAMEWORK" --manifest "$MANIFEST" >/dev/null 2>&1; then
    "${REPO_ROOT}/build_framework.sh" ${FRAMEWORK_FLAGS[@]+"${FRAMEWORK_FLAGS[@]}"}
fi
python3 "$HELPER" check-source --repo "$REPO_ROOT" --configuration "$CONFIGURATION" ${FLAGS[@]+"${FLAGS[@]}"} \
    --framework "$FRAMEWORK" --manifest "$MANIFEST"

DERIVED="${BUILD_DIR}/example-${CONFIGURATION}-${BENCH}-${BASELINE}"
DESTINATION='generic/platform=iOS'
SIGNING=()
if [ "$BUILD_ONLY" = true ]; then
    SIGNING+=('CODE_SIGNING_ALLOWED=NO' 'CODE_SIGNING_REQUIRED=NO' 'CODE_SIGN_IDENTITY=')
else
    if [ -z "$DEVICE_ID" ]; then
        DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | awk '/available/ {print $(NF-3)}' | rg '^[0-9A-F-]{36}$' | head -1) || true
    fi
    [ -n "$DEVICE_ID" ] || fail 'No physical device available; use --build-only for an unsigned generic build'
    DESTINATION="platform=iOS,id=${DEVICE_ID}"
    [ "$ALLOW_PROVISIONING" = false ] || SIGNING+=(-allowProvisioningUpdates)
fi
xcodebuild -project "${REPO_ROOT}/BeAroundScan/BeAroundScan.xcodeproj" -scheme BeAroundScan \
    -configuration Debug -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=${APP_FLAGS}" ${HOST_SETTINGS[@]+"${HOST_SETTINGS[@]}"} ${SIGNING[@]+"${SIGNING[@]}"} clean build
APP="${DERIVED}/Build/Products/Debug-iphoneos/BeAroundScan.app"
[ -d "$APP" ] || fail 'Example build produced no app'
python3 "$HELPER" verify-app --repo "$REPO_ROOT" --configuration "$CONFIGURATION" ${FLAGS[@]+"${FLAGS[@]}"} \
    --framework "$FRAMEWORK" --manifest "$MANIFEST" --app "$APP" --output "${BUILD_DIR}/example-build-proof.json"
if [ "$BUILD_ONLY" = true ]; then
    echo "Unsigned build verified; installation not run. Proof: ${BUILD_DIR}/example-build-proof.json"
    exit 0
fi
codesign -dv "$APP" >/dev/null 2>&1 || fail 'Example app is not signed; refusing installation'
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "Physical installation complete; preserve the proof and device receipt before recording a bench result."
