//
//  BackgroundTaskManagerTests.swift
//  BearoundSDKTests
//
//  Tests for background task management
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("BackgroundTaskManager Tests")
struct BackgroundTaskManagerTests {
    
    @Test("Shared instance exists")
    @available(iOS 13.0, *)
    func sharedInstanceExists() {
        let manager = BackgroundTaskManager.shared
        
        #expect(manager != nil)
    }
    
    @Test("Can schedule sync task")
    @available(iOS 13.0, *)
    func canScheduleSyncTask() {
        let manager = BackgroundTaskManager.shared
        
        // Should not crash when scheduling
        manager.scheduleSync()
    }
    
    @Test("Can cancel pending tasks")
    @available(iOS 13.0, *)
    func canCancelPendingTasks() {
        let manager = BackgroundTaskManager.shared
        
        // Schedule a task
        manager.scheduleSync()
        
        // Should not crash when cancelling
        manager.cancelPendingTasks()
    }
    
    @Test("Can register tasks multiple times")
    @available(iOS 13.0, *)
    func canRegisterTasksMultipleTimes() {
        let manager = BackgroundTaskManager.shared
        
        // Should not crash when calling multiple times
        manager.registerTasks()
        manager.registerTasks()
        manager.registerTasks()
    }
}
