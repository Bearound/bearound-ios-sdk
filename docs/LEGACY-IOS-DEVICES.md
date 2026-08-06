# Supporting older iOS devices (iOS 13–15, e.g. iPhone 7)

The BeAround SDK targets **iOS 13.0+**. This document explains what it takes to keep it
running on old hardware and the one non‑obvious pitfall introduced by recent Xcode versions.

**Validated on-device (2026-07-17):** iPhone 7 (iPhone9,3, **iOS 15.8.8**) — all three iOS
integration paths launch, detect beacons and sync:

| Integration | Result on iPhone 7 / iOS 15.8 | Change needed |
| --- | --- | --- |
| **Native** (`BeAroundScan` example) | ✅ runs + detects | rebuild the SDK **xcframework** at deployment target `13.0`; gate the example's iOS-16 SwiftUI APIs |
| **Flutter** (`bearound_flutter_sdk`) | ✅ runs + detects + syncs | **none** (source pod) |
| **React Native** (`@bearound/react-native-sdk`) | ✅ runs | **none** (source pod) |

---

## TL;DR

1. Set your **app's iOS deployment target** to the oldest iOS you want to support (`13.0` … `15.0`).
2. If — and only if — you ship a **pre-built `BearoundSDK.xcframework`**, build it with
   `IPHONEOS_DEPLOYMENT_TARGET = 13.0`. Integrating via **CocoaPods** (source) needs nothing extra.
3. In SwiftUI UIs, gate iOS-16-only APIs behind `if #available(iOS 16, *)`.

---

## The pitfall: a pre-built framework built for a too-new OS crashes at launch on old iOS

Xcode 16/26 **auto-sets a high `IPHONEOS_DEPLOYMENT_TARGET`** (e.g. `18.5` or `26.0`) at the
**project** level of new/upgraded projects. A framework compiled with a high deployment target
links against the newer Swift‑Foundation ABI shipped with recent iOS. Some of those symbols do
**not** exist in older iOS, so `dyld` aborts the host app at launch:

```
dyld: Symbol not found: (_$s10Foundation10URLRequestV10httpMethodSSSgvs)   // URLRequest.httpMethod setter
      Referenced from: …/BearoundSDK.framework/BearoundSDK
      Expected in:     …/Foundation.framework/Foundation                    // absent on iOS 15.8
```

`ideviceinstaller install` says *"Complete"* but tapping the icon bounces back to the home
screen. Pull the crash report to confirm the cause (`idevicecrashreport`, file `*.ips` →
`DYLD Symbol missing`).

**Root cause is the framework's `minos`, not the app's.** Check both:

```bash
otool -l <App>.app/<App>            | grep -A3 LC_BUILD_VERSION   # app
otool -l …/BearoundSDK.framework/BearoundSDK | grep -A3 LC_BUILD_VERSION   # embedded SDK
# both must read: minos 13.0 (or ≤ the oldest OS you target)
```

If the embedded SDK reads `minos 18.5` while the app reads `minos 15.6`, that's the bug.

---

## Per-integration guidance

### CocoaPods (source pod) — nothing to do
`BearoundSDK.podspec` is **source-based** (`spec.source_files`, `platform :ios, "13.0"`), so
CocoaPods compiles the SDK **at your app's deployment target**. Set your app to `13.0`–`15.0`
and the produced binary's `minos` matches automatically. This is why **Flutter** and
**React Native** (both `s.dependency 'BearoundSDK'`) run on the iPhone 7 with **no code change** —
Flutter embeds `BearoundSDK.framework` at `minos 13.0`; RN static-links it into the app at `minos 15.1`.

### Pre-built `BearoundSDK.xcframework` — force the low target
The `build_framework.sh` script archives from `BearoundSDK.xcodeproj`. Keep **both** the project-
and target-level `IPHONEOS_DEPLOYMENT_TARGET` at `13.0` before running it, then verify:

```bash
# BearoundSDK.xcodeproj → IPHONEOS_DEPLOYMENT_TARGET = 13.0 (project AND target)
./build_framework.sh
otool -l build/BearoundSDK.xcframework/ios-arm64/BearoundSDK.framework/BearoundSDK \
  | grep -A3 LC_BUILD_VERSION   # → minos 13.0
```

### SwiftUI on an iOS-15 target
If your own UI uses iOS-16 APIs (`NavigationStack`, `.contentTransition(.numericText())`), a
`15.x` deployment target won't compile until they're gated. The `BeAroundScan` example wraps them:

```swift
struct CompatNavigation<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 16.0, *) { NavigationStack(root: content) }
        else { NavigationView(content: content).navigationViewStyle(.stack) }
    }
}
```

---

## Testing on an iOS-15 device from the CLI

Xcode 26's `devicectl` only drives iOS 17+. For iOS 15 use **libimobiledevice**
(`brew install ideviceinstaller`):

```bash
idevice_id -l                                   # 40-hex UDID = pre‑iPhone‑X device
ideviceinfo -u <udid> -k ProductVersion         # 15.8.8
ideviceinstaller -u <udid> install <App>.app    # install (uses lockdown, works on iOS 15)
idevicescreenshot -u <udid> shot.png            # verify it actually launched (not just installed)
idevicecrashreport -u <udid> -k ./crash         # pull crash logs if it bounces to home
```

**Provisioning gotcha:** each bundle id needs its own managed profile that includes the device.
If a cached profile predates the device you'll get `0xe8008015` ("valid provisioning profile not
found"). Delete the stale profile and rebuild with `-allowProvisioningUpdates`:

```bash
find ~/Library/MobileDevice/Provisioning\ Profiles \
     ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles -name '*.mobileprovision' \
  -exec sh -c 'security cms -D -i "$1" | grep -q "<your.bundle.id>" && rm -f "$1"' _ {} \;
# then: flutter build ios --profile   |   xcodebuild … -allowProvisioningUpdates
# confirm the device is in the fresh profile:
security cms -D -i <App>.app/embedded.mobileprovision | grep <udid>
```
