import XCTest

@testable import BearoundSDK

/// The canonicalisation is the one piece that silently breaks the whole access-point map
/// if it drifts: iOS and Android must produce the SAME identifier for the SAME router,
/// forever. These tests pin that contract — the Android SDK has the mirror of this file.
final class ApIdentifierTests: XCTestCase {

    /// Golden value for a fixed input, verified on real hardware on BOTH platforms. If this
    /// assertion ever fails, every identifier already issued becomes unreachable under the
    /// new hash — so it is a compatibility gate, not a style check.
    private let goldenId = "9a6abef5e0c70054"

    func testIosAndAndroidFormatsAgreeOnTheSameRouter() {
        // iOS drops leading zeros, Android keeps them — same physical router.
        XCTAssertEqual(ApIdentifier.from("00:0:5e:0:53:1"), goldenId)
        XCTAssertEqual(ApIdentifier.from("00:00:5e:00:53:01"), goldenId)
    }

    func testCaseAndSeparatorDoNotChangeIdentity() {
        XCTAssertEqual(ApIdentifier.from("00:00:5E:00:53:01"), goldenId)
        XCTAssertEqual(ApIdentifier.from("00-00-5e-00-53-01"), goldenId)
        XCTAssertEqual(ApIdentifier.from("  00:0:5e:0:53:1  "), goldenId)
    }

    func testIdentifierIsSixteenHexCharacters() throws {
        let id = try XCTUnwrap(ApIdentifier.from("00:00:5e:00:53:0a"))
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testDifferentRoutersGetDifferentIdentifiers() {
        XCTAssertNotEqual(
            ApIdentifier.from("00:00:5e:00:53:01"),
            ApIdentifier.from("00:00:5e:00:53:02")
        )
    }

    func testPlatformPlaceholdersAreRejected() {
        // Handed back when the entitlement or authorisation is missing — hashing them
        // would invent one phantom access point shared by every unpermitted device.
        XCTAssertNil(ApIdentifier.from("02:00:00:00:00:00"))
        XCTAssertNil(ApIdentifier.from("00:00:00:00:00:00"))
        XCTAssertNil(ApIdentifier.from("ff:ff:ff:ff:ff:ff"))
    }

    func testMalformedInputReturnsNilInsteadOfBogusIdentifier() {
        XCTAssertNil(ApIdentifier.from(nil))
        XCTAssertNil(ApIdentifier.from(""))
        XCTAssertNil(ApIdentifier.from("00:00:5e:00:53"))        // 5 octets
        XCTAssertNil(ApIdentifier.from("00:00:5e:00:53:01:aa"))  // 7 octets
        XCTAssertNil(ApIdentifier.from("zz:00:5e:00:53:01"))     // not hex
        XCTAssertNil(ApIdentifier.from("00005e005301"))          // no separators
    }
}
