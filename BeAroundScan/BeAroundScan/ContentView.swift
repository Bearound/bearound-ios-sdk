import BearoundSDK
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = BeaconViewModel()
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("BeAroundScan")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Permissões")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "location.fill")
                                .font(.caption)
                                .foregroundColor(locationPermissionColor)
                                .frame(width: 20)
                            Text("Localização:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.permissionStatus)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(locationPermissionColor)
                        }

                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundColor(bluetoothPermissionColor)
                                .frame(width: 20)
                            Text("Bluetooth:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.bluetoothStatus)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(bluetoothPermissionColor)
                        }

                        HStack {
                            Image(systemName: "bell.fill")
                                .font(.caption)
                                .foregroundColor(notificationPermissionColor)
                                .frame(width: 20)
                            Text("Notificações:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.notificationStatus)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(notificationPermissionColor)
                        }
                    }
                    .padding(12)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                if viewModel.isScanning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Informações do Scan")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Modo:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(viewModel.scanMode)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            HStack {
                                Text("Intervalo de sync:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(viewModel.currentDisplayInterval)s")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            HStack {
                                Text("Duração do scan:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(viewModel.scanDuration)s")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            Divider()

                        }
                        .padding(12)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Informações do Sync")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Último sync:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let syncTime = viewModel.lastSyncTime {
                                    Text(syncTime.formatted(date: .omitted, time: .standard))
                                        .font(.caption)
                                        .fontWeight(.medium)
                                } else {
                                    Text("--")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                            }

                            HStack {
                                Text("Beacons sincronizados:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(viewModel.lastSyncBeaconCount)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            HStack {
                                Text("Resposta do ingest:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(viewModel.lastSyncResult)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(syncResultColor)
                            }
                        }
                        .padding(12)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                Button(action: {
                    if viewModel.isScanning {
                        viewModel.stopScanning()
                    } else {
                        viewModel.startScanning()
                    }
                }) {
                    Text(viewModel.isScanning ? "Parar Scan" : "Iniciar Scan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isScanning ? .red : .blue)
                .padding(.horizontal)
                
                Button(action: {
                    showSettings = true
                }) {
                    Label("Configurações do SDK", systemImage: "gearshape.fill")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)

                HStack {
                    Text("Ordenar:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Picker("", selection: $viewModel.sortOption) {
                        ForEach(BeaconSortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                .padding(.horizontal)

                if let lastScan = viewModel.lastScanTime {
                    Text("Última atualização: \(lastScan.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if viewModel.beacons.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("Aguardando próximos scans")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        if viewModel.isScanning {
                            Text("O sistema está monitorando beacons")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(viewModel.beacons.indices, id: \.self) { index in
                        BeaconRow(beacon: viewModel.beacons[index])
                    }
                    .listStyle(.plain)
                }
            }
            .padding(.vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
        }
    }

    private var locationPermissionColor: Color {
        let status = viewModel.permissionStatus
        if status.contains("Negada") { return .red }
        if status.contains("Sempre") { return .green }
        if status.contains("Quando em uso") || status.contains("Aguardando") { return .orange }
        return .secondary
    }

    private var bluetoothPermissionColor: Color {
        let status = viewModel.bluetoothStatus
        if status.contains("Ligado") { return .green }
        if status.contains("Desligado") || status.contains("Não autorizado") { return .red }
        if status.contains("Não suportado") { return .red }
        return .orange
    }

    private var syncResultColor: Color {
        let result = viewModel.lastSyncResult
        if result.contains("Sucesso") { return .green }
        if result.contains("Falha") { return .red }
        return .secondary
    }

    private var notificationPermissionColor: Color {
        let status = viewModel.notificationStatus
        if status.contains("Autorizada") { return .green }
        if status.contains("Negada") { return .red }
        return .orange
    }
}

struct BeaconRow: View {
    let beacon: Beacon

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Beacon \(beacon.major).\(beacon.minor)")
                        .font(.headline)

                    Text(beacon.uuid.uuidString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(proximityColor)
                                .frame(width: 8, height: 8)
                            Text(proximityText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if beacon.accuracy > 0 {
                            Text(String(format: "%.1fm", beacon.accuracy))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        ForEach(sortedDiscoverySources, id: \.self) { source in
                            Text(sourceText(for: source))
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(sourceColor(for: source))
                                .cornerRadius(4)
                        }
                    }

                    if let metadata = beacon.metadata {
                        HStack(spacing: 10) {
                            HStack(spacing: 3) {
                                Image(systemName: "battery.100")
                                    .font(.caption2)
                                    .foregroundColor(batteryColor(metadata.batteryLevel))
                                Text("\(metadata.batteryLevel)mV")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 3) {
                                Image(systemName: "thermometer.medium")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text("\(metadata.temperature)\u{00B0}C")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 3) {
                                Image(systemName: "figure.walk.motion")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                Text("\(metadata.movements)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 3) {
                                Image(systemName: "cpu")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                Text("v\(metadata.firmwareVersion)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                    Text("\(beacon.rssi)dB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var uuidString: String {
        let uuid = beacon.uuid.uuidString
        return "\(uuid.prefix(8))...\(uuid.suffix(4))"
    }

    private var proximityText: String {
        switch beacon.proximity {
        case .immediate: "Imediato"
        case .near: "Perto"
        case .far: "Longe"
        case .bt: "Bluetooth"
        case .unknown: "Desconhecido"
        }
    }

    private var proximityColor: Color {
        switch beacon.proximity {
        case .immediate: .green
        case .near: .orange
        case .far: .red
        case .bt: .blue
        case .unknown: .gray
        }
    }

    private func batteryColor(_ mV: Int) -> Color {
        if mV > 2800 { return .green }
        if mV > 2400 { return .orange }
        return .red
    }

    private var sortedDiscoverySources: [BeaconDiscoverySource] {
        let order: [BeaconDiscoverySource] = [.serviceUUID, .coreLocation, .name]
        return order.filter { beacon.discoverySources.contains($0) }
    }

    private func sourceText(for source: BeaconDiscoverySource) -> String {
        switch source {
        case .serviceUUID: "Service UUID"
        case .name: "Name"
        case .coreLocation: "iBeacon"
        }
    }

    private func sourceColor(for source: BeaconDiscoverySource) -> Color {
        switch source {
        case .serviceUUID: .purple
        case .name: .teal
        case .coreLocation: .indigo
        }
    }
}
