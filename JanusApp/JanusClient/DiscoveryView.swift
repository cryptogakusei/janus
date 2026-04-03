import SwiftUI
import JanusShared

/// Main view: discovers providers, connects, then navigates to prompt entry.
struct DiscoveryView: View {
    @ObservedObject var auth: PrivyAuthManager
    @StateObject private var engine = ClientEngine()
    var switchToRelay: (() -> Void)?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Janus")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 8) {
                        walletBadge
                        connectionModeBadge
                    }
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
        .onAppear {
            // Inject wallet provider from Privy auth into the engine
            engine.walletProvider = auth.walletProvider
        }
        .onChange(of: auth.walletProvider != nil) { _ in
            engine.walletProvider = auth.walletProvider
        }
    }

    // MARK: - Subviews

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

    private var connectionModeBadge: some View {
        Group {
            switch engine.browser.connectionMode {
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

    private var settingsMenu: some View {
        Menu {
            Toggle("Force Relay Mode", isOn: Binding(
                get: { engine.browser.forceRelayMode },
                set: { engine.browser.forceRelayMode = $0 }
            ))
            Divider()
            Button {
                engine.stopSearching()
                switchToRelay?()
            } label: {
                Label("Switch to Relay Mode", systemImage: "antenna.radiowaves.left.and.right")
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
        switch engine.browser.connectionState {
        case .disconnected: return .red
        case .connecting: return .yellow
        case .connected: return .green
        case .connectionFailed: return .orange
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: engine.browser.connectionState == .connectionFailed
                  ? "wifi.exclamationmark" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(engine.browser.connectionState == .connectionFailed ? .orange : .secondary)
            if engine.browser.connectionState == .connectionFailed {
                Text("Provider found but can't connect")
                    .font(.headline)
                Text("WiFi must be enabled on both devices.\nInternet is not required — just the WiFi radio.")
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

            Text("Pricing")
                .font(.headline)
            HStack(spacing: 16) {
                priceBadge("Small", provider.pricing.small)
                priceBadge("Medium", provider.pricing.medium)
                priceBadge("Large", provider.pricing.large)
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
