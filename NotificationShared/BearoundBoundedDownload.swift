//
//  BearoundBoundedDownload.swift
//  BearoundSDKNotificationExtensions
//
//  Shared by the Service and Content extensions (both subspecs compile it). Not part of the
//  core SDK.
//

import Foundation

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
