//
//  BackgroundTaskManager.swift
//  BearoundSDK
//
//  Manages BGTaskScheduler for background sync operations
//  Created by Bearound on 17/01/26.
//

import BackgroundTasks
import Foundation

/// Manages background task scheduling for beacon sync operations
/// Uses BGTaskScheduler (iOS 13+) for reliable background execution
@available(iOS 13.0, *)
public class BackgroundTaskManager {

    public static let shared = BackgroundTaskManager()

    /// Task identifier for beacon sync (app refresh) - must be registered in Info.plist
    public static let syncTaskIdentifier = "io.bearound.sdk.sync"

    /// Task identifier for processing task (longer execution) - must be registered in Info.plist
    public static let processingTaskIdentifier = "io.bearound.sdk.processing"

    private var isRegistered = false

    private init() {}

    /// Registers the background tasks with the system
    /// Must be called in application(_:didFinishLaunchingWithOptions:) BEFORE the app finishes launching
    public func registerTasks() {
        guard !isRegistered else {
            NSLog("[BeAroundSDK] Background tasks already registered")
            return
        }

        // Register app refresh task (short background execution)
        let refreshSuccess = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.syncTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleSyncTask(task as! BGAppRefreshTask)
        }

        // Register processing task (longer background execution, iOS 13+)
        let processingSuccess = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleProcessingTask(task as! BGProcessingTask)
        }

        isRegistered = refreshSuccess || processingSuccess

        if refreshSuccess {
            NSLog("[BeAroundSDK] Background refresh task registered: %@", Self.syncTaskIdentifier)
        } else {
            NSLog("[BeAroundSDK] Failed to register background refresh task: %@", Self.syncTaskIdentifier)
        }

        if processingSuccess {
            NSLog("[BeAroundSDK] Background processing task registered: %@", Self.processingTaskIdentifier)
        } else {
            NSLog("[BeAroundSDK] Failed to register background processing task: %@", Self.processingTaskIdentifier)
        }
    }

    /// Schedules the next sync task (short execution)
    /// The system will execute this when conditions are favorable
    public func scheduleSync() {
        guard isRegistered else {
            NSLog("[BeAroundSDK] Cannot schedule sync - tasks not registered")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.syncTaskIdentifier)
        // Request execution in 15 minutes (system may delay based on conditions)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog("[BeAroundSDK] Background sync scheduled for ~15 minutes")
        } catch {
            NSLog("[BeAroundSDK] Failed to schedule background sync: %@", error.localizedDescription)
        }
    }

    /// Schedules a processing task for longer background execution
    /// Use this for more complex operations that need more time
    public func scheduleProcessingTask() {
        guard isRegistered else {
            NSLog("[BeAroundSDK] Cannot schedule processing - tasks not registered")
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // Request execution in 30 minutes
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog("[BeAroundSDK] Background processing task scheduled for ~30 minutes")
        } catch {
            NSLog("[BeAroundSDK] Failed to schedule background processing: %@", error.localizedDescription)
        }
    }

    /// Cancels any pending sync tasks
    public func cancelPendingTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.syncTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
        NSLog("[BeAroundSDK] Cancelled pending background tasks")
    }

    /// Handles the sync task when executed by the system (short execution ~30s)
    /// Refreshes BLE scan for 3s to collect Service Data, then syncs
    private func handleSyncTask(_ task: BGAppRefreshTask) {
        NSLog("[BeAroundSDK] BGAppRefreshTask started — refreshing BLE + sync")

        // Schedule the next sync before processing
        scheduleSync()

        // Set expiration handler
        task.expirationHandler = {
            NSLog("[BeAroundSDK] BGAppRefreshTask expired")
            task.setTaskCompleted(success: false)
        }

        // Refresh BLE scan (3s collection) then sync
        BeAroundSDK.shared.performBackgroundBLERefreshAndSync(bleScanDuration: 3.0) { success in
            NSLog("[BeAroundSDK] BGAppRefreshTask completed (success=%d)", success ? 1 : 0)
            task.setTaskCompleted(success: success)
        }
    }

    /// Handles the processing task when executed by the system (longer execution, minutes)
    /// Refreshes BLE scan for 5s to collect Service Data, then syncs
    private func handleProcessingTask(_ task: BGProcessingTask) {
        NSLog("[BeAroundSDK] BGProcessingTask started — refreshing BLE + sync")

        // Schedule the next processing task before starting
        scheduleProcessingTask()

        // Set expiration handler
        task.expirationHandler = {
            NSLog("[BeAroundSDK] BGProcessingTask expired")
            task.setTaskCompleted(success: false)
        }

        // Refresh BLE scan (5s collection — more time available) then sync
        BeAroundSDK.shared.performBackgroundBLERefreshAndSync(bleScanDuration: 5.0) { success in
            NSLog("[BeAroundSDK] BGProcessingTask completed (success=%d)", success ? 1 : 0)
            task.setTaskCompleted(success: success)
        }
    }
}

// MARK: - Fallback for iOS < 13
public class BackgroundTaskManagerLegacy {
    public static let shared = BackgroundTaskManagerLegacy()

    private init() {}

    /// No-op for iOS versions that don't support BGTaskScheduler
    public func registerTasks() {
        NSLog("[BeAroundSDK] BGTaskScheduler not available on this iOS version")
    }

    public func scheduleSync() {
        // Not supported
    }

    public func scheduleProcessingTask() {
        // Not supported
    }

    public func cancelPendingTasks() {
        // Not supported
    }
}
