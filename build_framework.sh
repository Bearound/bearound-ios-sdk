#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATION=Release
BENCH=false
BASELINE=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bench) BENCH=true; CONFIGURATION=Debug; shift ;;
        --baseline) BASELINE=true; shift ;;
        --configuration) [ "$#" -ge 2 ] || { echo 'Missing configuration' >&2; exit 2; }; CONFIGURATION="$2"; shift 2 ;;
        --help) echo 'Usage: build_framework.sh [--configuration Release|Debug] [--bench [--baseline]]'; exit 0 ;;
        *) echo 'Unknown framework build flag' >&2; exit 2 ;;
    esac
done
[ "$CONFIGURATION" = Release ] || [ "$CONFIGURATION" = Debug ] || { echo 'Invalid configuration' >&2; exit 2; }
[ "$BENCH" = false ] || [ "$CONFIGURATION" = Debug ] || { echo 'Bench requires Debug' >&2; exit 2; }
[ "$BASELINE" = false ] || [ "$BENCH" = true ] || { echo 'Baseline requires bench mode' >&2; exit 2; }

BUILD_DIR="${REPO_ROOT}/build"
WORK="${BUILD_DIR}/framework-work"
HELPER="${REPO_ROOT}/scripts/adaptive-bench-build.py"
FLAGS=()
SWIFT_FLAGS=''
[ "$CONFIGURATION" != Debug ] || SWIFT_FLAGS=DEBUG
if [ "$BENCH" = true ]; then FLAGS+=(--bench); SWIFT_FLAGS+=' BEAROUND_ADAPTIVE_BENCH'; fi
if [ "$BASELINE" = true ]; then FLAGS+=(--baseline); SWIFT_FLAGS+=' BEAROUND_ADAPTIVE_BASELINE'; fi
SOURCE_FP=$(python3 "$HELPER" source --repo "$REPO_ROOT" --configuration "$CONFIGURATION" ${FLAGS[@]+"${FLAGS[@]}"})
mkdir -p "$WORK"
rm -rf "${WORK}/devices.xcarchive" "${WORK}/simulators.xcarchive" "${BUILD_DIR}/BearoundSDK.xcframework"

for SLICE in devices simulators; do
    PLATFORM=iOS
    [ "$SLICE" != simulators ] || PLATFORM='iOS Simulator'
    echo "Building ${CONFIGURATION} SDK for ${PLATFORM}; source fingerprint ${SOURCE_FP}"
    xcodebuild archive -project "${REPO_ROOT}/BearoundSDK.xcodeproj" -scheme BearoundSDK \
        -configuration "$CONFIGURATION" -destination "generic/platform=${PLATFORM}" \
        -archivePath "${WORK}/${SLICE}.xcarchive" -derivedDataPath "${WORK}/DerivedData" \
        SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=${SWIFT_FLAGS}"
done
DEVICE="${WORK}/devices.xcarchive/Products/Library/Frameworks/BearoundSDK.framework"
SIMULATOR="${WORK}/simulators.xcarchive/Products/Library/Frameworks/BearoundSDK.framework"
python3 "$HELPER" stamp --repo "$REPO_ROOT" --configuration "$CONFIGURATION" ${FLAGS[@]+"${FLAGS[@]}"} \
    --framework "$DEVICE" --framework "$SIMULATOR" --output "${BUILD_DIR}/framework-build-manifest.json"
xcodebuild -create-xcframework -framework "$DEVICE" -framework "$SIMULATOR" -output "${BUILD_DIR}/BearoundSDK.xcframework"
cp "${BUILD_DIR}/framework-build-manifest.json" "${BUILD_DIR}/BearoundSDK.xcframework/build-manifest.json"
python3 "$HELPER" check-source --repo "$REPO_ROOT" --configuration "$CONFIGURATION" ${FLAGS[@]+"${FLAGS[@]}"} \
    --framework "${BUILD_DIR}/BearoundSDK.xcframework/ios-arm64/BearoundSDK.framework" \
    --manifest "${BUILD_DIR}/framework-build-manifest.json"
echo "XCFramework verified: ${CONFIGURATION}; source fingerprint ${SOURCE_FP}"
