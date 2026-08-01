import XCTest

@testable import BearoundSDK

/// The canonicalisation is the one piece that silently breaks the whole access-point map
/// if it drifts: iOS and Android must produce the SAME identifier for the SAME router,
/// forever. These tests pin that contract — the Android SDK has the mirror of this file.
final class ApIdentifierTests: XCTestCase {

    /// Verified on real hardware during the POC — the office router seen from an iPhone
    /// and from an Android phone. If this assertion ever fails, every access point already
    /// mapped becomes unreachable under the new hash.
    private let officeAp = "2dc5d7448d0b3ef4"

    func testIosAndAndroidFormatsAgreeOnTheSameRouter() {
        // iOS drops leading zeros, Android keeps them — same physical router.
        XCTAssertEqual(ApIdentifier.from("b8:1e:61:0:95:e"), officeAp)
        XCTAssertEqual(ApIdentifier.from("b8:1e:61:00:95:0e"), officeAp)
    }

    func testCaseAndSeparatorDoNotChangeIdentity() {
        XCTAssertEqual(ApIdentifier.from("B8:1E:61:00:95:0E"), officeAp)
        XCTAssertEqual(ApIdentifier.from("b8-1e-61-00-95-0e"), officeAp)
        XCTAssertEqual(ApIdentifier.from("  b8:1e:61:0:95:e  "), officeAp)
    }

    func testIdentifierIsSixteenHexCharacters() throws {
        let id = try XCTUnwrap(ApIdentifier.from("a4:33:d7:fa:48:b8"))
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testDifferentRoutersGetDifferentIdentifiers() {
        XCTAssertNotEqual(
            ApIdentifier.from("b8:1e:61:00:95:0e"),
            ApIdentifier.from("b8:1e:61:00:95:0f")
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
        XCTAssertNil(ApIdentifier.from("b8:1e:61:00:95"))        // 5 octets
        XCTAssertNil(ApIdentifier.from("b8:1e:61:00:95:0e:aa"))  // 7 octets
        XCTAssertNil(ApIdentifier.from("zz:1e:61:00:95:0e"))     // not hex
        XCTAssertNil(ApIdentifier.from("b81e6100950e"))          // no separators
    }
}
