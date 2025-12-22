//
//  Constants.swift
//  poc
//
//  Created by Arthur Sousa on 16/07/25.
//

import Foundation

// MARK: - BeAroundSDK Configuration

/// Configurações globais do BeAroundSDK
public struct BeAroundSDKConfig {
    
    /// Versão atual do SDK
    /// **IMPORTANTE**: Este é o único local onde a versão deve ser definida
    public static let version: String = "1.3.1"
    
    /// Nome do SDK usado em logs
    public static let name: String = "BeAroundSDK"
    
    /// Tag usada em todos os logs do SDK
    public static let logTag: String = "[\(name)]"
}

// MARK: - Internal Constants

/// Constantes internas do SDK (não expostas publicamente)
internal struct Constants {
    
    struct Logs {
        static let tag = BeAroundSDKConfig.logTag
    }
    
    struct API {
        static let beaconsSend = "Beacons saved in API"
        static let beaconExit = "Beacons exit and sent to API"
        static let saveLostBeacon = "Lost beacons saved in API"
    }
}
