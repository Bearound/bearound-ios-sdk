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
                        Text("2.2.1")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Informações")
                }
                
                // Scan Intervals Section
                Section {
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
                } header: {
                    Text("Intervalos de Sync")
                } footer: {
                    Text("Controla a frequência de envio de dados para a API.\n\nForeground: quando o app está ativo\nBackground: quando em segundo plano (ranging é contínuo, interval controla sync)")
                }
                
                // Queue Settings Section
                Section {
                    Picker("Tamanho da Fila", selection: $viewModel.queueSize) {
                        ForEach(MaxQueuedPayloads.allCases, id: \.self) { payload in
                            Text(displayTextForQueue(payload)).tag(payload)
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
