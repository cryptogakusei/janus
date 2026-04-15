import SwiftUI
import JanusShared

/// Main view: discovers providers, connects, then navigates to prompt entry.
struct DiscoveryView: View {
    @StateObject private var engine = ClientEngine()
    var switchToRelay: (() -> Void)?
    var switchToDual: (() -> Void)?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Janus")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    connectionModeBadge
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button(engine.isSearching ? "Stop" : "Scan") {
                            if engine.isSearching {
                                engine.stopSearching()
                            } else {
                                engine.startSearching()
                            }
                        }
                        settingsMenu
                    }
                }
            }
        }
    }

    // MARK: - Subviews

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

    private var connectionModeBadge: some View {
        Group {
            switch engine.connectionMode {
            case .direct:
                Text("Direct")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green)
                    .cornerRadius(4)
            case .relayed(let relayName):
                Text("via \(relayName)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue)
                    .cornerRadius(4)
            case .disconnected:
                EmptyView()
            }
        }
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

    private var settingsMenu: some View {
        Menu {
            if let mpcBrowser = engine.compositeRef?.mpcBrowser {
                Toggle("Force Relay Mode", isOn: Binding(
                    get: { mpcBrowser.forceRelayMode },
                    set: { mpcBrowser.forceRelayMode = $0 }
                ))
            }
            Divider()
            Button {
                engine.stopSearching()
                switchToRelay?()
            } label: {
                Label("Switch to Relay Mode", systemImage: "antenna.radiowaves.left.and.right")
            }
            Button {
                engine.stopSearching()
                switchToDual?()
            } label: {
                Label("Switch to Dual Mode", systemImage: "point.3.connected.trianglepath.dotted")
            }
        } label: {
            Image(systemName: "gearshape")
        }
    }

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
            Image(systemName: engine.connectionState == .connectionFailed
                  ? "wifi.exclamationmark" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(engine.connectionState == .connectionFailed ? .orange : .secondary)
            if engine.connectionState == .connectionFailed {
                Text("Direct connection failed")
                    .font(.headline)
                Text("Searching for nearby relays...\nWiFi must be enabled on both devices.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(engine.isSearching ? "Searching for providers..." : "Tap Scan to find nearby providers")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }

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

            Divider()

            Text("Tasks")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(provider.supportedTasks, id: \.self) { task in
                    Text(task.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1))
                        .cornerRadius(8)
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
            Text(label)
                .foregroundStyle(.secondary)
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
}
