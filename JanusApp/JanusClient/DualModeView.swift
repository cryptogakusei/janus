import SwiftUI
import JanusShared

/// Dual mode UI — phone simultaneously relays for other clients AND acts as a client itself.
///
/// Layout: compact relay stats bar at top, full client UI below.
struct DualModeView: View {
    @ObservedObject var auth: PrivyAuthManager
    @ObservedObject private var relay: MPCRelay
    @ObservedObject private var engine: ClientEngine
    var switchToClient: (() -> Void)?
    var switchToRelay: (() -> Void)?

    init(auth: PrivyAuthManager, relay: MPCRelay, engine: ClientEngine,
         switchToClient: (() -> Void)? = nil, switchToRelay: (() -> Void)? = nil) {
        self.auth = auth
        self.relay = relay
        self.engine = engine
        self.switchToClient = switchToClient
        self.switchToRelay = switchToRelay
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                relayStatsBar
                Divider()
                clientSection
            }
            .navigationTitle("Janus Dual")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 8) {
                        walletBadge
                        dualModeBadge
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    settingsMenu
                }
            }
        }
        .onAppear {
            engine.walletProvider = auth.walletProvider
            if !relay.isRunning {
                relay.start()
            }
        }
        .onChange(of: auth.walletProvider != nil) { _ in
            engine.walletProvider = auth.walletProvider
        }
    }

    // MARK: - Relay stats bar

    private var relayStatsBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(relay.isRunning ? .green : .gray)
                Text("Relay")
                    .font(.caption.weight(.semibold))
            }

            Spacer()

            HStack(spacing: 12) {
                statBadge(systemImage: "desktopcomputer", value: relay.reachableProviders.count)
                statBadge(systemImage: "iphone", value: relay.connectedClients.count)
                statBadge(systemImage: "arrow.left.arrow.right", value: relay.forwardedCount)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.gray.opacity(0.05))
    }

    private func statBadge(systemImage: String, value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.bold().monospacedDigit())
        }
    }

    // MARK: - Client section

    private var clientSection: some View {
        VStack(spacing: 24) {
            connectionStatusView

            if let provider = engine.connectedProvider {
                providerInfoCard(provider)

                if engine.sessionReady {
                    NavigationLink {
                        PromptView(engine: engine)
                            .navigationTitle("Janus")
                    } label: {
                        Text("Start Using Provider")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                emptyStateView
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Status views

    private var connectionStatusView: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(engine.connectionStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch engine.connectionState {
        case .disconnected: return .red
        case .connecting: return .yellow
        case .connected: return .green
        case .connectionFailed: return .orange
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(relay.isRunning ? "Waiting for provider..." : "Starting relay...")
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Provider info (reused from DiscoveryView pattern)

    private func providerInfoCard(_ provider: ServiceAnnounce) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                Text(provider.providerName)
                    .font(.title2.bold())
            }

            Divider()

            infoRow("Model", provider.modelTier)
            infoRow("Status", provider.available ? "Available" : "Busy")

            Divider()

            Text("Pricing")
                .font(.headline)
            HStack(spacing: 16) {
                priceBadge("Small", provider.pricing.small)
                priceBadge("Medium", provider.pricing.medium)
                priceBadge("Large", provider.pricing.large)
            }

            if let credits = engine.sessionManager?.remainingCredits {
                Divider()
                infoRow("Session Credits", "\(credits)")
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 2)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func priceBadge(_ tier: String, _ credits: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(credits)")
                .font(.title3.bold())
            Text(tier)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.gray.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Toolbar items

    private var walletBadge: some View {
        Group {
            if let addr = auth.walletAddress {
                Menu {
                    Text(addr)
                    Button("Logout") {
                        Task { await auth.logout() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wallet.pass")
                        Text(String(addr.prefix(6)) + "..." + String(addr.suffix(4)))
                            .font(.caption.monospaced())
                    }
                }
            }
        }
    }

    private var dualModeBadge: some View {
        Text("Dual")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.purple)
            .cornerRadius(4)
    }

    private var settingsMenu: some View {
        Menu {
            Button {
                relay.stop()
                switchToClient?()
            } label: {
                Label("Client Only", systemImage: "iphone")
            }
            Button {
                switchToRelay?()
            } label: {
                Label("Relay Only", systemImage: "antenna.radiowaves.left.and.right")
            }
        } label: {
            Image(systemName: "gearshape")
        }
    }
}
