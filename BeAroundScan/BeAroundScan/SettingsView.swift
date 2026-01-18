//
//  SettingsView.swift
//  BeAroundScan
//
//  Created by Bearound on 12/01/26.
//

import SwiftUI
import BearoundSDK

struct SettingsView: View {
    @ObservedObject var viewModel: BeaconViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                // SDK Info Section
                Section {
                    HStack {
                        Text("SDK Version")
                        Spacer()
                        Text("2.2.0")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Informações")
                }
                
                // Scan Intervals Section
                Section {
                    Picker("Foreground", selection: $viewModel.foregroundInterval) {
                        ForEach(ForegroundIntervalOption.allCases, id: \.self) { option in
                            Text(option.displayText).tag(option)
                        }
                    }
                    
                    Picker("Background", selection: $viewModel.backgroundInterval) {
                        ForEach(BackgroundIntervalOption.allCases, id: \.self) { option in
                            Text(option.displayText).tag(option)
                        }
                    }
                } header: {
                    Text("Intervalos de Sync")
                } footer: {
                    Text("Controla a frequência de envio de dados para a API.\n\nForeground: quando o app está ativo\nBackground: quando em segundo plano (ranging é contínuo, interval controla sync)")
                }
                
                // Queue Settings Section
                Section {
                    Picker("Tamanho da Fila", selection: $viewModel.queueSize) {
                        ForEach(QueueSizeOption.allCases, id: \.self) { option in
                            Text(option.displayText).tag(option)
                        }
                    }
                } header: {
                    Text("Fila de Retry")
                } footer: {
                    Text("Número máximo de batches de requisições guardados quando a API falha. Cada batch contém múltiplos beacons.")
                }
                
                // Features Section
                Section {
                    Text("Bluetooth Scanning: Sempre ativo")
                        .foregroundColor(.secondary)

                    Text("Periodic Scanning: Sempre ativo (economiza bateria)")
                        .foregroundColor(.secondary)
                } header: {
                    Text("Funcionalidades")
                } footer: {
                    Text("O SDK agora sempre ativa Bluetooth scanning e periodic scanning para otimização de bateria.\n\nEm background o ranging é sempre contínuo (limitação do iOS)")
                }
                
                // Current Configuration Display
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Sync Interval Atual:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(viewModel.currentDisplayInterval)s")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        HStack {
                            Text("Scan Duration:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(viewModel.scanDuration)s")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                } header: {
                    Text("Configuração Atual")
                } footer: {
                    Text("Valores calculados baseados nas configurações selecionadas")
                }
                
                // Apply Button
                Section {
                    Button(action: {
                        viewModel.applySettings()
                        dismiss()
                    }) {
                        HStack {
                            Spacer()
                            Text("Aplicar Configurações")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fechar") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Helper Enums for UI

enum ForegroundIntervalOption: CaseIterable {
    case seconds5, seconds10, seconds15, seconds20, seconds25, seconds30
    case seconds35, seconds40, seconds45, seconds50, seconds55, seconds60
    
    var displayText: String {
        "\(seconds)s"
    }
    
    var seconds: Int {
        switch self {
        case .seconds5: return 5
        case .seconds10: return 10
        case .seconds15: return 15
        case .seconds20: return 20
        case .seconds25: return 25
        case .seconds30: return 30
        case .seconds35: return 35
        case .seconds40: return 40
        case .seconds45: return 45
        case .seconds50: return 50
        case .seconds55: return 55
        case .seconds60: return 60
        }
    }
    
    var sdkValue: ForegroundScanInterval {
        ForegroundScanInterval(seconds: TimeInterval(seconds))
    }

    static func from(sdkValue: ForegroundScanInterval) -> ForegroundIntervalOption {
        let seconds = Int(sdkValue.timeInterval)
        switch seconds {
        case 5: return .seconds5
        case 10: return .seconds10
        case 15: return .seconds15
        case 20: return .seconds20
        case 25: return .seconds25
        case 30: return .seconds30
        case 35: return .seconds35
        case 40: return .seconds40
        case 45: return .seconds45
        case 50: return .seconds50
        case 55: return .seconds55
        case 60: return .seconds60
        default: return .seconds15
        }
    }
}

enum BackgroundIntervalOption: CaseIterable {
    case seconds15, seconds30, seconds60, seconds90, seconds120
    
    var displayText: String {
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            return "\(seconds)s (\(minutes)min)"
        }
    }
    
    var seconds: Int {
        switch self {
        case .seconds15: return 15
        case .seconds30: return 30
        case .seconds60: return 60
        case .seconds90: return 90
        case .seconds120: return 120
        }
    }
    
    var minutes: Int {
        seconds / 60
    }
    
    var sdkValue: BackgroundScanInterval {
        BackgroundScanInterval(seconds: TimeInterval(seconds))
    }

    static func from(sdkValue: BackgroundScanInterval) -> BackgroundIntervalOption {
        let seconds = Int(sdkValue.timeInterval)
        switch seconds {
        case 15: return .seconds15
        case 30: return .seconds30
        case 60: return .seconds60
        case 90: return .seconds90
        case 120: return .seconds120
        default: return .seconds30
        }
    }
}

enum QueueSizeOption: CaseIterable {
    case small, medium, large, xlarge
    
    var displayText: String {
        switch self {
        case .small: return "Small (50 batches)"
        case .medium: return "Medium (100 batches)"
        case .large: return "Large (200 batches)"
        case .xlarge: return "XLarge (500 batches)"
        }
    }
    
    var sdkValue: MaxQueuedPayloads {
        switch self {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xlarge: return .xlarge
        }
    }
    
    static func from(sdkValue: MaxQueuedPayloads) -> QueueSizeOption {
        switch sdkValue {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xlarge: return .xlarge
        }
    }
}
