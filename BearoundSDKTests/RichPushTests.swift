//
//  RichPushTests.swift
//  BearoundSDKTests
//
//  Rich push contract (`bearound_rich` v1): parsing, card count per format/category,
//  per-card tracker URLs and the attachment file-extension mapping used by the extensions.
//

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import BearoundSDK

private let mediaBase = "https://media.example.com/push-media/"
private let tracker = "https://tracker.example.com"
private let m0 = String(repeating: "a", count: 64)
private let m1 = String(repeating: "b", count: 64)

private func rich(_ format: String, cards: [[String: Any]], version: Any = 1) -> [String: Any] {
    ["v": version, "f": format, "mb": mediaBase, "c": cards]
}

private func card(_ m: String, t: String? = nil, u: String? = nil, vt: String? = nil) -> [String: Any] {
    var out: [String: Any] = ["m": m]
    if let t { out["t"] = t }
    if let u { out["u"] = u }
    if let vt { out["vt"] = vt }
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
            #expect(payload.format.categoryIdentifier == "BEAROUND_\(format)")
        }
    }

    @Test("the content extension claims IMAGE, TWO_IMAGES and CAROUSEL, never PLAY")
    func categoryIds() {
        #expect(BearoundPushCategory.contentExtension == ["BEAROUND_IMAGE", "BEAROUND_TWO_IMAGES", "BEAROUND_CAROUSEL"])
        // PLAY keeps its category id (the server sends it), but the system player owns it.
        #expect(BearoundPushCategory.play == "BEAROUND_PLAY")
        #expect(RichPushFormat.play.categoryIdentifier == BearoundPushCategory.play)
        #expect(!BearoundPushCategory.contentExtension.contains(BearoundPushCategory.play))
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
                                          lastSentVersion: "3.12.0", currentVersion: "3.13.0", now: sentAt + 60))
        // Installs that predate the version key count as a different version.
        #expect(PushTokenStore.shouldSend(token: "tok", lastSent: "tok", lastSentAt: sentAt,
                                          lastSentVersion: nil, currentVersion: "3.13.0", now: sentAt + 60))
        // After the send is marked with the current version: nothing until rotation or TTL.
        #expect(!PushTokenStore.shouldSend(token: "tok", lastSent: "tok", lastSentAt: sentAt,
                                           lastSentVersion: "3.13.0", currentVersion: "3.13.0", now: sentAt + 60))
    }
}

@Suite("Rich push PLAY video")
struct RichPushPlayVideoTests {
    private let video = "https://media.example.com/push-media/" + String(repeating: "c", count: 64)

    @Test("PLAY parses the poster in m and the direct video in u")
    func parsesPlay() throws {
        let payload = try #require(RichPushPayload.parse([
            "bearound": marker,
            "bearound_rich": rich("PLAY", cards: [card(m0, u: video, vt: "video/mp4")]),
        ]))
        #expect(payload.format == .play)
        #expect(payload.cards == [RichPushCard(mediaId: m0, caption: nil, url: video, videoType: "video/mp4")])
        #expect(payload.videoURL?.absoluteString == video)
        // The poster fetch goes through the tracker: it is the view.
        #expect(payload.imageURL(at: 0)?.absoluteString.hasPrefix("\(tracker)/v1/push:view?") == true)
        // u is the video, not a tap target: a tap opens the app.
        #expect(payload.tapURL(at: 0) == nil)
    }

    @Test("videoURL only for PLAY with an http(s) u")
    func videoURLOnlyForPlay() throws {
        let noU = try #require(RichPushPayload.parse(["bearound_rich": rich("PLAY", cards: [card(m0)])]))
        #expect(noU.videoURL == nil)
        let deepLink = try #require(RichPushPayload.parse(["bearound_rich": rich("PLAY", cards: [card(m0, u: "myapp://video")])]))
        #expect(deepLink.videoURL == nil)
        let image = try #require(RichPushPayload.parse(["bearound_rich": rich("IMAGE", cards: [card(m0, u: video)])]))
        #expect(image.videoURL == nil)
        #expect(image.tapURL(at: 0)?.absoluteString == video)
    }

    @Test("attachment plan: PLAY downloads video and poster, other formats only the image")
    func attachmentPlan() {
        let play = RichPush.attachmentPlan(from: ["bearound_rich": rich("PLAY", cards: [card(m0, u: video)])])
        #expect(play == RichPushAttachmentPlan(image: URL(string: mediaBase + m0), video: URL(string: video)))

        let playNoVideo = RichPush.attachmentPlan(from: ["bearound_rich": rich("PLAY", cards: [card(m0)])])
        #expect(playNoVideo == RichPushAttachmentPlan(image: URL(string: mediaBase + m0), video: nil))

        let carousel = RichPush.attachmentPlan(from: ["bearound_rich": rich("CAROUSEL", cards: [card(m0, u: video), card(m1)])])
        #expect(carousel == RichPushAttachmentPlan(image: URL(string: mediaBase + m0), video: nil))

        let legacy = "https://tracker.example.com/v1/push:view?d=x&r=y"
        #expect(RichPush.attachmentPlan(from: ["image_url": legacy]) == RichPushAttachmentPlan(image: URL(string: legacy), video: nil))
        #expect(RichPush.attachmentPlan(from: [:]) == nil)
    }

    @Test("the video wins when it made it, else the poster, else nothing")
    func attachmentChoice() {
        #expect(RichPush.preferredAttachment(video: "video", image: "poster") == "video")
        #expect(RichPush.preferredAttachment(video: nil, image: "poster") == "poster")
        #expect(RichPush.preferredAttachment(video: "video", image: nil) == "video")
        #expect(RichPush.preferredAttachment(video: String?.none, image: nil) == nil)
    }

    @Test("size cap: an announced or received size above 15 MB aborts the video")
    func sizeCap() {
        let cap = RichPush.maxVideoBytes
        #expect(cap == 15 * 1024 * 1024)
        #expect(!RichPush.exceedsCap(expected: 2_848_208, received: 0, cap: cap))
        #expect(!RichPush.exceedsCap(expected: cap, received: cap, cap: cap))
        #expect(RichPush.exceedsCap(expected: cap + 1, received: 0, cap: cap))
        // Unknown length (-1, chunked): decided by what arrived.
        #expect(!RichPush.exceedsCap(expected: -1, received: cap - 1, cap: cap))
        #expect(RichPush.exceedsCap(expected: -1, received: cap + 1, cap: cap))
        // A server that under-announces is still cut by the bytes received.
        #expect(RichPush.exceedsCap(expected: 1_000, received: cap + 1, cap: cap))
    }

    @Test("only MP4 bytes become a video attachment")
    func mp4Detection() {
        let ftyp = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        let html = Data("<!doctype html>".utf8)
        #expect(RichPush.isMP4(mimeType: "video/mp4", data: nil))
        #expect(RichPush.isMP4(mimeType: "Video/MP4; codecs=avc1", data: nil))
        #expect(RichPush.isMP4(mimeType: "application/octet-stream", data: ftyp))
        #expect(!RichPush.isMP4(mimeType: "text/html", data: html))
        #expect(!RichPush.isMP4(mimeType: nil, data: Data([0x00])))
    }

    @Test("the type hint is the MPEG-4 uniform type")
    func typeHint() {
        if #available(iOS 14.0, *) {
            #expect(RichPush.mpeg4TypeIdentifier == UTType.mpeg4Movie.identifier)
        }
        #expect(RichPush.videoThumbnailTime == 1)
    }
}
