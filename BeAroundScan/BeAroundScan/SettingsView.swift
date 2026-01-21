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
                Section {
                    HStack {
                        Text("Versão do SDK")
                        Spacer()
                        Text(viewModel.sdkVersion)
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Section("Intervalos de Sync") {
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
                }

                Section("Fila de Retry") {
                    Picker("Tamanho da Fila", selection: $viewModel.queueSize) {
                        ForEach(QueueSizeOption.allCases, id: \.self) { option in
                            Text(option.displayText).tag(option)
                        }
                    }
                }

                Section("Propriedades do Usuário") {
                    TextField("ID do usuário", text: $viewModel.userPropertyInternalId)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    TextField("E-Mail do usuário", text: $viewModel.userPropertyEmail)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.emailAddress)

                    TextField("Nome do usuário", text: $viewModel.userPropertyName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(false)

                    TextField("Propriedade customizada", text: $viewModel.userPropertyCustom)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section {
                    Button(action: {
                        viewModel.applySettings()
                        dismiss()
                    }) {
                        Text("Aplicar Configurações")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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

enum ForegroundIntervalOption: String, CaseIterable {
    case seconds5 = "5", seconds10 = "10", seconds15 = "15", seconds20 = "20", seconds25 = "25", seconds30 = "30"
    case seconds35 = "35", seconds40 = "40", seconds45 = "45", seconds50 = "50", seconds55 = "55", seconds60 = "60"
    
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

enum BackgroundIntervalOption: String, CaseIterable {
    case seconds15 = "15", seconds30 = "30", seconds60 = "60", seconds90 = "90", seconds120 = "120"
    
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

enum QueueSizeOption: String, CaseIterable {
    case small = "small", medium = "medium", large = "large", xlarge = "xlarge"
    
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
