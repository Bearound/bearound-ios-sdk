# CLAUDE.md

Guidance for Claude Code when working in this repository (BeAround iOS SDK).

## Structure

- `BearoundSDK/` — the library. The only code clients ship.
- `BeAroundScan/` — the example / bench app (bundle `io.bearound.BeAround-Scan`).
- `build/BearoundSDK.xcframework` — **prebuilt artifact**, git-ignored, produced by
  `./build_framework.sh`. Read the next section before touching anything here.

## ⚠️ The example does NOT compile the SDK

`BeAroundScan.xcodeproj` links `../build/BearoundSDK.xcframework` — a **prebuilt artifact**.
Editing SDK source and hitting Build produces an app with the **old** SDK inside, silently.

This is not hypothetical: a bench iPhone ran SDK **3.4.5** for weeks while `main` was on
3.7.0, and a field test "validated" a fix that was never in the binary.

**Always build and install with:**

```bash
./install_example.sh          # rebuilds the framework only if SDK source moved, then
./install_example.sh <UDID>   # builds clean, checks signature + version, installs
./install_example.sh --list
```

A build phase (`Verificar frescor do XCFramework`, first in the target) fails the build when
any SDK `.swift` is newer than the artifact, and every build prints
`note: BearoundSDK embarcado neste build: X.Y.Z`. If the phase gets lost (project recreated,
bad merge): `scripts/add-freshness-guard.sh` — idempotent.

**`clean` is deliberate in that script**: a bundle from an incremental build reached a device
*unsigned*, and it only surfaced as `ApplicationVerificationFailed` at install time.

### Which SDK is actually running on a device?

The payload is the source of truth: `sdk.version` reads `CFBundleShortVersionString` from the
embedded framework (`SDKVersion.resolved`). The app's Settings screen shows the same value.
Never infer the version from the branch you last edited.

## Release — the version lives in FOUR places

`release.yml` (triggered by tag `v*`) verifies each against the tag and aborts on the first
mismatch:

| File | Where |
|------|-------|
| `BearoundSDK.podspec` | `spec.version` |
| `BearoundSDK.xcodeproj/project.pbxproj` | `MARKETING_VERSION` (all occurrences) |
| `BearoundSDK/Constants.swift` | `SDKVersion.current` |
| `CHANGELOG.md` | `## [X.Y.Z]` |

**`Constants.swift` is the one that bites.** PR CI does not check it — only the release
workflow does, and that runs *after* you push the tag. A green PR does not prove the release
will pass. Simulate all four locally before tagging; `PUBLISH.md` has the commands.

## Testing

```bash
xcodebuild -project BearoundSDK.xcodeproj -scheme BearoundSDKTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The `BearoundSDK` scheme has **no test action** — using it returns "not currently configured
for the test action", which reads like a broken setup but is just the wrong scheme.

Tests touching `SDKConfigStorage` share one `UserDefaults` suite and must stay in a
`.serialized` suite. A test that passes alone and fails in the suite is usually shared
persisted state, not a real bug — see the deleted `BackgroundScanInfoFreshnessTests`.

## Signing (this Mac signs officially for BeAround)

`DEVELOPMENT_TEAM = 2F225FWN5Q`, automatic signing. The cert
`Apple Development: João Paulo de Sousa (LP65SLSN85)` belongs to the BeAround team — the id
in parentheses is the **individual**, not the team; check `OU` to see the real team.
`-allowProvisioningUpdates` refreshes profiles for **already registered** devices; a new
device must be registered in the portal and takes 24–72h to leave "Processing".

Stale cached profiles cause a persistent "device isn't registered" even after portal
registration — delete the app's profile from `~/Library/MobileDevice/Provisioning Profiles`
and `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, then rebuild.

## Tooling footguns

- **`plutil -extract KEY FORMAT FILE` OVERWRITES the file** with the extracted value. It
  destroyed `BeAroundScan/App-Info.plist` (3155 bytes → 75) and every example build after it
  produced a bundle with no `Info.plist`, unsigned — while still reporting
  `** BUILD SUCCEEDED **`. Always pass `-o -` to print instead:
  `plutil -extract UIBackgroundModes json -o - App-Info.plist`
- `App-Info.plist` carries the 5 `UIBackgroundModes` (`GENERATE_INFOPLIST_FILE = NO`); the
  pbxproj alone does not tell you this, and losing them silently breaks background sync.
- The `xcodeproj` ruby gem is not installed standalone — it ships inside CocoaPods.
  `scripts/add-freshness-guard.sh` locates its `GEM_HOME` for you.
- macOS has no `timeout` (it is `gtimeout`).

## Language

Bench/docs pt-BR; code and commits in English.
