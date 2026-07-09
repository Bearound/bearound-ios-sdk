# Bearound iOS — AI agent setup prompt

Hover the block below and click the **copy icon** in its top-right corner to copy
the prompt, then paste it into your AI coding agent (Claude Code, Cursor, Copilot, …)
with your app's repo open. The agent reads the [SDK README](./README.md) and wires
the full iOS background integration.

```text
Integrate the BearoundSDK CocoaPod into this native iOS (Swift) app. First READ the
SDK's README end to end — especially "Required Permissions", "Push Notifications &
Push Token", "Advanced Background Integration", "Basic Usage" (Quick Start), and
"Terminated App Detection" — then do ALL of the following (follow the README Quick
Start; the steps below refine it).

1. Install: add `pod 'BearoundSDK', '~> 3.4'` to the Podfile, run `pod install`, and
   open the generated `.xcworkspace`. CocoaPods only — no Swift Package Manager yet.

2. AppDelegate wiring. Put ALL of this inside
   application(_:didFinishLaunchingWithOptions:), before it returns:
   - BeAroundSDK.shared.registerBackgroundTasks() FIRST — it touches the singleton
     synchronously, which re-arms scanning during state restoration; deferring it
     loses the terminated/background relaunch event.
   - application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
     — REQUIRED to arm the `fetch` background mode; without it iOS never calls
     performFetch and the declared mode is dead.
   - application.registerForRemoteNotifications() (the silent-push wake vector).
   - UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
     { _, _ in } AND set UNUserNotificationCenter.current().delegate = self (make
     AppDelegate conform to UNUserNotificationCenterDelegate); implement
     userNotificationCenter(_:willPresent:withCompletionHandler:) ->
     completionHandler([.banner, .sound]) on iOS 14+, falling back to [.alert, .sound]
     below 14 (.banner is iOS 14+ and the SDK min is iOS 13), so the relaunch
     notification is visible in the FOREGROUND too — without the delegate it never shows.
   - Handle launchOptions[.location] and launchOptions[.bluetoothCentrals]: surface
     the relaunch with a local UNNotificationRequest, or NSLog a greppable tag
     (e.g. "[App] bg-relaunch") so the field test has a visible signal.
   - BeAroundSDK.shared.delegate = self (make AppDelegate conform to
     BeAroundSDKDelegate to receive beacons). The delegate property is WEAK — if you
     use a separate delegate object instead of self, hold it in a strong property or
     callbacks silently stop; self works because UIApplication retains the AppDelegate.
   - BeAroundSDK.shared.configure(businessToken: <MY REAL TOKEN>), then
     BeAroundSDK.shared.startScanning(). These go HERE (README Quick Start), not in a
     view's onAppear/viewDidLoad. If I have NOT given you the real token yet, do NOT
     write a literal placeholder that compiles — never configure(businessToken:
     "your-business-token") or "<ASK ME FOR IT>". HALT and leave a TODO that FAILS to
     compile until I supply it; a token that silently ships makes ingest return 401 and
     the device never appears in the Control Hub.
   Also implement, as separate UIApplicationDelegate methods:
   - didRegisterForRemoteNotificationsWithDeviceToken -> convert the raw Data to hex
     with `let token = deviceToken.map { String(format: "%02x", $0) }.joined()` (this
     IS the "raw APNs hex" — do NOT use deviceToken.description), forward it via
     BeAroundSDK.shared.setPushToken(token), and NSLog("APNS_DEVICE_TOKEN %@", token)
     (that line only appears on a signed device AFTER the human enables the Push
     Notifications capability — see step 5).
   - didFailToRegisterForRemoteNotificationsWithError -> log it. Before the Push
     Notifications capability is enabled this fires with "no valid aps-environment" —
     that is EXPECTED, not a bug to chase.
   - performFetchWithCompletionHandler ->
     BeAroundSDK.shared.performBackgroundFetch { completionHandler($0 ? .newData : .noData) }
     (this is what the setMinimumBackgroundFetchInterval call above arms — wire both or
     neither).
   - handleEventsForBackgroundURLSession ->
     BeAroundSDK.shared.handleBackgroundURLSessionEvents(identifier:completionHandler:).
   - didReceiveRemoteNotification(_:fetchCompletionHandler:) is OPTIONAL/redundant —
     the SDK's AppDelegate swizzle already handles Bearound silent pushes and the
     shipped example omits it. If you add one for symmetry, implement
     application(_:didReceiveRemoteNotification:fetchCompletionHandler:) and ONLY when
     userInfo["bearound"] != nil call
     BeAroundSDK.shared.performBackgroundBLERefreshAndSync(bleScanDuration: 10,
     trigger: "silent_push") { ok in completionHandler(ok ? .newData : .noData) }; for
     EVERY OTHER push call completionHandler(.noData). Never drop the completion handler
     or iOS penalizes the push budget. (The signature is
     performBackgroundBLERefreshAndSync(bleScanDuration:trigger:completion:); it is not
     in the README.)
   For a SwiftUI app, bridge with @UIApplicationDelegateAdaptor(AppDelegate.self).
   (The shipped BeAroundScan example configures in its view model and omits BOTH
   setPushToken and the manual receive handler to prove the zero-code swizzle path —
   deliberately DIVERGE from that: configure in didFinishLaunching per the Quick Start,
   and forward setPushToken; it is idempotent and is your safeguard against
   Firebase/OneSignal swizzling the token to NULL.)

3. Info.plist — FIRST resolve the AUTHORITATIVE plist, then edit ONLY that file. Read
   the app target's build settings: if GENERATE_INFOPLIST_FILE=YES there is NO physical
   Info.plist — the keys live as INFOPLIST_KEY_* build settings, and array keys
   (UIBackgroundModes, BGTaskSchedulerPermittedIdentifiers) effectively REQUIRE a real
   file. So either set GENERATE_INFOPLIST_FILE=NO and point INFOPLIST_FILE at a real
   `.plist`, or (scalar keys only) add them as INFOPLIST_KEY_*. Also confirm NO
   INFOPLIST_KEY_UIBackgroundModes build setting is shadowing the file — Xcode merges
   INFOPLIST_KEY_* ON TOP of INFOPLIST_FILE, so a leftover one silently overrides your
   array (the shipped example has exactly this trap). Edit only the file INFOPLIST_FILE
   actually resolves to. Into it, add:
   - the FIVE UIBackgroundModes — fetch, location, processing, bluetooth-central, AND
     remote-notification. remote-notification is REQUIRED for the silent-push wake
     vector this prompt relies on; do NOT omit it and assume the Xcode Background-Modes
     capability will add it.
   - the two BGTaskSchedulerPermittedIdentifiers (io.bearound.sdk.sync,
     io.bearound.sdk.processing) — a missing identifier means that BGTask silently
     never runs.
   - NSBluetoothAlwaysUsageDescription (REQUIRED — Bluetooth is the primary detection
     path) — a user-facing rationale, no jargon like "beacon".
   Do NOT add the location usage strings by default: the Bluetooth-only default keeps
   ONLY NSBluetoothAlwaysUsageDescription. Add NSLocationWhenInUseUsageDescription and
   NSLocationAlwaysAndWhenInUseUsageDescription ONLY if you enable the Location eye
   (step 4). Do NOT add NSUserTrackingUsageDescription (the SDK does not use the IDFA).

4. Location eye (force-quit survival). Bluetooth-only detection works without it, but
   iOS PURGES the Bluetooth eye on a USER force-quit (swipe-kill from the app switcher).
   So if this app must keep waking AFTER the user swipe-kills it, step 4 is REQUIRED,
   not optional for that case: call BeAroundSDK.shared.requestLocationAuthorization(.always)
   before startScanning() (see "Terminated App Detection") AND add the two
   NSLocation*UsageDescription keys from step 3. Only CoreLocation region monitoring
   (Location "Always") survives a user force-quit.

5. Verify — agent-achievable, offline ONLY. `plutil -lint` validates XML SYNTAX only:
   it prints OK on a plist that has just 1 of the 5 modes and zero BGTask ids, so it
   CANNOT confirm key presence — keep it only as a syntax pre-check. To actually verify,
   dump CONTENT and assert literal presence: `plutil -p <the resolved Info.plist>` (or
   `/usr/libexec/PlistBuddy -c Print`) and confirm all FIVE UIBackgroundMode strings
   AND both io.bearound.sdk.sync / io.bearound.sdk.processing are present. BETTER, assert
   against the BUILT app's Info.plist (inside the compiled `.app` bundle) so a
   build-setting override or a wrong authoritative-plist choice can't hide a miss. That
   plist content check is the only thing you can verify yourself. Do NOT try to confirm
   APNS_DEVICE_TOKEN or any background/terminated detection: before the human enables
   the Push Notifications capability, registerForRemoteNotifications() fails with "no
   valid aps-environment" and no token is issued (EXPECTED). The APNS_DEVICE_TOKEN line,
   silent-push wake, and terminated/background detection can only be confirmed on a
   signed REAL device AFTER the human completes the capabilities + on-device grants below
   and runs the on-device 3-state field test — never claim any of them done from a
   foreground/simulator run.

Guardrails — follow strictly:
- NEVER rely on the SDK's push swizzle alone. Forward the RAW APNs token explicitly
  via setPushToken — the swizzle is intercepted whenever Firebase (or another push
  library) swizzles first, which silently ships a NULL push token. setPushToken is
  idempotent, so this is safe alongside the SDK's auto-capture.
- The SDK must NEVER crash the host app.
- Ask me for my businessToken; never invent one or reuse the example app's token. If I
  haven't given it, HALT with a non-compiling TODO rather than writing any literal
  placeholder that builds — an unsupplied token ships silently (ingest 401, device
  absent from the Control Hub).
- STOP and hand me click-by-click steps for anything only a human can do: the Xcode
  Push Notifications capability with my provisioning profile — set aps-environment =
  `development` for Debug and `production` for Release (a Release/TestFlight build
  left on development silently fails the silent-push wake in production), with
  CODE_SIGN_ENTITLEMENTS pointing at the .entitlements in BOTH configs; the Xcode
  Background Modes capability -> enable Remote notifications (plus Location updates
  and Uses Bluetooth LE accessories); and on-device Always location + Background App
  Refresh. Do not attempt those yourself.
```

Web-capable agents can fetch this prompt directly from its raw URL:
`https://raw.githubusercontent.com/Bearound/bearound-ios-sdk/main/AI-AGENT-SETUP.md`
