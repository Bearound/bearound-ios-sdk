//
//  RichPushTests.swift
//  BearoundSDKTests
//
//  Rich push contract (`bearound_rich` v1): parsing, card count per format/category,
//  per-card tracker URLs and the attachment file-extension mapping used by the extensions.
//

import Foundation
import Testing

@testable import BearoundSDK

private let mediaBase = "https://media.example.com/push-media/"
private let tracker = "https://tracker.example.com"
private let m0 = String(repeating: "a", count: 64)
private let m1 = String(repeating: "b", count: 64)

private func rich(_ format: String, cards: [[String: Any]], version: Any = 1) -> [String: Any] {
    ["v": version, "f": format, "mb": mediaBase, "c": cards]
}

private func card(_ m: String, t: String? = nil, u: String? = nil) -> [String: Any] {
    var out: [String: Any] = ["m": m]
    if let t { out["t"] = t }
    if let u { out["u"] = u }
    return out
}

private let marker: [String: Any] = ["t": "push", "sid": "s1", "d": "ctx+/=", "tr": tracker]

@Suite("Rich push parsing")
struct RichPushParsingTests {
    @Test("parses the APNs object shape with captions, urls and tracking")
    func parsesObjectShape() throws {
        let userInfo: [AnyHashable: Any] = [
            "bearound": marker,
            "bearound_rich": rich("TWO_IMAGES", cards: [card(m0, t: "First", u: "https://shop.example.com/a"), card(m1, t: "Second")]),
        ]
        let payload = try #require(RichPushPayload.parse(userInfo))
        #expect(payload.format == .twoImages)
        #expect(payload.format.categoryIdentifier == BearoundPushCategory.twoImages)
        #expect(payload.cards == [
            RichPushCard(mediaId: m0, caption: "First", url: "https://shop.example.com/a"),
            RichPushCard(mediaId: m1, caption: "Second", url: nil),
        ])
        #expect(payload.tracking == RichPushTracking(d: "ctx+/=", tr: tracker))
    }

    @Test("parses the JSON-string shape of both keys")
    func parsesJSONStringShape() throws {
        let richJSON = String(data: try JSONSerialization.data(withJSONObject: rich("IMAGE", cards: [card(m0)])), encoding: .utf8)
        let markerJSON = String(data: try JSONSerialization.data(withJSONObject: marker), encoding: .utf8)
        let payload = try #require(RichPushPayload.parse(["bearound_rich": richJSON as Any, "bearound": markerJSON as Any]))
        #expect(payload.format == .image)
        #expect(payload.cards.count == 1)
        #expect(payload.tracking != nil)
    }

    @Test("card count per format follows the contract", arguments: [
        ("IMAGE", 1, true), ("IMAGE", 2, false),
        ("TWO_IMAGES", 2, true), ("TWO_IMAGES", 1, false), ("TWO_IMAGES", 3, false),
        ("CAROUSEL", 2, true), ("CAROUSEL", 5, true), ("CAROUSEL", 1, false), ("CAROUSEL", 6, false),
        ("PLAY", 1, true), ("PLAY", 2, false),
    ])
    func cardCountPerFormat(format: String, count: Int, valid: Bool) {
        let cards = (0..<count).map { _ in card(m0) }
        let payload = RichPushPayload.parse(["bearound_rich": rich(format, cards: cards)])
        #expect((payload != nil) == valid)
        if let payload {
            #expect(payload.cards.count == count)
            #expect(BearoundPushCategory.all.contains(payload.format.categoryIdentifier))
        }
    }

    @Test("category ids are the four BEAROUND_ ids")
    func categoryIds() {
        #expect(BearoundPushCategory.all == ["BEAROUND_IMAGE", "BEAROUND_TWO_IMAGES", "BEAROUND_CAROUSEL", "BEAROUND_PLAY"])
        #expect(RichPushFormat.play.categoryIdentifier == "BEAROUND_PLAY")
    }

    @Test("anything outside v1 is the legacy path")
    func rejectsOutsideContract() {
        #expect(RichPushPayload.parse(["bearound_rich": rich("IMAGE", cards: [card(m0)], version: 2)]) == nil)
        #expect(RichPushPayload.parse(["bearound_rich": rich("MESSAGE", cards: [card(m0)])]) == nil)
        #expect(RichPushPayload.parse(["bearound_rich": rich("IMAGE", cards: [card("../etc")])]) == nil)
        #expect(RichPushPayload.parse(["bearound_rich": rich("IMAGE", cards: [["t": "no media"]])]) == nil)
        #expect(RichPushPayload.parse(["bearound_rich": ["v": 1, "f": "IMAGE", "mb": "ftp://x/", "c": [card(m0)]]]) == nil)
        #expect(RichPushPayload.parse(["bearound_rich": "not json"]) == nil)
        #expect(RichPushPayload.parse([:]) == nil)
    }
}

@Suite("Rich push per-card URLs")
struct RichPushURLTests {
    private let encodedMedia0 = "https%3A%2F%2Fmedia.example.com%2Fpush-media%2F" + m0

    @Test("image fetch goes through the tracker view with d, r and idx")
    func trackedImageURL() throws {
        let payload = try #require(RichPushPayload.parse([
            "bearound": marker,
            "bearound_rich": rich("CAROUSEL", cards: [card(m0), card(m1)]),
        ]))
        #expect(payload.imageURL(at: 0)?.absoluteString
            == "\(tracker)/v1/push:view?d=ctx%2B%2F%3D&r=\(encodedMedia0)&idx=0")
        #expect(payload.imageURL(at: 1)?.absoluteString.hasSuffix("push-media%2F\(m1)&idx=1") == true)
        #expect(payload.imageURL(at: 2) == nil)
    }

    @Test("without both d and an https tr the raw media URL is used", arguments: [
        (nil, nil), (nil, tracker), ("ctx", nil), ("ctx", "http://insecure.example.com"),
    ] as [(String?, String?)])
    func rawImageURLWithoutTracking(d: String?, tr: String?) throws {
        var partialMarker: [String: Any] = ["sid": "s1"]
        if let d { partialMarker["d"] = d }
        if let tr { partialMarker["tr"] = tr }
        let payload = try #require(RichPushPayload.parse([
            "bearound": partialMarker,
            "bearound_rich": rich("IMAGE", cards: [card(m0)]),
        ]))
        #expect(payload.tracking == nil)
        #expect(payload.imageURL(at: 0)?.absoluteString == mediaBase + m0)
    }

    @Test("http(s) taps go through the tracker click; deep links open directly")
    func tapURLs() throws {
        let cards = [
            card(m0, u: "https://shop.example.com/p?x=1&y=2"),
            card(m1, u: "myapp://deep/link"),
            card(m0),
        ]
        let tracked = try #require(RichPushPayload.parse(["bearound": marker, "bearound_rich": rich("CAROUSEL", cards: cards)]))
        #expect(tracked.tapURL(at: 0)?.absoluteString
            == "\(tracker)/v1/push:click?d=ctx%2B%2F%3D&r=https%3A%2F%2Fshop.example.com%2Fp%3Fx%3D1%26y%3D2&idx=0")
        #expect(tracked.tapURL(at: 1)?.absoluteString == "myapp://deep/link")
        #expect(tracked.tapURL(at: 2) == nil)

        let untracked = try #require(RichPushPayload.parse(["bearound_rich": rich("CAROUSEL", cards: cards)]))
        #expect(untracked.tapURL(at: 0)?.absoluteString == "https://shop.example.com/p?x=1&y=2")
    }

    @Test("open hit for taps the host app never sees")
    func openURL() {
        let url = RichPush.openURL(RichPushTracking(d: "ctx+/=", tr: tracker))
        #expect(url?.absoluteString == "\(tracker)/v1/push:open?d=ctx%2B%2F%3D")
    }

    @Test("attachment: card 0 of a rich payload, else the legacy image_url")
    func attachmentURL() {
        let legacy = "https://tracker.example.com/v1/push:view?d=x&r=y"
        #expect(RichPush.attachmentURL(from: ["bearound_rich": rich("PLAY", cards: [card(m0, u: "https://video.example.com/v")])])?
            .absoluteString == mediaBase + m0)
        #expect(RichPush.attachmentURL(from: ["image_url": legacy])?.absoluteString == legacy)
        #expect(RichPush.attachmentURL(from: ["bearound_rich": rich("IMAGE", cards: [], version: 9), "image_url": legacy])?
            .absoluteString == legacy)
        #expect(RichPush.attachmentURL(from: ["image_url": "file:///etc/passwd"]) == nil)
        #expect(RichPush.attachmentURL(from: [:]) == nil)
    }
}

@Suite("Rich push attachment extension")
struct RichPushAttachmentExtensionTests {
    @Test("Content-Type maps to the attachment file extension", arguments: [
        ("image/jpeg", "jpg"), ("image/jpg", "jpg"), ("IMAGE/PNG", "png"), ("image/gif", "gif"),
        ("image/jpeg; charset=binary", "jpg"),
    ])
    func mimeMapping(mime: String, ext: String) {
        #expect(RichPush.attachmentFileExtension(mimeType: mime, data: nil) == ext)
    }

    @Test("without a usable Content-Type the file signature decides")
    func signatureFallback() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])
        let gif = Data("GIF89a".utf8)
        let webp = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBP".utf8)
        #expect(RichPush.attachmentFileExtension(mimeType: nil, data: png) == "png")
        #expect(RichPush.attachmentFileExtension(mimeType: "application/octet-stream", data: jpeg) == "jpg")
        #expect(RichPush.attachmentFileExtension(mimeType: nil, data: gif) == "gif")
        // WebP is not an attachment type: nil tells the extension to re-encode it.
        #expect(RichPush.attachmentFileExtension(mimeType: "image/webp", data: webp) == nil)
        #expect(RichPush.attachmentFileExtension(mimeType: nil, data: Data([0x01])) == nil)
    }
}

@Suite("Push token resend on SDK upgrade")
struct PushTokenVersionResendTests {
    @Test("a changed SDK version re-sends the same token once, then stops")
    func versionChangedResendsOnce() {
        let sentAt = Date()
        // Same token, sent a minute ago by the previous SDK version: re-send.
        #expect(PushTokenStore.shouldSend(token: "tok", lastSent: "tok", lastSentAt: sentAt,
                                          lastSentVersion: "3.11.0", currentVersion: "3.12.0", now: sentAt + 60))
        // Installs that predate the version key count as a different version.
        #expect(PushTokenStore.shouldSend(token: "tok", lastSent: "tok", lastSentAt: sentAt,
                                          lastSentVersion: nil, currentVersion: "3.12.0", now: sentAt + 60))
        // After the send is marked with the current version: nothing until rotation or TTL.
        #expect(!PushTokenStore.shouldSend(token: "tok", lastSent: "tok", lastSentAt: sentAt,
                                           lastSentVersion: "3.12.0", currentVersion: "3.12.0", now: sentAt + 60))
    }
}
