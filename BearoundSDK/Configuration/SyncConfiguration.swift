//
//  SyncConfiguration.swift
//  BearoundSDK
//
//  Created by Felipe Costa Araujo on 22/12/25.
//

import Foundation

// MARK: - Sync Interval

/// Intervalos de sincronização predefinidos para envio de beacons à API
public enum SyncInterval: TimeInterval, CaseIterable {
    case time5 = 5.0
    case time10 = 10.0
    case time15 = 15.0
    case time20 = 20.0
    case time25 = 25.0
    case time30 = 30.0
    case time35 = 35.0
    case time40 = 40.0
    case time45 = 45.0
    case time50 = 50.0
    case time55 = 55.0
    case time60 = 60.0
    
    /// Valor em segundos do intervalo
    public var seconds: TimeInterval {
        return self.rawValue
    }
    
    /// Descrição amigável do intervalo
    public var description: String {
        return "\(Int(rawValue))s"
    }
}

// MARK: - Backup Size

/// Tamanho máximo do backup de beacons perdidos
public enum BackupSize: Int, CaseIterable {
    case size5 = 5
    case size10 = 10
    case size15 = 15
    case size20 = 20
    case size25 = 25
    case size30 = 30
    case size35 = 35
    case size40 = 40
    case size45 = 45
    case size50 = 50
    
    /// Quantidade máxima de beacons no backup
    public var count: Int {
        return self.rawValue
    }
    
    /// Descrição amigável do tamanho
    public var description: String {
        return "\(rawValue) beacons"
    }
}
