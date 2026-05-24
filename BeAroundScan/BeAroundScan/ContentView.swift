import BearoundSDK
import CoreLocation
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: BeaconViewModel
    @State private var showSettings = false
    /// Toggles the dedicated focused screen for the two-eyes debug panel.
    /// Sheet so the user can still feel "inside the same app" — full-screen cover
    /// would make it feel like a separate app and lose the breadcrumb back.
    @State private var showTwoEyesScreen = false

    var body: some View {
        NavigationView {
            ScrollView {
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

                        // Prominent entry point for the focused two-eyes debug screen.
                        // Sits right under the title so it's the first thing the tester sees.
                        Button {
                            showTwoEyesScreen = true
                        } label: {
                            HStack(spacing: 6) {
                                Text("👁 👁")
                                    .font(.title3)
                                Text("Abrir Debug — Dois Olhos")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [.green, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(20)
                        }
                        .padding(.top, 4)
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

                        // BLE Diagnostic
                        Text(viewModel.bleDiagnostic)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.orange)
                            .lineLimit(2)

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

                        HStack {
                            Image(systemName: "hand.raised.fill")
                                .font(.caption)
                                .foregroundColor(trackingPermissionColor)
                                .frame(width: 20)
                            Text("Tracking:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.trackingStatus)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(trackingPermissionColor)
                        }

                        HStack {
                            Image(systemName: "tag.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            Text("IDFA:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.idfaValue)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
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
                                Text("Precisão:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(viewModel.scanPrecisionLabel)
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

                    GeofenceDebugCard(viewModel: viewModel)
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
                    .padding(.vertical, 40)
                } else {
                    let pendingBeacons = viewModel.beacons.filter { !$0.alreadySynced }
                    let syncedBeacons = viewModel.beacons.filter { $0.alreadySynced }

                    if !pendingBeacons.isEmpty {
                        BeaconSection(
                            title: "Pending",
                            count: pendingBeacons.count,
                            color: .orange,
                            beacons: pendingBeacons,
                            viewModel: viewModel
                        )
                    }

                    if !syncedBeacons.isEmpty {
                        BeaconSection(
                            title: "Synced",
                            count: syncedBeacons.count,
                            color: .green,
                            beacons: syncedBeacons,
                            viewModel: viewModel
                        )
                    }
                }
            }
            .padding(.vertical)
            }
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
            .sheet(isPresented: $showTwoEyesScreen) {
                TwoEyesDebugScreen(viewModel: viewModel)
            }
        }  // NavigationView
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

    private var trackingPermissionColor: Color {
        let status = viewModel.trackingStatus
        if status.contains("Permitido") { return .green }
        if status.contains("Negado") || status.contains("Restrito") { return .red }
        return .orange
    }
}

struct BeaconSection: View {
    let title: String
    let count: Int
    let color: Color
    let beacons: [Beacon]
    let viewModel: BeaconViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text("\(title) (\(count))")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            LazyVStack(spacing: 0) {
                ForEach(beacons.indices, id: \.self) { index in
                    let beacon = beacons[index]
                    BeaconRow(beacon: beacon, isPinned: viewModel.isPinned(beacon))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.togglePin(for: beacon)
                        }
                        .padding(.horizontal)

                    if index < beacons.count - 1 {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(color.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

struct BeaconRow: View {
    let beacon: Beacon
    var isPinned: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        Text("Beacon \(beacon.major).\(beacon.minor)")
                            .font(.headline)
                    }

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

                    // Debug: detection timestamp + age
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Image(systemName: "eye")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Det: \(beacon.timestamp.formatted(date: .omitted, time: .standard))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text("(\(beaconAge)s ago)")
                            .font(.caption2)
                            .foregroundColor(beaconAgeColor)

                        if let syncedAt = beacon.syncedAt {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text("Sync: \(syncedAt.formatted(date: .omitted, time: .standard))")
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

    private var beaconAge: Int {
        Int(Date().timeIntervalSince(beacon.timestamp))
    }

    private var beaconAgeColor: Color {
        let age = beaconAge
        if age < 10 { return .green }
        if age < 30 { return .orange }
        return .red
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

// MARK: - Two Eyes Dedicated Screen (v2.5)

/// Focused debug screen for the two-eyes model. Presented as a sheet from the main
/// ContentView. Shows the two EyeCards big, with a live event log below — all the
/// state the user needs to validate the duty cycle, region wake-up, and BLE detection
/// behavior in one place, without scrolling past the other diagnostics.
struct TwoEyesDebugScreen: View {
    @ObservedObject var viewModel: BeaconViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header summary — one line that captures the dual state at a glance.
                    summaryStrip

                    // The two big cards. Reuses the same EyeCard component as the
                    // inline panel in ContentView, so visual + behavior stay in sync.
                    HStack(alignment: .top, spacing: 10) {
                        EyeCard(
                            eye: .location,
                            isInZone: viewModel.isInBeaconRegion,
                            lastEnter: viewModel.lastLocationEnter,
                            lastExit: viewModel.lastLocationExit,
                            enterCount: viewModel.locationRegionEnterCount,
                            beaconsNow: viewModel.locationBeaconsNow,
                            totalDetected: viewModel.locationBeaconKeysSeen.count,
                            modeLabel: viewModel.isActiveScanRunning ? "RANGING" : "REGION",
                            modeIsActive: viewModel.isActiveScanRunning,
                            cadenceLabel: viewModel.isActiveScanRunning ? "~1Hz iOS" : "kernel-level",
                            nextScanAt: nil,
                            nowTick: viewModel.nowTick
                        )

                        EyeCard(
                            eye: .bluetooth,
                            isInZone: viewModel.isInBluetoothZone,
                            lastEnter: viewModel.lastBluetoothEnter,
                            lastExit: viewModel.lastBluetoothExit,
                            enterCount: viewModel.bluetoothZoneEnterCount,
                            beaconsNow: viewModel.bluetoothBeaconsNow,
                            totalDetected: viewModel.bluetoothBeaconKeysSeen.count,
                            modeLabel: viewModel.bluetoothScanMode == .active ? "ATIVO" : "STANDBY",
                            modeIsActive: viewModel.bluetoothScanMode == .active,
                            cadenceLabel: viewModel.bluetoothScanMode == .active ? "10s tick" : "5min cycle",
                            nextScanAt: viewModel.bluetoothNextIdleScanAt,
                            nowTick: viewModel.nowTick
                        )
                    }

                    // Comparative analysis — quantifies which eye is "better" for THIS user's
                    // environment based on actual data the app has collected this session.
                    analysisBlock

                    // Quick legend so the user remembers what each mode means without
                    // having to scroll back to docs. Kept compact.
                    legendBlock

                    // Live event log — same data as the inline panel but with more rows visible
                    // and a clear-all button.
                    eventsBlock
                }
                .padding(16)
            }
            .navigationTitle("👁 👁 Dois Olhos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fechar") { dismiss() }
                        .font(.subheadline)
                }
            }
        }
    }

    /// One-line summary at the top — at-a-glance status of both eyes.
    private var summaryStrip: some View {
        HStack(spacing: 8) {
            eyeBadge(
                title: "Location",
                color: .green,
                isOn: viewModel.isInBeaconRegion,
                detail: "\(viewModel.locationBeaconsNow) beacon(s) agora"
            )
            eyeBadge(
                title: "Bluetooth",
                color: .blue,
                isOn: viewModel.isInBluetoothZone,
                detail: "\(viewModel.bluetoothScanMode == .active ? "ATIVO" : "STANDBY") · \(viewModel.bluetoothBeaconsNow) agora"
            )
        }
    }

    private func eyeBadge(title: String, color: Color, isOn: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn ? color : Color.gray)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isOn ? color.opacity(0.12) : Color.gray.opacity(0.08))
        )
    }

    /// "Análise comparativa" — answers the user's question: "which eye is more precise?"
    /// Pulls live aggregates from the view model. Each row is a different lens on the data.
    /// Every number is paired with a quality pill (EXCELENTE/BOM/FRACO/RUIM) + a one-line
    /// natural-language interpretation so a non-RF person can read it cold.
    private var analysisBlock: some View {
        let race = viewModel.detectionRace
        let rssi = viewModel.bluetoothRSSIStats
        let locOnly = viewModel.locationOnlyKeys.count
        let btOnly = viewModel.bluetoothOnlyKeys.count
        let both = viewModel.bothEyesKeys.count
        let hasData = (locOnly + btOnly + both) > 0
        let hasBT = !viewModel.beacons.filter {
            $0.discoverySources.contains(.serviceUUID) || $0.discoverySources.contains(.name)
        }.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            Text("Análise comparativa")
                .font(.subheadline)
                .fontWeight(.semibold)

            if !hasData {
                Text("Sem dados ainda — fica perto de um beacon por uns segundos pra eu poder comparar os olhos.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Top-line verdict — single sentence answer.
                verdictPill(locOnly: locOnly, btOnly: btOnly, both: both,
                            avgRSSI: rssi.avg, hasBT: hasBT,
                            locWins: race.locationWins, btWins: race.bluetoothWins)

                // The main attraction: "Quem é mais preciso?" — 4 dimensions with explicit
                // winners + scoreboard summary. Replaces the old "Cobertura/Latência" split
                // which left the user unsure of who was actually winning.
                precisionScorecard(
                    locOnly: locOnly, btOnly: btOnly, both: both,
                    locWins: race.locationWins, btWins: race.bluetoothWins,
                    avgRSSI: rssi.avg, rssiRange: (rssi.min, rssi.max), hasBT: hasBT
                )

                // Recommendation — synthesized prose from the numbers above. Plain language.
                analysisGroup(title: "Recomendação", hint: nil) {
                    Text(recommendation(locOnly: locOnly, btOnly: btOnly, both: both,
                                        locWins: race.locationWins, btWins: race.bluetoothWins))
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Precision Scorecard (v2.5)

    /// Four-dimension scorecard that declares a winner per category and a final scoreboard.
    /// Replaces the previous Cobertura/Latência sections which made the user count by hand.
    @ViewBuilder
    private func precisionScorecard(
        locOnly: Int, btOnly: Int, both: Int,
        locWins: Int, btWins: Int,
        avgRSSI: Int, rssiRange: (Int, Int), hasBT: Bool
    ) -> some View {
        // Evaluate the four dimensions. Each returns (winner, value-text, why-text).
        let coverage = evaluateCoverage(locOnly: locOnly, btOnly: btOnly, both: both)
        let speed = evaluateSpeed(locWins: locWins, btWins: btWins)
        let granularity = evaluateGranularity(hasBT: hasBT)
        let stability = evaluateStability(hasBT: hasBT, range: rssiRange, avg: avgRSSI)

        // Scoreboard tally — including a 'no-data' bucket for dimensions that can't be
        // judged in the current setup (e.g. BT off → granularity/stability are unmeasurable).
        // This matters: without it, the silent eye looks like it 'won' those dimensions when
        // really it just had no competition.
        let dimensions = [coverage, speed, granularity, stability]
        let locScore = dimensions.filter { $0.winner == .location }.count
        let btScore = dimensions.filter { $0.winner == .bluetooth }.count
        let tieScore = dimensions.filter { $0.winner == .tie }.count
        let noDataScore = dimensions.filter { $0.winner == .none }.count

        VStack(alignment: .leading, spacing: 10) {
            Text("Quem é mais preciso?")
                .font(.system(size: 13, weight: .bold))

            // 4 dimension cards
            precisionRow(icon: "🎯", title: "Cobertura",     evaluation: coverage)
            precisionRow(icon: "⚡", title: "Velocidade",     evaluation: speed)
            precisionRow(icon: "🔍", title: "Granularidade",  evaluation: granularity)
            precisionRow(icon: "📊", title: "Estabilidade",   evaluation: stability)

            // Final scoreboard — one big row showing the tally with explicit framing
            // so the user reads "X-Y" rather than re-counting badges above.
            scoreboardRow(loc: locScore, bt: btScore, ties: tieScore, noData: noDataScore)
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    /// Render one dimension row: icon · title · winner badge · value · why-prose.
    /// The "why" is the key addition the user asked for — every number has its
    /// interpretation glued to it.
    private func precisionRow(icon: String, title: String, evaluation: PrecisionEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(icon).font(.body)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                winnerBadge(evaluation.winner)
            }
            // Value (numeric) and why (prose). Padded so they nest under the title visually.
            VStack(alignment: .leading, spacing: 2) {
                Text(evaluation.valueText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                Text(evaluation.why)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 4)
    }

    /// Small colored chip showing who won this dimension. Same chip language as the cards.
    @ViewBuilder
    private func winnerBadge(_ winner: PrecisionWinner) -> some View {
        switch winner {
        case .location:
            chip(text: "👁 LOCATION", color: .green)
        case .bluetooth:
            chip(text: "👁 BLUETOOTH", color: .blue)
        case .tie:
            chip(text: "EMPATE", color: .gray)
        case .none:
            chip(text: "S/ DADOS", color: .gray)
        }
    }

    private func chip(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color, lineWidth: 0.8)
            )
    }

    /// Final scoreboard row — visual tally. Bigger numbers, more impact.
    /// Includes a S/ DADOS column when dimensions couldn't be judged (e.g. one eye silent)
    /// so the user sees the result is incomplete rather than a fake 'sweep'.
    private func scoreboardRow(loc: Int, bt: Int, ties: Int, noData: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                scoreColumn(value: loc, label: "LOCATION", color: .green)
                Text("—").font(.title3).foregroundColor(.secondary)
                scoreColumn(value: bt, label: "BLUETOOTH", color: .blue)
                if ties > 0 {
                    Text("·").font(.title3).foregroundColor(.secondary)
                    scoreColumn(value: ties, label: "EMPATE", color: .gray)
                }
                if noData > 0 {
                    Text("·").font(.title3).foregroundColor(.secondary)
                    scoreColumn(value: noData, label: "S/ DADOS", color: .gray)
                }
                Spacer()
            }
            if noData > 0 {
                Text("\(noData) dimensão(ões) sem comparação — um dos olhos precisa estar ativo pra eu medir.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
        .padding(.top, 4)
    }

    private func scoreColumn(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Per-dimension evaluation logic

    private enum PrecisionWinner { case location, bluetooth, tie, none }

    private struct PrecisionEvaluation {
        let winner: PrecisionWinner
        let valueText: String
        let why: String
    }

    /// 🎯 Cobertura — quem vê mais dos beacons disponíveis (relativo ao total visto pelos dois).
    /// Reframed from the old "Só Location 0 / Só BT 0 / Ambos N" which made the user count by hand.
    /// Now expressed as "BT cobre X% do que Location vê" + reverse.
    private func evaluateCoverage(locOnly: Int, btOnly: Int, both: Int) -> PrecisionEvaluation {
        let totalUniverse = locOnly + btOnly + both
        guard totalUniverse > 0 else {
            return .init(winner: .none, valueText: "0 beacons", why: "Nenhum beacon visto ainda.")
        }
        // % of the union that each eye sees
        let locSees = both + locOnly  // beacons Location has seen
        let btSees = both + btOnly    // beacons BT has seen
        let locPct = Int((Double(locSees) / Double(totalUniverse)) * 100)
        let btPct = Int((Double(btSees) / Double(totalUniverse)) * 100)

        let winner: PrecisionWinner
        if locPct == btPct { winner = .tie }
        else if locPct > btPct { winner = .location }
        else { winner = .bluetooth }

        let valueText = "Location: \(locPct)% (\(locSees)/\(totalUniverse))   •   Bluetooth: \(btPct)% (\(btSees)/\(totalUniverse))"
        let why: String
        if winner == .tie {
            why = "Os dois olhos veem 100% dos beacons. Cobertura completa."
        } else if winner == .location {
            why = "Location enxerga \(locSees - btSees) beacon(s) que o BT não vê — provável: BT bloqueado ou fora de range."
        } else {
            why = "Bluetooth enxerga \(btSees - locSees) beacon(s) que o Location não vê — provável: Precise Location off ou beacon fora da region monitorada."
        }
        return .init(winner: winner, valueText: valueText, why: why)
    }

    /// ⚡ Velocidade — quem detectou primeiro nas corridas (overlap-only).
    private func evaluateSpeed(locWins: Int, btWins: Int) -> PrecisionEvaluation {
        let total = locWins + btWins
        guard total > 0 else {
            return .init(winner: .none, valueText: "Sem corridas ainda", why: "Precisa de pelo menos 1 beacon visto pelos 2 olhos pra medir.")
        }
        let winner: PrecisionWinner
        if locWins == btWins { winner = .tie }
        else if locWins > btWins { winner = .location }
        else { winner = .bluetooth }

        let valueText = "Location: \(locWins)x   •   Bluetooth: \(btWins)x"
        let why: String
        switch winner {
        case .location:
            why = "Location detectou primeiro em \(locWins) de \(total) corridas. Vantagem: kernel-level monitoring acorda o app antes do BLE scan."
        case .bluetooth:
            why = "Bluetooth detectou primeiro em \(btWins) de \(total) corridas. Vantagem: scan ativo é determinístico (~1-2s); CL pode ser preguiçoso (até 30s)."
        case .tie:
            why = "Empate técnico — os dois olhos respondem em paralelo, sem atraso significativo entre eles."
        case .none:
            why = ""
        }
        return .init(winner: winner, valueText: valueText, why: why)
    }

    /// 🔍 Granularidade — qual olho dá leitura mais fina por beacon.
    /// BT é estruturalmente mais granular (RSSI em dBm vs 4 proximity buckets do CL).
    /// Quando BT está off, NÃO atribuímos vitória pra Location aqui — esta dimensão simplesmente
    /// não tem dado pra comparar. Dar ponto pra Location seria enganoso (ela não substitui o RSSI).
    private func evaluateGranularity(hasBT: Bool) -> PrecisionEvaluation {
        if hasBT {
            return .init(
                winner: .bluetooth,
                valueText: "BT: RSSI em dBm (256 níveis)   •   Location: 4 buckets (immediate/near/far/unknown)",
                why: "Bluetooth dá distância fina por dBm. CoreLocation só te diz a 'faixa' (perto/médio/longe). BT é ~64x mais granular."
            )
        } else {
            return .init(
                winner: .none,
                valueText: "Sem dado BT — comparação impossível",
                why: "Granularidade só é mensurável via Bluetooth (RSSI puro). Com BT off, Location não consegue 'substituir' essa dimensão — ela simplesmente não tem essa informação. Liga o BT pra ver."
            )
        }
    }

    /// 📊 Estabilidade — qual eye mantém leitura consistente.
    /// Esta dimensão SÓ É MENSURÁVEL via Bluetooth (Location não expõe variância). Quando BT
    /// tem dados, BT vence (com label de qualidade variando BAIXA/MÉDIA/ALTA). Quando BT está
    /// off, retornamos .none — atribuir vitória pra Location aqui é enganoso porque ela
    /// "parece estável" só porque não mede nada.
    private func evaluateStability(hasBT: Bool, range: (min: Int, max: Int), avg: Int) -> PrecisionEvaluation {
        guard hasBT else {
            return .init(
                winner: .none,
                valueText: "Sem dado BT — comparação impossível",
                why: "Estabilidade só é mensurável via BT (variância do RSSI). Location 'parece estável' só porque não expõe esse dado — não é uma vitória real, é a ausência de medição."
            )
        }
        let spread = range.max - range.min
        // BT always wins this dimension when it has data — only it can measure variance.
        // The quality label is what shifts (BAIXA / MÉDIA / ALTA), not the winner.
        let stability: String
        if spread <= 10 {
            stability = "Variação BAIXA (\(spread) dB) — sinal muito estável"
        } else if spread <= 25 {
            stability = "Variação MÉDIA (\(spread) dB) — sinal aceitável"
        } else {
            stability = "Variação ALTA (\(spread) dB) — beacons em distâncias diferentes ou sinal oscilando"
        }
        return .init(
            winner: .bluetooth,
            valueText: "BT range: \(range.min)…\(range.max) dBm   •   Δ \(spread) dB",
            why: "\(stability). Location não tem esse dado bruto — não consegue competir nessa dimensão."
        )
    }

    // MARK: - Quality thresholds (RSSI + Latency)

    /// Maps an RSSI value (in dBm) to a human-readable quality bucket + color.
    /// Thresholds chosen from typical BLE deployment ranges:
    ///   ≥ -55 dBm: practically touching the beacon
    ///   -55..-70: normal indoor working range, very reliable
    ///   -70..-85: still detectable but flaky, may drop in/out
    ///   < -85: edge of receiver sensitivity, expect frequent misses
    private func rssiQuality(avg: Int) -> (label: String, color: Color) {
        switch avg {
        case (-54)... :    return ("EXCELENTE", .green)
        case (-70) ... (-55): return ("BOM",     .green)
        case (-85) ... (-71): return ("FRACO",   .orange)
        default:               return ("RUIM",    .red)
        }
    }

    /// Maps the average latency lead (positive seconds) between eyes to a quality bucket.
    /// Closer to zero = the two eyes are tightly synchronized. Larger numbers = one eye is
    /// clearly ahead — usually means the slower one is being throttled by iOS.
    private func latencyQuality(seconds: Double) -> (label: String, color: Color) {
        switch seconds {
        case 0..<0.5:  return ("MUITO RÁPIDO", .green)
        case 0.5..<3:  return ("OK",            .green)
        case 3..<10:   return ("LENTO",         .orange)
        default:        return ("BEM LENTO",     .red)
        }
    }

    // MARK: - Verdict pill

    /// Big colored pill at the top of the analysis block. Synthesizes everything into
    /// a single conclusion the user can read in 1 second.
    @ViewBuilder
    private func verdictPill(
        locOnly: Int, btOnly: Int, both: Int,
        avgRSSI: Int, hasBT: Bool,
        locWins: Int, btWins: Int
    ) -> some View {
        let v = computeVerdict(
            locOnly: locOnly, btOnly: btOnly, both: both,
            avgRSSI: avgRSSI, hasBT: hasBT,
            locWins: locWins, btWins: btWins
        )

        HStack(alignment: .top, spacing: 10) {
            Text(v.emoji)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("VEREDITO")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(v.headline)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(v.color)
                Text(v.subline)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(v.color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(v.color, lineWidth: 1.5)
        )
    }

    /// Computes the verdict from the current session's numbers. Priority order:
    ///   1. RSSI too weak (universal problem regardless of which eye)
    ///   2. One eye is silent (only the other is delivering data)
    ///   3. One eye is faster than the other in latency races
    ///   4. Default: both healthy
    private func computeVerdict(
        locOnly: Int, btOnly: Int, both: Int,
        avgRSSI: Int, hasBT: Bool,
        locWins: Int, btWins: Int
    ) -> (emoji: String, headline: String, subline: String, color: Color) {
        // 1. Weak signal everywhere — neither eye is doing great
        if hasBT && avgRSSI < -85 {
            return (
                "⚠️",
                "Sinal fraco — chega mais perto do beacon",
                "Os dois olhos estão capturando, mas o RSSI está no limite. Pode haver perda de detecção a qualquer momento.",
                .orange
            )
        }

        // 2. One eye is silent
        if locOnly + both > 0 && btOnly + both == 0 {
            return (
                "🟢",
                "Location está dominando — Bluetooth silencioso",
                "Só a Location está vendo beacons. Verifica a permissão de Bluetooth do app ou se BT está ligado no celular.",
                .green
            )
        }
        if btOnly + both > 0 && locOnly + both == 0 {
            return (
                "🔵",
                "Bluetooth está dominando — Location silencioso",
                "Só o BT está vendo beacons. Verifica permissão Location, Precise Location, ou se o beacon é um CLBeaconRegion válido.",
                .blue
            )
        }

        // 3. Clear winner in latency races
        if both >= 2 && locWins > btWins * 2 {
            return (
                "🟢",
                "Location é mais rápido aqui",
                "Em \(locWins) de \(locWins + btWins) corridas, Location detectou primeiro. Use ele pra acordar o app.",
                .green
            )
        }
        if both >= 2 && btWins > locWins * 2 {
            return (
                "🔵",
                "Bluetooth é mais rápido aqui",
                "Em \(btWins) de \(locWins + btWins) corridas, BT detectou primeiro. Talvez Location esteja sendo throttled pelo iOS.",
                .blue
            )
        }

        // 4. Both healthy
        return (
            "✅",
            "Os dois olhos estão precisos",
            "Cobertura completa, sinal bom, latência baixa. Use Location pra wake-up + BT pra precisão fina.",
            .green
        )
    }

    private enum StatEmphasis {
        case green, blue, primary, muted

        var color: Color {
            switch self {
            case .green:   return .green
            case .blue:    return .blue
            case .primary: return .primary
            case .muted:   return .secondary
            }
        }
    }

    private func analysisGroup<Content: View>(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.leading, 4)
            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func statRow(label: String, value: String, emphasis: StatEmphasis) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(emphasis.color)
        }
    }

    /// Carrier for the colored quality badge shown next to a value.
    /// nil-able so we can skip the badge for neutral/contextual rows.
    private struct QualityBadge {
        let text: String
        let color: Color
        init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    }

    /// Variant of statRow that appends a small colored badge (EXCELENTE / BOM / FRACO / RUIM /
    /// LACUNA / VENCEDOR / OK / OVERLAP) so the user can interpret the number without
    /// knowing the underlying scale.
    private func statRowWithBadge(label: String, value: String, valueColor: Color, badge: QualityBadge?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(valueColor)
            if let badge {
                Text(badge.text)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(badge.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(badge.color.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(badge.color, lineWidth: 0.8)
                    )
            }
        }
    }

    /// Generates a one-paragraph recommendation based on the data the user has collected.
    /// We don't pretend there's a single winner — we surface the trade-offs that matched
    /// THIS session's numbers.
    private func recommendation(locOnly: Int, btOnly: Int, both: Int, locWins: Int, btWins: Int) -> String {
        var lines: [String] = []

        if both > 0 && locWins > btWins {
            lines.append("• Location detectou primeiro em \(locWins)/\(locWins + btWins) beacons → melhor pra wake-up rápido.")
        } else if both > 0 && btWins > locWins {
            lines.append("• Bluetooth detectou primeiro em \(btWins)/\(locWins + btWins) beacons → melhor pra real-time aqui.")
        } else if both > 0 {
            lines.append("• Empate técnico de latência entre os olhos.")
        }

        if locOnly > 0 {
            lines.append("• \(locOnly) beacon(s) só apareceu(ram) via Location — BT pode estar bloqueado ou fora de range.")
        }
        if btOnly > 0 {
            lines.append("• \(btOnly) beacon(s) só apareceu(ram) via BT — provavelmente Precise Location off, ou o beacon não está na region monitorada.")
        }

        lines.append("→ Use Location pra acordar o app (kernel level, fires mesmo terminated).")
        lines.append("→ Use Bluetooth pra contagem ao vivo + RSSI fino + metadata (battery, temp).")

        return lines.joined(separator: "\n")
    }

    /// Compact legend reminding the user what each mode/transition means. Stuck below the
    /// cards so it's always in view without scrolling. Designed to be informative for a
    /// first-time tester reading the screen cold.
    private var legendBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Como ler")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            legendRow(
                color: .green,
                title: "Location",
                text: "iBeacon region monitoring do iOS (kernel level). Funciona mesmo se BT estiver bloqueado no app."
            )
            legendRow(
                color: .blue,
                title: "Bluetooth",
                text: "CBCentralManager scan ativo. STANDBY = scanner off, peek de 10s a cada 5min. ATIVO = scan contínuo."
            )
            legendRow(
                color: .orange,
                title: "Wake-up",
                text: "Quando Location entra na zona, o BT eye é acordado pra ATIVO imediatamente — não espera o ciclo."
            )
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    private func legendRow(color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Live event log — most recent first, capped at 20 visible rows. The full 30 still
    /// lives in the view model.
    private var eventsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Eventos ao vivo")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if !viewModel.geofenceEventLog.isEmpty {
                    Button("Limpar") { viewModel.clearGeofenceLog() }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.geofenceEventLog.isEmpty {
                Text("Nenhum evento ainda — aproxime de um beacon para disparar.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.geofenceEventLog.prefix(20)) { event in
                        GeofenceEventRow(event: event)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Geofence Debug — Two Eyes (v2.5)

struct GeofenceDebugCard: View {
    @ObservedObject var viewModel: BeaconViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Debug Geofence — Dois Olhos")
                    .font(.headline)
                Spacer()
                if !viewModel.geofenceEventLog.isEmpty {
                    Button(action: { viewModel.clearGeofenceLog() }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Two eyes side by side. On narrow screens iOS stacks them automatically.
            HStack(alignment: .top, spacing: 10) {
                EyeCard(
                    eye: .location,
                    isInZone: viewModel.isInBeaconRegion,
                    lastEnter: viewModel.lastLocationEnter,
                    lastExit: viewModel.lastLocationExit,
                    enterCount: viewModel.locationRegionEnterCount,
                    beaconsNow: viewModel.locationBeaconsNow,
                    totalDetected: viewModel.locationBeaconKeysSeen.count,
                    // Location eye doesn't have a BLE-style duty cycle. We map its current
                    // operating state to the same Modo/Cadência slots so both cards look symmetric:
                    //   - "Ranging" (active) when iOS is currently delivering beacon updates
                    //   - "Region monitor" (idle) when only kernel-level region monitoring is on
                    modeLabel: viewModel.isActiveScanRunning ? "RANGING" : "REGION",
                    modeIsActive: viewModel.isActiveScanRunning,
                    cadenceLabel: viewModel.isActiveScanRunning ? "~1Hz iOS" : "kernel-level",
                    nextScanAt: nil,
                    nowTick: viewModel.nowTick
                )

                EyeCard(
                    eye: .bluetooth,
                    isInZone: viewModel.isInBluetoothZone,
                    lastEnter: viewModel.lastBluetoothEnter,
                    lastExit: viewModel.lastBluetoothExit,
                    enterCount: viewModel.bluetoothZoneEnterCount,
                    beaconsNow: viewModel.bluetoothBeaconsNow,
                    totalDetected: viewModel.bluetoothBeaconKeysSeen.count,
                    modeLabel: viewModel.bluetoothScanMode == .active ? "ATIVO" : "STANDBY",
                    modeIsActive: viewModel.bluetoothScanMode == .active,
                    cadenceLabel: viewModel.bluetoothScanMode == .active ? "10s tick" : "5min cycle",
                    nextScanAt: viewModel.bluetoothNextIdleScanAt,
                    nowTick: viewModel.nowTick
                )
            }

            // Active scan status — surfaces ranging + BLE central state for the Location eye.
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan ativo (👁 olho Location)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                statusRow(
                    icon: "antenna.radiowaves.left.and.right",
                    label: "Scan ativo (ranging):",
                    value: viewModel.isActiveScanRunning ? "LIGADO" : "desligado",
                    color: viewModel.isActiveScanRunning ? .green : .secondary,
                    bold: viewModel.isActiveScanRunning
                )
            }
            .padding(12)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            if !viewModel.geofenceEventLog.isEmpty {
                Text("Eventos recentes")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.geofenceEventLog.prefix(10)) { event in
                        GeofenceEventRow(event: event)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(icon: String, label: String, value: String, color: Color, bold: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(bold ? .bold : .medium)
                .foregroundColor(color)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

// MARK: - Single Eye Card (v2.5)

/// One Debug Geofence card representing a single "eye" — Location or Bluetooth.
/// Both cards are rendered side-by-side inside GeofenceDebugCard.
struct EyeCard: View {
    let eye: GeofenceEye
    let isInZone: Bool
    let lastEnter: Date?
    let lastExit: Date?
    let enterCount: Int
    /// Beacons currently visible to this eye, derived live from the viewModel's beacons array.
    let beaconsNow: Int
    /// Cumulative count of unique beacons (by major.minor) this eye has detected this session.
    let totalDetected: Int
    /// Short label for the current operating mode (e.g. "ATIVO", "STANDBY", "RANGING", "REGION").
    let modeLabel: String
    /// True when the eye is in its "high-frequency / actively detecting" mode. Used for color.
    let modeIsActive: Bool
    /// Sub-label describing the cadence the user can expect ("10s tick", "5min cycle", "~1Hz iOS").
    let cadenceLabel: String
    /// When non-nil, render a live countdown to this date — the next idle peek time for BT eye.
    /// Location eye passes nil (no scheduled peek concept on its side).
    let nextScanAt: Date?
    /// 1Hz heartbeat from the view model. Triggering re-renders ages the countdown.
    let nowTick: Date

    /// Display labels per eye, kept here so the parent stays mechanism-agnostic.
    private var title: String {
        switch eye {
        case .location:  return "👁 Location"
        case .bluetooth: return "👁 Bluetooth"
        }
    }

    private var subtitle: String {
        switch eye {
        case .location:  return "CLBeaconRegion"
        case .bluetooth: return "CBCentralManager"
        }
    }

    /// Accent color used for the in-zone state. Distinct between the two eyes so they're
    /// visually separable at a glance even before reading the labels.
    private var accentColor: Color {
        switch eye {
        case .location:  return .green
        case .bluetooth: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Eye label + mechanism subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.bold)
                Text(subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Big presence indicator — flips green/blue when "in zone", gray when out.
            HStack(spacing: 6) {
                Circle()
                    .fill(isInZone ? accentColor : Color.gray)
                    .frame(width: 10, height: 10)
                Text(isInZone ? "DENTRO" : "fora")
                    .font(.caption)
                    .fontWeight(isInZone ? .bold : .medium)
                    .foregroundColor(isInZone ? accentColor : .secondary)
            }

            // Two big pills with the detection counts — what this eye SEES right now and
            // what it has seen ever this session. These are the primary signal for the
            // user during testing: a card with "Beacons agora: 0" and "Total: 0" means
            // that eye is not picking up anything.
            HStack(spacing: 6) {
                countPill(label: "Agora",  value: beaconsNow,     emphasize: beaconsNow > 0)
                countPill(label: "Total",  value: totalDetected,  emphasize: false)
            }

            // Mode / cadence — the duty cycle of this eye. For BT this flips between
            // STANDBY (5min) and ATIVO (10s tick). For Location it shows whether iOS
            // is currently ranging or just monitoring the region in the background.
            modeBlock

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                detailRow(label: "Entrou:",   value: formatTimestamp(lastEnter))
                detailRow(label: "Saiu:",     value: formatTimestamp(lastExit))
                detailRow(label: "Entradas:", value: "\(enterCount)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isInZone ? accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isInZone ? accentColor : Color.gray.opacity(0.3), lineWidth: isInZone ? 1.5 : 1)
        )
    }

    /// Composite view that renders Modo (mode label) + Cadência + optional Próx scan countdown.
    /// Kept as a computed `@ViewBuilder` so the body() above stays scannable.
    @ViewBuilder
    private var modeBlock: some View {
        let bg = modeIsActive ? accentColor.opacity(0.18) : Color.gray.opacity(0.12)
        let fg = modeIsActive ? accentColor : Color.secondary

        VStack(alignment: .leading, spacing: 3) {
            // Top line: MODO + status pill
            HStack(spacing: 4) {
                Text("MODO")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(modeLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(fg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(bg)
                    )
                Spacer()
            }

            // Cadência — how often this eye produces a detection beat
            HStack {
                Text("Cadência:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text(cadenceLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary)
            }

            // Live countdown to next idle peek. Only rendered for the BT eye in STANDBY.
            // We deliberately depend on `nowTick` so SwiftUI re-renders this row every second
            // without touching anything else.
            if let next = nextScanAt {
                HStack {
                    Text("Próx. scan:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(countdownString(to: next, now: nowTick))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Formats a countdown to `target` as "Xm Ys" (or "Ys" if under a minute).
    /// Returns "agora" once we pass the target, since the SDK should be peeking at that point.
    private func countdownString(to target: Date, now: Date) -> String {
        let delta = max(0, Int(target.timeIntervalSince(now)))
        if delta <= 0 { return "agora" }
        let minutes = delta / 60
        let seconds = delta % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    /// "—" when nil, otherwise local time (HH:mm:ss).
    private func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    /// Compact count badge — "Agora 3", "Total 7". When `emphasize` the pill takes on
    /// the eye's accent color so a non-zero "live" count visually pops.
    private func countPill(label: String, value: Int, emphasize: Bool) -> some View {
        let bg = emphasize ? accentColor.opacity(0.18) : Color.gray.opacity(0.12)
        let fg = emphasize ? accentColor : Color.primary
        return VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text("\(value)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(fg)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(bg)
        )
    }
}

struct GeofenceEventRow: View {
    let event: GeofenceEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(color)
                    Spacer()
                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(event.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var color: Color {
        switch event.kind {
        case .regionEnter: .green
        case .regionExit: .orange
        case .scanResumed: .mint
        case .scanPaused: .gray
        case .bluetoothZoneEnter: .blue
        case .bluetoothZoneExit: .orange
        }
    }

    private var title: String {
        switch event.kind {
        case .regionEnter: "LOCATION → DENTRO"
        case .regionExit: "LOCATION → FORA"
        case .scanResumed: "SCAN LIGADO"
        case .scanPaused: "SCAN PAUSADO"
        case .bluetoothZoneEnter: "BLUETOOTH → DENTRO"
        case .bluetoothZoneExit: "BLUETOOTH → FORA"
        }
    }
}
