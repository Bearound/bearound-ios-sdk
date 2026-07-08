# Bearound iOS — AI agent setup prompt

Hover the block below and click the **copy icon** in its top-right corner to copy
the prompt, then paste it into your AI coding agent (Claude Code, Cursor, Copilot, …)
with your app's repo open. The agent reads the [SDK README](./README.md) and wires
the full iOS background integration.

```text
Integrate the BearoundSDK CocoaPod into this native iOS (Swift) app. First READ
the SDK's README end to end — especially "Required Permissions", "Push
Notifications & Push Token", "Advanced Background Integration", "Basic Usage"
(Quick Start), and "Terminated App Detection" — then do ALL of the following,
matching the README's proven-working example EXACTLY:

1. Install: add `pod 'BearoundSDK', '~> 3.4'` to the Podfile, run `pod install`,
   and open the generated `.xcworkspace`. There is NO Swift Package Manager
   support yet — CocoaPods only (or the manual XCFramework the README describes).

2. AppDelegate wiring (Quick Start + Advanced Background Integration): wire the
   COMPLETE AppDelegate — EVERY method, none optional. Inside
   application(_:didFinishLaunchingWithOptions:), before it returns:
   - BeAroundSDK.shared.registerBackgroundTasks() FIRST — it touches the
     singleton synchronously, which is what re-arms scanning during state
     restoration; deferring it loses the terminated/background relaunch event.
   - application.registerForRemoteNotifications() (the silent-push wake vector).
   - Handle launchOptions[.location] and launchOptions[.bluetoothCentrals]
     (surface the relaunch, e.g. a local notification).
   - BeAroundSDK.shared.configure(businessToken: <ASK ME FOR IT>), then
     BeAroundSDK.shared.delegate = <your delegate>, then
     BeAroundSDK.shared.startScanning(). These three go HERE, in
     didFinishLaunchingWithOptions — NOT in a view's onAppear/viewDidLoad (the
     README is explicit: a view runs too late and misses the restore window).
   Also implement, as separate UIApplicationDelegate methods:
   - performFetchWithCompletionHandler -> BeAroundSDK.shared.performBackgroundFetch
   - didRegisterForRemoteNotificationsWithDeviceToken -> forward the RAW APNs hex
     token via BeAroundSDK.shared.setPushToken(token)
   - didFailToRegisterForRemoteNotificationsWithError (log it — usually a missing
     Push Notifications capability)
   - handleEventsForBackgroundURLSession ->
     BeAroundSDK.shared.handleBackgroundURLSessionEvents(identifier:completionHandler:)
   Implement BeAroundSDKDelegate to receive beacons. For a SwiftUI app, bridge
   this AppDelegate with @UIApplicationDelegateAdaptor(AppDelegate.self).

3. Info.plist: add NSBluetoothAlwaysUsageDescription (REQUIRED — Bluetooth is the
   primary detection path) and, to enable the Location eye / force-quit survival,
   NSLocationWhenInUseUsageDescription + NSLocationAlwaysAndWhenInUseUsageDescription.
   Write user-facing rationales that match what THIS app actually does (no
   internal jargon like "beacon"); Apple reviews them. Add the UIBackgroundModes
   array (fetch, location, processing, bluetooth-central) and the two
   BGTaskSchedulerPermittedIdentifiers (io.bearound.sdk.sync,
   io.bearound.sdk.processing) — if either identifier is missing, that BGTask
   silently never runs. Do NOT add NSUserTrackingUsageDescription on the SDK's
   behalf — it does not use the IDFA. Then run `plutil -lint` and confirm it
   prints OK.

4. Optional Location eye (force-quit survival): if this app needs wake-up after
   the user swipe-kills it, call
   BeAroundSDK.shared.requestLocationAuthorization(.always) before startScanning()
   — see "Terminated App Detection". Bluetooth-only detection works without it
   (but iOS purges the Bluetooth eye on user force-quit).

5. Verify: run the plutil checks and give me the 3-state field-test checklist
   (foreground / background / terminated), and confirm the Xcode console prints
   the APNs device token on launch (proof registration fired).

Guardrails — follow strictly:
- NEVER rely on the SDK's push swizzle alone. Forward the RAW APNs token
  explicitly from didRegisterForRemoteNotificationsWithDeviceToken via
  BeAroundSDK.shared.setPushToken(token) — the swizzle is intercepted whenever
  Firebase (or another push library) swizzles first, which silently ships a NULL
  push token and no terminated-state wake. setPushToken is idempotent, so this is
  safe alongside the SDK's auto-capture.
- The SDK must NEVER crash the host app.
- Ask me for my businessToken; do not invent one.
- STOP and hand me click-by-click steps for anything only a human can do: the
  Xcode Push Notifications capability with my provisioning profile (signed
  aps-environment = development for Debug, production for Release), the Xcode
  Background Modes capability -> Remote notifications (plus Location updates and
  Uses Bluetooth LE accessories), and the on-device permission grants (Always
  location + Background App Refresh). Do not attempt those yourself.
```

Web-capable agents can fetch this prompt directly from its raw URL:
`https://raw.githubusercontent.com/Bearound/bearound-ios-sdk/main/AI-AGENT-SETUP.md`
