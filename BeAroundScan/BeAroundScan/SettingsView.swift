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
                        Text("2.2.1")
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Section("Intervalos de Sync") {
                    Picker("Foreground", selection: $viewModel.foregroundInterval) {
                        ForEach(ForegroundScanInterval.allCases, id: \.self) { interval in
                            Text("\(Int(interval.timeInterval))s").tag(interval)
                        }
                    }

                    Picker("Background", selection: $viewModel.backgroundInterval) {
                        ForEach(BackgroundScanInterval.allCases, id: \.self) { interval in
                            let seconds = Int(interval.timeInterval)
                            if seconds < 60 {
                                Text("\(seconds)s").tag(interval)
                            } else {
                                Text("\(seconds)s (\(seconds/60)min)").tag(interval)
                            }
                        }
                    }
                }

                Section("Fila de Retry") {
                    Picker("Tamanho da Fila", selection: $viewModel.queueSize) {
                        ForEach(MaxQueuedPayloads.allCases, id: \.self) { payload in
                            Text(displayTextForQueue(payload)).tag(payload)
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
    
    // MARK: - Helper Functions
    
    private func displayTextForQueue(_ payload: MaxQueuedPayloads) -> String {
        switch payload {
        case .small: return "Small (50 batches)"
        case .medium: return "Medium (100 batches)"
        case .large: return "Large (200 batches)"
        case .xlarge: return "XLarge (500 batches)"
        }
    }
}

// MARK: - Note: Now using SDK enums directly - no helper enums needed!
