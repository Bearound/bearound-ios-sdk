import BearoundSDK
import SwiftUI

struct RetryQueueView: View {
    @ObservedObject var viewModel: BeaconViewModel
    @State private var batches: [[Beacon]] = []
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Retry Queue")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("\(batches.count) batch\(batches.count == 1 ? "" : "es") pendente\(batches.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Button(action: refreshBatches) {
                        Label("Atualizar", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)

                    if batches.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.largeTitle)
                                .foregroundColor(.green)

                            Text("Fila vazia")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text("Todos os beacons foram sincronizados")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 40)
                    } else {
                        ForEach(batches.indices, id: \.self) { batchIndex in
                            let batch = batches[batchIndex]

                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                    Text("Batch #\(batchIndex + 1) — \(batch.count) beacon\(batch.count == 1 ? "" : "s")")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.red)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)

                                LazyVStack(spacing: 0) {
                                    ForEach(batch.indices, id: \.self) { beaconIndex in
                                        let beacon = batch[beaconIndex]
                                        BeaconRow(beacon: beacon)
                                            .padding(.horizontal)

                                        if beaconIndex < batch.count - 1 {
                                            Divider()
                                                .padding(.horizontal)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.05))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            refreshBatches()
        }
        .onChange(of: viewModel.retryBatchCount) { _ in
            refreshBatches()
        }
    }

    private func refreshBatches() {
        batches = BeAroundSDK.shared.pendingBatches
    }
}
