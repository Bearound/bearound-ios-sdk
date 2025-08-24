//
//  Bearound+Public.swift
//  BeAround
//
//  Created by Arthur Sousa on 20/08/25.
//

import Foundation

extension Bearound {
    public func startServices() {
        self.scanner.startScanning()
        self.tracker.startTracking()
        self.debugger.defaultPrint("SDK initialization successful on version: \(DesignSystemVersion.current)")
    }
    
    public func stopServices() {
        self.scanner.stopScanning()
        self.tracker.stopTracking()
        self.stopTimer()
    }
    
    public func enableDebug() {
        self.debugger.isDebuggerEnabled = true
    }
    
    public func disableDebug() {
        self.debugger.isDebuggerEnabled = false
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    public func setUpdatingTime(_ seconds: TimeIntervals) {
        self.stopTimer()
        self.timer = Timer.scheduledTimer(
            timeInterval: seconds.rawValue,
            target: self,
            selector: #selector(syncWithAPI),
            userInfo: nil,
            repeats: true
        )
    }
    
    public func setMaximumLostBeaconsStorage(_ count: LostBeaconsStorage) {
        self.maximumLostBeaconsStorage = count.rawValue
    }
}
