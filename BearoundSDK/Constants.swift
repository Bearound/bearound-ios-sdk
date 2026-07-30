import Foundation

enum BeaconConstants {
    static let uuid = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
}

/// Compile-time SDK version — the iOS counterpart of Android's
/// `BuildConfig.SDK_VERSION`. MUST match the podspec/tag; the release CI
/// verifies it alongside MARKETING_VERSION.
///
/// Why not read the bundle: under STATIC linking (CocoaPods default in
/// React Native hosts, or `use_frameworks! :linkage => :static`) the class is
/// compiled into the app binary, so `Bundle(for: BeAroundSDK.self)` resolves
/// to the HOST APP's bundle and `CFBundleShortVersionString` returns the app's
/// version (e.g. "1.0") — which then pollutes the ingest telemetry for every
/// statically-linked host. A constant is correct in every linkage mode.
enum SDKVersion {
    static let current = "3.6.2"
}
