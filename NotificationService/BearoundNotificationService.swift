//
//  BearoundNotificationService.swift
//  BearoundSDKNotificationExtensions/Service
//
//  Notification Service Extension for Bearound rich push. Downloads card 0 of a
//  `bearound_rich` payload, or the legacy top-level `image_url`, and attaches it. For PLAY it
//  also downloads the MP4 (`u`) and attaches the video, so expanding the notification plays
//  it with the system player; the poster is the fallback when the video fails or is too big.
//  Extension-safe: does not depend on the core SDK.
//
//  Host usage (the whole NotificationService.swift of the host's NSE target):
//
//      import BearoundSDKNotificationExtensions
//      class NotificationService: BearoundNotificationService {}
//

import Foundation
import ImageIO
import UserNotifications

open class BearoundNotificationService: UNNotificationServiceExtension {
    /// Temp items older than this are left over from earlier notifications and are removed.
    private static let staleTempAge: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var downloads: [BearoundBoundedDownload] = []
    private var imageAttachment: UNNotificationAttachment?
    private var videoAttachment: UNNotificationAttachment?

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        RichPush.removeStaleTempItems(in: FileManager.default.temporaryDirectory, olderThan: Self.staleTempAge)
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        // The category picks the content extension that draws the cards. A server that does
        // not set `aps.category` (an older sender, a bridge) still gets the rich layout.
        if content.categoryIdentifier.isEmpty, let payload = RichPushPayload.parse(request.content.userInfo) {
            content.categoryIdentifier = payload.format.categoryIdentifier
        }
        lock.lock()
        self.contentHandler = contentHandler
        self.bestAttempt = content
        lock.unlock()

        guard let plan = RichPush.attachmentPlan(from: request.content.userInfo) else {
            deliver()
            return
        }

        // The image (poster for PLAY) is always fetched. The video runs in parallel, so the
        // poster is ready if the video fails.
        let group = DispatchGroup()
        var started: [BearoundBoundedDownload] = []
        if let image = plan.image {
            group.enter()
            started.append(BearoundBoundedDownload(
                url: image, maxBytes: RichPush.maxImageBytes, timeout: RichPush.imageDownloadTimeout
            ) { [weak self] file, response in
                if let file, let response, let attachment = Self.makeAttachment(from: file, response: response) {
                    self?.lock.lock()
                    self?.imageAttachment = attachment
                    self?.lock.unlock()
                }
                // A usable image was moved next to the attachment; this only drops a rejected one.
                if let file { try? FileManager.default.removeItem(at: file) }
                group.leave()
            })
        }
        if let video = plan.video {
            group.enter()
            started.append(BearoundBoundedDownload(
                url: video, maxBytes: RichPush.maxVideoBytes, timeout: RichPush.videoDownloadTimeout
            ) { [weak self] file, response in
                if let file, let response, let attachment = Self.makeVideoAttachment(from: file, response: response) {
                    self?.lock.lock()
                    self?.videoAttachment = attachment
                    self?.lock.unlock()
                }
                // A valid video was moved into the attachment; this only drops a rejected one.
                if let file { try? FileManager.default.removeItem(at: file) }
                group.leave()
            })
        }
        lock.lock()
        downloads = started
        lock.unlock()
        group.notify(queue: .global()) { [weak self] in self?.deliver() }
        started.forEach { $0.start() }
    }

    open override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let pending = downloads
        lock.unlock()
        pending.forEach { $0.cancel() }
        deliver()
    }

    /// Hands the best attempt to the system exactly once, with the video when it made it,
    /// else the image or poster. The attachment that loses (the poster, when the video won)
    /// is deleted here; the delivered one belongs to the system from now on.
    private func deliver() {
        lock.lock()
        let handler = contentHandler
        let content = bestAttempt
        let attachment = RichPush.preferredAttachment(video: videoAttachment, image: imageAttachment)
        let unused = videoAttachment != nil ? imageAttachment : nil
        contentHandler = nil
        downloads = []
        lock.unlock()
        guard let handler, let content else { return }
        if let attachment { content.attachments = [attachment] }
        if let unused { Self.removeAttachmentDirectory(of: unused.url) }
        handler(content)
    }

    /// Moves the downloaded image to a path with the right extension and wraps it. WebP, HEIC
    /// and other types the attachment API rejects are downsampled from the file (at most
    /// `RichPush.maxImagePixelSize`, never decoded at full size) and re-encoded as JPEG.
    static func makeAttachment(from location: URL, response: URLResponse) -> UNNotificationAttachment? {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        let head = readHead(of: location, length: 12)
        guard let head, !head.isEmpty else { return nil }

        let ext = RichPush.attachmentFileExtension(mimeType: response.mimeType, data: head)
        guard let file = try? attachmentFile(extension: ext ?? "jpg") else { return nil }
        let ready: Bool
        if ext != nil {
            ready = (try? FileManager.default.moveItem(at: location, to: file)) != nil
        } else if let image = RichPush.downsampledImage(at: location) {
            ready = RichPush.writeJPEG(image, to: file)
        } else {
            ready = false
        }
        guard ready else {
            removeAttachmentDirectory(of: file)
            return nil
        }
        return wrap(file, options: nil)
    }

    /// Wraps a downloaded MP4 as a video attachment: `.mp4` file, MPEG-4 type hint and a
    /// thumbnail taken about 1 s in. Nil for an HTTP error, an empty or oversized file, or
    /// bytes that are not an MP4.
    static func makeVideoAttachment(from location: URL, response: URLResponse) -> UNNotificationAttachment? {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, !RichPush.exceedsCap(expected: -1, received: size, cap: RichPush.maxVideoBytes) else { return nil }
        guard RichPush.isMP4(mimeType: response.mimeType, data: readHead(of: location, length: 12)) else { return nil }

        guard let file = try? attachmentFile(extension: "mp4") else { return nil }
        guard (try? FileManager.default.moveItem(at: location, to: file)) != nil else {
            removeAttachmentDirectory(of: file)
            return nil
        }
        return wrap(file, options: [
            UNNotificationAttachmentOptionsTypeHintKey: RichPush.mpeg4TypeIdentifier,
            UNNotificationAttachmentOptionsThumbnailTimeKey: NSNumber(value: RichPush.videoThumbnailTime),
        ])
    }

    /// Creates the attachment, or removes the file (and its directory) when the system
    /// rejects it.
    private static func wrap(_ file: URL, options: [AnyHashable: Any]?) -> UNNotificationAttachment? {
        do {
            return try UNNotificationAttachment(identifier: RichPush.attachmentIdentifier, url: file, options: options)
        } catch {
            removeAttachmentDirectory(of: file)
            return nil
        }
    }

    private static func readHead(of file: URL, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { handle.closeFile() }
        return handle.readData(ofLength: length)
    }

    private static func attachmentFile(extension fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearound-rich-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(RichPush.attachmentIdentifier).\(fileExtension)")
    }

    /// Removes the `bearound-rich-<uuid>` directory holding `file` (never anything else).
    private static func removeAttachmentDirectory(of file: URL) {
        let directory = file.deletingLastPathComponent()
        if directory.lastPathComponent.hasPrefix("bearound-rich-") {
            try? FileManager.default.removeItem(at: directory)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
