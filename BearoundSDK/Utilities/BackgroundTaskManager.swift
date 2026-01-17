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
    
    /// Task identifier for beacon sync - must be registered in Info.plist
    public static let syncTaskIdentifier = "io.bearound.sdk.sync"
    
    private var isRegistered = false
    
    private init() {}
    
    /// Registers the background task with the system
    /// Must be called in application(_:didFinishLaunchingWithOptions:) BEFORE the app finishes launching
    public func registerTasks() {
        guard !isRegistered else {
            NSLog("[BeAroundSDK] Background tasks already registered")
            return
        }
        
        let success = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.syncTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleSyncTask(task as! BGAppRefreshTask)
        }
        
        if success {
            isRegistered = true
            NSLog("[BeAroundSDK] Background task registered: %@", Self.syncTaskIdentifier)
        } else {
            NSLog("[BeAroundSDK] Failed to register background task: %@", Self.syncTaskIdentifier)
        }
    }
    
    /// Schedules the next sync task
    /// The system will execute this when conditions are favorable (device plugged in, on Wi-Fi, etc.)
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
    
    /// Cancels any pending sync tasks
    public func cancelPendingTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.syncTaskIdentifier)
        NSLog("[BeAroundSDK] Cancelled pending background sync tasks")
    }
    
    /// Handles the sync task when executed by the system
    private func handleSyncTask(_ task: BGAppRefreshTask) {
        NSLog("[BeAroundSDK] Background sync task started")
        
        // Schedule the next sync before processing
        scheduleSync()
        
        // Set expiration handler
        task.expirationHandler = {
            NSLog("[BeAroundSDK] Background sync task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Perform the sync
        BeAroundSDK.shared.performBackgroundSync { success in
            NSLog("[BeAroundSDK] Background sync task completed (success=%d)", success ? 1 : 0)
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
    
    public func cancelPendingTasks() {
        // Not supported
    }
}
