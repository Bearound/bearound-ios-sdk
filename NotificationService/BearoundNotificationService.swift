//
//  BearoundNotificationService.swift
//  BearoundSDK/NotificationService
//
//  Notification Service Extension for Bearound rich push. Downloads card 0 of a
//  `bearound_rich` payload, or the legacy top-level `image_url`, and attaches it. For PLAY it
//  also downloads the MP4 (`u`) and attaches the video, so expanding the notification plays
//  it with the system player; the poster is the fallback when the video fails or is too big.
//  Extension-safe: does not depend on the core SDK.
//
//  Host usage (the whole NotificationService.swift of the host's NSE target):
//
//      import BearoundSDK
//      class NotificationService: BearoundNotificationService {}
//

import Foundation
import UIKit
import UserNotifications

open class BearoundNotificationService: UNNotificationServiceExtension {
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

        // The image (poster for PLAY) is always fetched: through the tracker that fetch IS
        // the view. The video runs in parallel, so the poster is ready if the video fails.
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
    /// else the image or poster.
    private func deliver() {
        lock.lock()
        let handler = contentHandler
        let content = bestAttempt
        let attachment = RichPush.preferredAttachment(video: videoAttachment, image: imageAttachment)
        contentHandler = nil
        downloads = []
        lock.unlock()
        guard let handler, let content else { return }
        if let attachment { content.attachments = [attachment] }
        handler(content)
    }

    /// Moves the downloaded file to a path with the right extension and wraps it. WebP and
    /// other types the attachment API rejects are re-encoded as JPEG.
    static func makeAttachment(from location: URL, response: URLResponse) -> UNNotificationAttachment? {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        guard let data = try? Data(contentsOf: location), !data.isEmpty else { return nil }

        let fileExtension: String
        let bytes: Data
        if let ext = RichPush.attachmentFileExtension(mimeType: response.mimeType, data: data) {
            fileExtension = ext
            bytes = data
        } else if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) {
            fileExtension = "jpg"
            bytes = jpeg
        } else {
            return nil
        }

        do {
            let file = try attachmentFile(extension: fileExtension)
            try bytes.write(to: file)
            return try UNNotificationAttachment(identifier: RichPush.attachmentIdentifier, url: file, options: nil)
        } catch {
            return nil
        }
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
        let head = (try? FileHandle(forReadingFrom: location)).map { handle -> Data in
            defer { handle.closeFile() }
            return handle.readData(ofLength: 12)
        }
        guard RichPush.isMP4(mimeType: response.mimeType, data: head) else { return nil }

        do {
            let file = try attachmentFile(extension: "mp4")
            try FileManager.default.moveItem(at: location, to: file)
            return try UNNotificationAttachment(
                identifier: RichPush.attachmentIdentifier,
                url: file,
                options: [
                    UNNotificationAttachmentOptionsTypeHintKey: RichPush.mpeg4TypeIdentifier,
                    UNNotificationAttachmentOptionsThumbnailTimeKey: NSNumber(value: RichPush.videoThumbnailTime),
                ]
            )
        } catch {
            return nil
        }
    }

    private static func attachmentFile(extension fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearound-rich-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(RichPush.attachmentIdentifier).\(fileExtension)")
    }
}

/// One download with a byte cap and a time limit. Cancelled as soon as the server announces,
/// or sends, more than `maxBytes`, so an oversized video does not eat the extension's time.
/// The completion runs once, with a temp file the caller owns (nil on any failure).
final class BearoundBoundedDownload: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let maxBytes: Int64
    private let completion: (URL?, URLResponse?) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var file: URL?
    private var finished = false

    init(url: URL, maxBytes: Int64, timeout: TimeInterval, completion: @escaping (URL?, URLResponse?) -> Void) {
        self.url = url
        self.maxBytes = maxBytes
        self.completion = completion
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = min(15, timeout)
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() {
        session?.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if RichPush.exceedsCap(expected: totalBytesExpectedToWrite, received: totalBytesWritten, cap: maxBytes) {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns: move it somewhere the caller owns.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearound-download-\(UUID().uuidString)")
        if (try? FileManager.default.moveItem(at: location, to: target)) != nil {
            lock.lock()
            file = target
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        let downloaded = file
        lock.unlock()
        session.finishTasksAndInvalidate()
        guard !alreadyFinished else { return }
        if error == nil, let downloaded {
            completion(downloaded, task.response)
        } else {
            if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            completion(nil, nil)
        }
    }
}
