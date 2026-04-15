import SwiftUI
import JanusShared

/// Dual mode UI — phone simultaneously relays for other clients AND acts as a client itself.
///
/// Layout: compact relay stats bar at top, full client UI below.
struct DualModeView: View {
    @ObservedObject private var relay: MPCRelay
    @ObservedObject private var engine: ClientEngine
    var switchToClient: (() -> Void)?
    var switchToRelay: (() -> Void)?

    init(relay: MPCRelay, engine: ClientEngine,
         switchToClient: (() -> Void)? = nil, switchToRelay: (() -> Void)? = nil) {
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
                    dualModeBadge
                }
                ToolbarItem(placement: .primaryAction) {
                    settingsMenu
                }
            }
        }
        .onAppear {
            if !relay.isRunning {
                relay.start()
            }
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
                if engine.availableProviders.count > 1 {
                    providerPicker
                }
                providerInfoCard(provider)

                if engine.sessionReady {
                    NavigationLink {
                        PromptView(engine: engine)
                            .navigationTitle("Janus")
                    } label: {
                        Text("Start Using Provider")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    channelOpeningBanner
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

    private var channelOpeningBanner: some View {
        let isFailed = engine.channelStatus.contains("failed")
        return HStack(spacing: 10) {
            if isFailed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                ProgressView().scaleEffect(0.8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isFailed ? "Channel setup failed" : "Opening payment channel...")
                    .font(.subheadline.bold())
                if !engine.channelStatus.isEmpty {
                    Text(engine.channelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isFailed {
                Button("Retry") { engine.sessionManager?.retryChannelOpenIfNeeded() }
                    .font(.caption.bold())
            }
        }
        .padding(12)
        .background(.blue.opacity(0.08))
        .cornerRadius(10)
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

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available Providers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(engine.availableProviders.sorted(by: { $0.providerName < $1.providerName }), id: \.providerID) { provider in
                        let isSelected = provider.providerID == engine.connectedProvider?.providerID
                        Button {
                            engine.selectProvider(provider.providerID)
                        } label: {
                            VStack(spacing: 2) {
                                Text(provider.providerName)
                                    .font(.caption.bold())
                                Text(provider.modelTier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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

            if provider.paymentModel == "tab" {
                Text("Pricing (Pay-Per-Token)")
                    .font(.headline)
                infoRow("Rate", "\(provider.tokenRate * 1000) credits / M tokens")
                infoRow("Tab threshold", "\(provider.tabThreshold) tokens")
                infoRow("Max output", "\(provider.maxOutputTokens) tokens")
            } else if let pricing = provider.pricing {
                Text("Pricing")
                    .font(.headline)
                HStack(spacing: 16) {
                    priceBadge("Small", pricing.small)
                    priceBadge("Medium", pricing.medium)
                    priceBadge("Large", pricing.large)
                }
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
