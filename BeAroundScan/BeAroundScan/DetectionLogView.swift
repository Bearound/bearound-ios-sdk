import SwiftUI

enum LogModeFilter: String, CaseIterable {
    case all = "Tudo"
    case foreground = "FG"
    case background = "BG"
    case backgroundLocked = "BG Lock"
}

enum LogTypeFilter: String, CaseIterable {
    case all = "Tudo"
    case serviceUUID = "Service UUID"
    case ibeacon = "iBeacon"
}

enum LogViewMode: String, CaseIterable {
    case detail = "Detalhado"
    case grouped = "Por Minuto"
}

struct DetectionLogView: View {
    @ObservedObject var viewModel: BeaconViewModel
    @State private var modeFilter: LogModeFilter = .all
    @State private var typeFilter: LogTypeFilter = .all
    @State private var viewMode: LogViewMode = .detail

    private var filteredLog: [DetectionLogEntry] {
        let sourceLog: [DetectionLogEntry] = switch modeFilter {
        case .all: viewModel.detectionLog
        case .foreground: viewModel.foregroundLog
        case .background: viewModel.backgroundLog
        case .backgroundLocked: viewModel.backgroundLockedLog
        }

        return sourceLog.filter { entry in
            switch typeFilter {
            case .all: true
            case .serviceUUID: entry.discoverySource == "Service UUID" || entry.discoverySource == "Both"
            case .ibeacon: entry.discoverySource == "iBeacon" || entry.discoverySource == "Both"
            }
        }
    }

    private var groupedByMinute: [MinuteGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredLog) { entry in
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: entry.timestamp)
        }

        return grouped.map { (components, entries) in
            let date = calendar.date(from: components) ?? Date()
            let fgCount = entries.filter { !$0.isBackground && !$0.isLocked }.count
            let bgCount = entries.filter { $0.isBackground && !$0.isLocked }.count
            let lkCount = entries.filter { $0.isLocked }.count
            let uniqueBeacons = Set(entries.map { "\($0.major).\($0.minor)" }).count
            return MinuteGroup(
                date: date,
                total: entries.count,
                fgCount: fgCount,
                bgCount: bgCount,
                lkCount: lkCount,
                uniqueBeacons: uniqueBeacons
            )
        }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Vista", selection: $viewMode) {
                        ForEach(LogViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Modo", selection: $modeFilter) {
                        ForEach(LogModeFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Tipo", selection: $typeFilter) {
                        ForEach(LogTypeFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("FG:\(viewModel.foregroundLog.count) BG:\(viewModel.backgroundLog.count) LK:\(viewModel.backgroundLockedLog.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.clearDetectionLog()
                        } label: {
                            Label("Limpar", systemImage: "trash")
                                .font(.caption)
                        }
                        .disabled(viewModel.foregroundLog.isEmpty && viewModel.backgroundLog.isEmpty && viewModel.backgroundLockedLog.isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if filteredLog.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Nenhuma detecção registrada")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if viewMode == .grouped {
                    List {
                        ForEach(groupedByMinute) { group in
                            MinuteGroupRow(group: group)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    List {
                        ForEach(filteredLog) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Log de Detecções")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Minute Group Model

private struct MinuteGroup: Identifiable {
    let id = UUID()
    let date: Date
    let total: Int
    let fgCount: Int
    let bgCount: Int
    let lkCount: Int
    let uniqueBeacons: Int
}

// MARK: - Minute Group Row

private struct MinuteGroupRow: View {
    let group: MinuteGroup

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.formatter.string(from: group.date))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(group.total) detecções")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }

            HStack(spacing: 8) {
                if group.fgCount > 0 {
                    badgeCount("FG", count: group.fgCount, color: .green)
                }
                if group.bgCount > 0 {
                    badgeCount("BG", count: group.bgCount, color: .orange)
                }
                if group.lkCount > 0 {
                    badgeCount("LK", count: group.lkCount, color: .red)
                }

                Spacer()

                Text("\(group.uniqueBeacons) beacon\(group.uniqueBeacons == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func badgeCount(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color)
                .cornerRadius(3)
            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Detail Row

private struct LogEntryRow: View {
    let entry: DetectionLogEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(entry.major).\(entry.minor)")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Text(Self.dateFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Text("RSSI: \(entry.rssi)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(entry.proximity)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(proximityColor)
                    .cornerRadius(3)

                sourceBadge

                modeBadge
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var modeBadge: some View {
        if entry.isLocked {
            badgeText("LK", color: .red)
        } else if entry.isBackground {
            badgeText("BG", color: .orange)
        } else {
            badgeText("FG", color: .green)
        }
    }

    private var proximityColor: Color {
        switch entry.proximity {
        case "Imediato": .green
        case "Perto": .blue
        case "Longe": .orange
        case "Bluetooth": .purple
        default: .gray
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch entry.discoverySource {
        case "Service UUID":
            badgeText("SU", color: .purple)
        case "iBeacon":
            badgeText("iB", color: .indigo)
        case "Both":
            HStack(spacing: 2) {
                badgeText("SU", color: .purple)
                badgeText("iB", color: .indigo)
            }
        default:
            badgeText("N", color: .teal)
        }
    }

    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color)
            .cornerRadius(3)
    }
}
