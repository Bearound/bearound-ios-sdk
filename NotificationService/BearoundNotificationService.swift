//
//  BearoundNotificationService.swift
//  BearoundSDK/NotificationService
//
//  Notification Service Extension for Bearound rich push. Downloads card 0 (or the PLAY
//  cover) of a `bearound_rich` payload, or the legacy top-level `image_url`, and attaches it.
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
    private var downloadTask: URLSessionDownloadTask?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        lock.lock()
        self.contentHandler = contentHandler
        self.bestAttempt = content
        lock.unlock()

        guard let url = RichPush.attachmentURL(from: request.content.userInfo) else {
            deliver()
            return
        }

        let task = session.downloadTask(with: url) { [weak self] location, response, error in
            guard let self else { return }
            if error == nil, let location, let response,
               let attachment = Self.makeAttachment(from: location, response: response) {
                self.lock.lock()
                self.bestAttempt?.attachments = [attachment]
                self.lock.unlock()
            }
            self.deliver()
        }
        lock.lock()
        downloadTask = task
        lock.unlock()
        task.resume()
    }

    open override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let task = downloadTask
        lock.unlock()
        task?.cancel()
        deliver()
    }

    /// Hands the best attempt to the system exactly once.
    private func deliver() {
        lock.lock()
        let handler = contentHandler
        let content = bestAttempt
        contentHandler = nil
        lock.unlock()
        guard let handler, let content else { return }
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

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearound-rich-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(RichPush.attachmentIdentifier).\(fileExtension)")
            try bytes.write(to: file)
            return try UNNotificationAttachment(identifier: RichPush.attachmentIdentifier, url: file, options: nil)
        } catch {
            return nil
        }
    }
}
