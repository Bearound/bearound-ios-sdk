//
//  BearoundRichPush.swift
//  BearoundSDK
//
//  Pure parsing of the rich push contract (`bearound_rich`, v1) and the URLs derived from it.
//  Foundation and ImageIO only, extension-safe: this file is compiled into the core SDK AND
//  into the separate `BearoundSDKNotificationExtensions` pod, which must not depend on the
//  core. Everything here stays internal except `BearoundPushCategory`, so each module gets
//  its own copy without clashing.
//

import Foundation
import ImageIO

/// Notification category ids of the rich push formats (`aps.category`).
public enum BearoundPushCategory {
    public static let image = "BEAROUND_IMAGE"
    public static let twoImages = "BEAROUND_TWO_IMAGES"
    public static let carousel = "BEAROUND_CAROUSEL"
    /// A real video: the Service Extension attaches the MP4 and the system player shows it
    /// on expand. The Content Extension must NOT claim it, or it would hide that player.
    public static let play = "BEAROUND_PLAY"

    /// The categories the host's Notification Content Extension declares in its Info.plist
    /// (`UNNotificationExtensionCategory`). `play` is deliberately absent.
    public static let contentExtension: [String] = [image, twoImages, carousel]
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
    /// Optional tap target: http(s) URL or a deep link. Nil opens the app. On a `PLAY` card
    /// it is the direct video URL instead, never a tap target.
    let url: String?
    /// Media type of a `PLAY` card's video (`vt`), e.g. `video/mp4`.
    let videoType: String?

    init(mediaId: String, caption: String?, url: String?, videoType: String? = nil) {
        self.mediaId = mediaId
        self.caption = caption
        self.url = url
        self.videoType = videoType
    }
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
              let mediaBase = rich["mb"] as? String, RichPush.isHTTPS(mediaBase),
              let rawCards = rich["c"] as? [Any]
        else { return nil }

        var cards: [RichPushCard] = []
        for raw in rawCards {
            guard let card = raw as? [String: Any],
                  let mediaId = card["m"] as? String, RichPush.isValidMediaId(mediaId)
            else { return nil }
            let caption = (card["t"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let url = (card["u"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let videoType = (card["vt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            cards.append(RichPushCard(mediaId: mediaId, caption: caption, url: url, videoType: videoType))
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

    /// URL to fetch card `index`'s image: through the tracker when the marker carries `d`
    /// and `tr`, the raw media URL otherwise.
    func imageURL(at index: Int) -> URL? {
        guard let raw = rawImageURL(at: index) else { return nil }
        guard let tracking else { return URL(string: raw) }
        return RichPush.trackerURL(tracking, verb: "view", target: raw, index: index)
    }

    /// Direct video URL of a `PLAY` payload (card 0 `u`, https only: ATS blocks plain http
    /// inside the extension). Nil for the other formats, or when `u` is missing or not https:
    /// the poster is attached instead.
    var videoURL: URL? {
        guard format == .play, let raw = cards.first?.url, RichPush.isHTTPS(raw) else { return nil }
        return URL(string: raw)
    }

    /// URL to open when card `index` is tapped. Nil means the default action (open the app):
    /// the card has no `u`, or `u` is neither http(s) nor a scheme the host app declares in
    /// its `CFBundleURLTypes` (`hostSchemes`, lowercased). An http(s) `u` goes through the
    /// tracker click when tracking is available; a declared deep link opens directly. Always
    /// nil for `PLAY`: its `u` is the video, and a tap opens the app.
    func tapURL(at index: Int, hostSchemes: Set<String> = []) -> URL? {
        guard format != .play, cards.indices.contains(index), let target = cards[index].url,
              let url = URL(string: target), RichPush.isAllowedTapTarget(url, hostSchemes: hostSchemes)
        else { return nil }
        if RichPush.isHTTP(target), let tracking {
            return RichPush.trackerURL(tracking, verb: "click", target: target, index: index)
        }
        return url
    }
}

/// URLs the Service Extension downloads for one notification.
struct RichPushAttachmentPlan: Equatable {
    /// Card 0 image, the PLAY poster, or the legacy `image_url`.
    let image: URL?
    /// The PLAY video, attached in preference to `image` when it downloads within the cap.
    let video: URL?
}

/// Helpers shared by the Service and Content extensions.
enum RichPush {
    /// Identifier of the attachment the Service Extension adds (card 0, the PLAY video, or
    /// the PLAY poster when the video could not be attached).
    static let attachmentIdentifier = "bearound-card-0"

    /// Largest PLAY video the Service Extension attaches. The contract caps uploads at
    /// 15 MB; a bigger download is cancelled as soon as it announces or passes the cap.
    static let maxVideoBytes: Int64 = 15 * 1024 * 1024
    /// Largest image attached (the system limit for image attachments is 10 MB).
    static let maxImageBytes: Int64 = 10 * 1024 * 1024
    /// Largest card image the Content Extension fetches (cards 1+ of a carousel or pair).
    static let maxCardImageBytes: Int64 = 5 * 1024 * 1024
    /// Longest side, in pixels, of an image the extensions decode or re-encode. Keeps a
    /// WebP/HEIC far larger than the screen from being decoded at full size in an extension.
    static let maxImagePixelSize = 2048
    /// Prefixes of the temp items the Service Extension creates.
    static let tempPrefixes = ["bearound-rich-", "bearound-download-"]
    /// The system gives a Service Extension about 30 s. The video gets this much, and the
    /// poster (downloaded in parallel) is always ready as the fallback.
    static let videoDownloadTimeout: TimeInterval = 22
    static let imageDownloadTimeout: TimeInterval = 20
    /// Uniform type of an MP4 attachment (`UTType.mpeg4Movie`), the attachment's type hint.
    static let mpeg4TypeIdentifier = "public.mpeg-4"
    /// Frame of the video the system uses as the collapsed thumbnail.
    static let videoThumbnailTime: Double = 1

    /// The image the Service Extension should attach: card 0 (the poster, for PLAY) of a
    /// valid rich payload, else the legacy top-level `image_url` (already tracker-wrapped).
    static func attachmentURL(from userInfo: [AnyHashable: Any]) -> URL? {
        attachmentPlan(from: userInfo)?.image
    }

    /// What the Service Extension downloads. `image` is always fetched when present, for PLAY
    /// too (the poster).
    /// `video` is set only for a PLAY payload with an http(s) `u`.
    static func attachmentPlan(from userInfo: [AnyHashable: Any]) -> RichPushAttachmentPlan? {
        if let payload = RichPushPayload.parse(userInfo) {
            let plan = RichPushAttachmentPlan(image: payload.imageURL(at: 0), video: payload.videoURL)
            return plan.image == nil && plan.video == nil ? nil : plan
        }
        guard let legacy = userInfo["image_url"] as? String, isHTTPS(legacy), let url = URL(string: legacy)
        else { return nil }
        return RichPushAttachmentPlan(image: url, video: nil)
    }

    /// The attachment to show: the video when it made it, else the poster/image, else none.
    static func preferredAttachment<T>(video: T?, image: T?) -> T? {
        video ?? image
    }

    /// True when a download must be abandoned: the server announced more than `cap` bytes
    /// (`expected` is negative when unknown), or more than `cap` already arrived.
    static func exceedsCap(expected: Int64, received: Int64, cap: Int64) -> Bool {
        (expected > 0 && expected > cap) || received > cap
    }

    /// True when a downloaded file is an MP4 the attachment API can play: the `ftyp` box at
    /// offset 4, always. The Content-Type alone is not trusted (`mimeType` is informational),
    /// so an HTML error page served as `video/mp4` with a 200 is rejected.
    static func isMP4(mimeType: String?, data: Data?) -> Bool {
        guard let data, data.count >= 8 else { return false }
        return [UInt8](data.subdata(in: 4..<8)) == [0x66, 0x74, 0x79, 0x70]
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

    /// Media (images, video) must be https: App Transport Security blocks plain http in the
    /// extensions, so an http media URL could never load.
    static func isHTTPS(_ value: String) -> Bool {
        value.lowercased().hasPrefix("https://")
    }

    /// Whether a card tap may open `url`: http(s), or a scheme the host app declares.
    /// Anything else (`javascript:`, `tel:`, another app's scheme) is the default action.
    static func isAllowedTapTarget(_ url: URL, hostSchemes: Set<String>) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        if scheme == "https" || scheme == "http" { return url.host?.isEmpty == false }
        return hostSchemes.contains(scheme)
    }

    /// The URL schemes an app declares in its Info.plist (`CFBundleURLTypes[].CFBundleURLSchemes`),
    /// lowercased.
    static func declaredURLSchemes(infoDictionary: [String: Any]?) -> Set<String> {
        guard let types = infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        var schemes = Set<String>()
        for type in types {
            for scheme in (type["CFBundleURLSchemes"] as? [String]) ?? [] where !scheme.isEmpty {
                schemes.insert(scheme.lowercased())
            }
        }
        return schemes
    }

    /// Decodes the image in `file` at most `maxPixelSize` on its longest side, never at full
    /// resolution (ImageIO thumbnail from the file; orientation applied). Nil when the file
    /// is not an image ImageIO can read.
    static func downsampledImage(at file: URL, maxPixelSize: Int = maxImagePixelSize) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// Writes `image` to `file` as JPEG. False when encoding fails.
    static func writeJPEG(_ image: CGImage, to file: URL, quality: Double = 0.9) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Removes the Service Extension's temp items (`tempPrefixes`) in `directory` last
    /// modified more than `age` seconds before `now`. A delivered attachment's file can only
    /// be dropped once the system took it, which happens after the extension hands the
    /// content over; the next run sweeps what is left.
    static func removeStaleTempItems(in directory: URL, olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }
        for item in items where tempPrefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age {
                try? fm.removeItem(at: item)
            }
        }
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
