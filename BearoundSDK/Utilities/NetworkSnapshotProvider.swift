//
//  NetworkSnapshotProvider.swift
//  BearoundSDK
//
//  Created by Bearound on 31/07/26.
//

import Foundation
import Network

/// Long-lived `NWPathMonitor` that keeps a lock-protected snapshot of the
/// current network type.
///
/// Replaces the previous per-read pattern in `DeviceInfoCollector`: a brand-new
/// monitor + `DispatchSemaphore.wait(0.5s)` on EVERY read — and device-info
/// collection reads it up to 3 times, so a single payload could block its queue
/// for up to 1.5s. With this provider the 0.5s worst-case wait is paid at most
/// once per process (first read before the monitor's initial callback); every
/// subsequent read is a lock-protected string copy.
///
/// The reported values are exactly the ones the old implementation produced —
/// "wifi" | "cellular" | "none" (wired Ethernet intentionally reports "wifi",
/// preserving the wire contract with the ingest API).
final class NetworkSnapshotProvider {

    static let shared = NetworkSnapshotProvider()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.bearound.sdk.networkMonitor", qos: .utility)

    private let lock = NSLock()
    private var snapshot = "none"
    private var receivedFirstUpdate = false

    private let firstUpdate = DispatchSemaphore(value: 0)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let value: String
            if path.status == .satisfied {
                value = path.usesInterfaceType(.cellular) ? "cellular" : "wifi"
            } else {
                value = "none"
            }

            self.lock.lock()
            self.snapshot = value
            let isFirst = !self.receivedFirstUpdate
            self.receivedFirstUpdate = true
            self.lock.unlock()

            if isFirst {
                self.firstUpdate.signal()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Current network type ("wifi" | "cellular" | "none").
    /// Non-blocking once the monitor has delivered its first path update; before
    /// that, waits up to 0.5s for it (same worst case as the old per-read code,
    /// but paid once per process instead of on every read).
    var current: String {
        lock.lock()
        let ready = receivedFirstUpdate
        let value = snapshot
        lock.unlock()

        if ready { return value }

        if firstUpdate.wait(timeout: .now() + 0.5) == .success {
            // Cascade the credit so concurrent first readers don't each burn
            // the full timeout waiting on a semaphore that only signals once.
            firstUpdate.signal()
        }

        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}
