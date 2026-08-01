import Foundation

enum BeaconConstants {
    static let uuid = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
}

/// SDK version resolution — automatic first, compiled constant as last resort.
///
/// Why not just read `Bundle(for:)`: under STATIC linking (CocoaPods default in
/// React Native hosts, or `use_frameworks! :linkage => :static`) the class is
/// compiled into the app binary, so `Bundle(for: BeAroundSDK.self)` resolves
/// to the HOST APP's bundle and `CFBundleShortVersionString` returns the app's
/// version (e.g. "1.0") — which then pollutes the ingest telemetry for every
/// statically-linked host.
///
/// Resolution order:
///  1. Dynamic framework — the class bundle IS the SDK framework; its
///     Info.plist version is stamped by CocoaPods from the podspec. Automatic.
///  2. Static linking — the pod's resource bundle (`BearoundSDKPrivacy.bundle`,
///     which also ships the Apple-required privacy manifest): CocoaPods stamps
///     its Info.plist with `spec.version` at install time. Automatic.
///  3. Compiled constant — last resort (tests, SPM-without-resources). The only
///     manual step, kept honest by the release CI check against the tag.
enum SDKVersion {
    /// Fallback only — release CI verifies it matches the tag.
    static let current = "3.6.4"

    static let resolved: String = {
        let classBundle = Bundle(for: BeAroundSDK.self)
        // 1) Dynamic framework: the class bundle is the SDK's own framework.
        if classBundle.bundleURL.pathExtension == "framework",
           let v = classBundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            return v
        }
        // 2) Static linking: CocoaPods-stamped resource bundle.
        for host in [classBundle, Bundle.main] {
            if let url = host.url(forResource: "BearoundSDKPrivacy", withExtension: "bundle"),
               let bundle = Bundle(url: url),
               let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
                return v
            }
        }
        // 3) Last resort.
        return current
    }()
}
