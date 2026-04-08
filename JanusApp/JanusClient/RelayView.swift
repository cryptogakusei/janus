import SwiftUI
import JanusShared

/// Relay mode UI — shows relay status, connected providers and clients, forwarded count.
struct RelayView: View {
    @StateObject private var relay = MPCRelay()
    var switchToClient: (() -> Void)?
    var switchToDual: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusSection
                statsSection
                providersSection
                clientsSection
                Spacer()
                controlsSection
            }
            .padding()
            .navigationTitle("Janus Relay")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            relay.stop()
                            switchToClient?()
                        } label: {
                            Label("Client Only", systemImage: "iphone")
                        }
                        Button {
                            relay.stop()
                            switchToDual?()
                        } label: {
                            Label("Dual Mode", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(relay.isRunning ? .green : .gray)
                .frame(width: 10, height: 10)
            Text(relay.isRunning ? "Relaying" : "Stopped")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if relay.isRunning && relay.reachableProviders.isEmpty {
                Text("Searching for providers...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 0) {
            statItem(value: "\(relay.reachableProviders.count)", label: "Providers")
            Divider().frame(height: 28)
            statItem(value: "\(relay.connectedClients.count)", label: "Clients")
            Divider().frame(height: 28)
            statItem(value: "\(relay.forwardedCount)", label: "Forwarded")
        }
        .padding(.vertical, 10)
        .background(.gray.opacity(0.05))
        .cornerRadius(10)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Providers")
                .font(.headline)

            if relay.reachableProviders.isEmpty {
                Text("No providers found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(relay.reachableProviders.values), id: \.providerID) { provider in
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.providerName)
                                .font(.subheadline.weight(.medium))
                            Text(provider.providerID.prefix(12) + "...")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(provider.modelTier)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Clients

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clients")
                .font(.headline)

            if relay.connectedClients.isEmpty {
                Text("No clients connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(relay.connectedClients.values), id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .foregroundStyle(.blue)
                        Text(name)
                            .font(.subheadline)
                        Spacer()
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Button(relay.isRunning ? "Stop Relay" : "Start Relay") {
            if relay.isRunning {
                relay.stop()
            } else {
                relay.start()
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(relay.isRunning ? .red : .blue)
    }
}
