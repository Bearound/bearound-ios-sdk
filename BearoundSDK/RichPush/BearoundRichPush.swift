//
//  BearoundRichPush.swift
//  BearoundSDK
//
//  Pure parsing of the rich push contract (`bearound_rich`, v1) and the URLs derived from it.
//  Foundation only and extension-safe: this file is compiled into the core SDK AND into the
//  `NotificationService` / `NotificationContent` subspecs, which must not depend on the core.
//

import Foundation

/// Notification category ids of the rich push formats. The host's Notification Content
/// Extension declares these in its Info.plist (`UNNotificationExtensionCategory`).
public enum BearoundPushCategory {
    public static let image = "BEAROUND_IMAGE"
    public static let twoImages = "BEAROUND_TWO_IMAGES"
    public static let carousel = "BEAROUND_CAROUSEL"
    public static let play = "BEAROUND_PLAY"

    public static let all: [String] = [image, twoImages, carousel, play]
}

/// Rich push display format (`bearound_rich.f`).
enum RichPushFormat: String {
    case image = "IMAGE"
    case twoImages = "TWO_IMAGES"
    case carousel = "CAROUSEL"
    case play = "PLAY"

    var categoryIdentifier: String {
        switch self {
        case .image: return BearoundPushCategory.image
        case .twoImages: return BearoundPushCategory.twoImages
        case .carousel: return BearoundPushCategory.carousel
        case .play: return BearoundPushCategory.play
        }
    }

    /// Card counts the contract allows for this format.
    var allowedCardCount: ClosedRange<Int> {
        switch self {
        case .image, .play: return 1...1
        case .twoImages: return 2...2
        case .carousel: return 2...5
        }
    }
}

/// One card of a rich push (`bearound_rich.c[i]`).
struct RichPushCard: Equatable {
    /// Media id (content-addressed); the image is `mb + m`.
    let mediaId: String
    /// Optional caption.
    let caption: String?
    /// Optional tap target: http(s) URL or a deep link. Nil opens the app.
    let url: String?
}

/// Delivery context from the `bearound` marker, used to route per-card fetches and taps
/// through the tracker. Present only when the marker has both `d` and an https `tr`.
struct RichPushTracking: Equatable {
    let d: String
    let tr: String

    static func extract(from userInfo: [AnyHashable: Any]) -> RichPushTracking? {
        guard let marker = RichPush.dictionary(userInfo["bearound"]),
              let d = marker["d"] as? String, !d.isEmpty,
              let tr = marker["tr"] as? String, tr.lowercased().hasPrefix("https://")
        else { return nil }
        return RichPushTracking(d: d, tr: tr.hasSuffix("/") ? String(tr.dropLast()) : tr)
    }
}

/// A parsed, contract-valid `bearound_rich` payload.
struct RichPushPayload: Equatable {
    static let supportedVersion = 1

    let format: RichPushFormat
    let mediaBase: String
    let cards: [RichPushCard]
    let tracking: RichPushTracking?

    /// Parses `bearound_rich` from a notification `userInfo`. Accepts the APNs object shape
    /// and the JSON-string shape. Returns nil for anything outside the v1 contract (unknown
    /// version or format, wrong card count, missing media), which means: legacy path.
    static func parse(_ userInfo: [AnyHashable: Any]) -> RichPushPayload? {
        guard let rich = RichPush.dictionary(userInfo["bearound_rich"]),
              let version = rich["v"] as? Int, version == supportedVersion,
              let rawFormat = rich["f"] as? String, let format = RichPushFormat(rawValue: rawFormat),
              let mediaBase = rich["mb"] as? String, RichPush.isHTTP(mediaBase),
              let rawCards = rich["c"] as? [Any]
        else { return nil }

        var cards: [RichPushCard] = []
        for raw in rawCards {
            guard let card = raw as? [String: Any],
                  let mediaId = card["m"] as? String, RichPush.isValidMediaId(mediaId)
            else { return nil }
            let caption = (card["t"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let url = (card["u"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            cards.append(RichPushCard(mediaId: mediaId, caption: caption, url: url))
        }
        guard format.allowedCardCount.contains(cards.count) else { return nil }

        return RichPushPayload(
            format: format,
            mediaBase: mediaBase,
            cards: cards,
            tracking: RichPushTracking.extract(from: userInfo)
        )
    }

    /// Raw media URL of card `index`: `mb + m`.
    func rawImageURL(at index: Int) -> String? {
        guard cards.indices.contains(index) else { return nil }
        return mediaBase + cards[index].mediaId
    }

    /// URL to fetch card `index`'s image. Through the tracker (the fetch IS the view) when
    /// the marker carries `d` and `tr`; the raw media URL otherwise.
    func imageURL(at index: Int) -> URL? {
        guard let raw = rawImageURL(at: index) else { return nil }
        guard let tracking else { return URL(string: raw) }
        return RichPush.trackerURL(tracking, verb: "view", target: raw, index: index)
    }

    /// URL to open when card `index` is tapped. Nil when the card has no `u` (the tap opens
    /// the app). An http(s) `u` goes through the tracker click when tracking is available; a
    /// deep link always opens directly.
    func tapURL(at index: Int) -> URL? {
        guard cards.indices.contains(index), let target = cards[index].url else { return nil }
        if RichPush.isHTTP(target), let tracking {
            return RichPush.trackerURL(tracking, verb: "click", target: target, index: index)
        }
        return URL(string: target)
    }
}

/// Helpers shared by the Service and Content extensions.
enum RichPush {
    /// Identifier of the attachment the Service Extension adds (card 0 or the PLAY cover).
    static let attachmentIdentifier = "bearound-card-0"

    /// The image the Service Extension should attach: card 0 of a valid rich payload, else
    /// the legacy top-level `image_url` (already tracker-wrapped by the server).
    static func attachmentURL(from userInfo: [AnyHashable: Any]) -> URL? {
        if let payload = RichPushPayload.parse(userInfo) {
            return payload.imageURL(at: 0)
        }
        guard let legacy = userInfo["image_url"] as? String, isHTTP(legacy) else { return nil }
        return URL(string: legacy)
    }

    /// `GET {tr}/v1/push:open?d={d}`, the open hit, for taps the host app never sees
    /// (a card tap that opens a URL from the Content Extension).
    static func openURL(_ tracking: RichPushTracking) -> URL? {
        URL(string: "\(tracking.tr)/v1/push:open?d=\(encode(tracking.d))")
    }

    /// File extension for a downloaded attachment, from the Content-Type, falling back to the
    /// file signature. Nil means the bytes are not a type `UNNotificationAttachment` accepts
    /// as-is (e.g. WebP), and must be re-encoded first.
    static func attachmentFileExtension(mimeType: String?, data: Data?) -> String? {
        if let mime = mimeType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() {
            switch mime {
            case "image/jpeg", "image/jpg", "image/pjpeg": return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            default: break
            }
        }
        guard let data, data.count >= 4 else { return nil }
        let head = [UInt8](data.prefix(4))
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        if head == [0x89, 0x50, 0x4E, 0x47] { return "png" }
        if head[0] == 0x47, head[1] == 0x49, head[2] == 0x46 { return "gif" }
        return nil
    }

    static func trackerURL(_ tracking: RichPushTracking, verb: String, target: String, index: Int) -> URL? {
        URL(string: "\(tracking.tr)/v1/push:\(verb)?d=\(encode(tracking.d))&r=\(encode(target))&idx=\(index)")
    }

    /// Strict query-value encoding: only RFC 3986 unreserved characters stay literal.
    static func encode(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func isHTTP(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    static func isValidMediaId(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                || $0 == "-" || $0 == "_"
        }
    }

    /// Accepts an object or a JSON string (FCM `data`, bridges) and returns a dictionary.
    static func dictionary(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        if let dict = raw as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict { if let key = key as? String { out[key] = value } }
            return out
        }
        guard let string = raw as? String, let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
