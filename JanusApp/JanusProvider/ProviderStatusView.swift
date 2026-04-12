import SwiftUI
import JanusShared

/// Mac provider status UI — shows model state, connection, per-client details, and request log.
struct ProviderStatusView: View {
    // Stable provider ID — try to restore from persisted state, else generate new
    private static let sharedProviderID: String = {
        if let persisted = JanusStore.appDefault.load(PersistedProviderState.self, from: "provider_state.json") {
            return persisted.providerID
        }
        return "prov_\(UUID().uuidString.prefix(8))"
    }()

    @StateObject private var engine = ProviderEngine(providerID: sharedProviderID)
    @StateObject private var advertiser = CompositeAdvertiser(
        providerName: Host.current().localizedName ?? "Janus Provider",
        providerID: sharedProviderID
    )

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    statusStrip
                    statsStrip
                    clientsSection
                    allLogsSection
                }
                .padding(24)
            }

            Spacer(minLength: 0)
            controlsBar
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .frame(minWidth: 520, minHeight: 620)
        .onAppear {
            advertiser.onMessageReceived = { [weak engine] envelope, _ in
                engine?.handleMessage(envelope)
            }
            engine.sendMessage = { [weak advertiser] envelope, senderID in
                try? advertiser?.send(envelope, to: senderID)
            }
            advertiser.onClientDisconnected = { [weak engine] clientName in
                print("Client disconnected: \(clientName), settling sessions...")
                Task { await engine?.settleAllSessions() }
            }
            advertiser.updateServiceAnnounce(
                providerPubkey: engine.providerPubkeyBase64,
                providerEthAddress: engine.providerEthKeyPair?.address.checksumAddress
            )
            advertiser.startAdvertising()
            Task { await engine.loadModel() }
            Task { await engine.fundProviderIfNeeded() }
            engine.startNetworkMonitor()
            Task { await engine.retryPendingSettlements() }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Janus Provider")
                    .font(.title3.bold())
                Text(Host.current().localizedName ?? "Local Machine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v1 Demo")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.gray.opacity(0.1))
                .cornerRadius(4)
        }
    }

    // MARK: - Status indicators

    private var statusStrip: some View {
        HStack(spacing: 12) {
            statusPill(
                icon: "circle.fill",
                color: modelColor,
                label: engine.modelStatus.rawValue
            )
            statusPill(
                icon: "antenna.radiowaves.left.and.right",
                color: advertiser.isAdvertising ? .green : .red,
                label: advertiser.isAdvertising ? "Advertising" : "Stopped"
            )
            statusPill(
                icon: "link",
                color: engine.activeSessionCount > 0 ? .green : .gray,
                label: engine.activeSessionCount > 0 ? "Active" : "Idle"
            )
            if engine.isSettling {
                statusPill(icon: "arrow.triangle.2.circlepath", color: .orange, label: "Settling...")
            } else if engine.pendingSettlementCredits > 0 {
                statusPill(icon: "clock.arrow.circlepath", color: .orange, label: "Pending")
            }
        }
    }

    private func statusPill(icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 7))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
        .cornerRadius(12)
    }

    private var modelColor: Color {
        switch engine.modelStatus {
        case .notLoaded: return .gray
        case .loading: return .yellow
        case .ready: return .green
        case .error: return .red
        }
    }

    // MARK: - Stats

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statItem(value: "\(engine.totalRequestsServed)", label: "Served")
            Divider().frame(height: 28)
            statItem(value: "\(engine.totalCreditsEarned)", label: "Credits Earned")
            Divider().frame(height: 28)
            statItem(value: "\(advertiser.connectedClients.count)", label: "Connected")
            Divider().frame(height: 28)
            statItem(value: "\(engine.activeSessionCount)", label: "Sessions")
            Divider().frame(height: 28)
            statItem(
                value: "\(engine.pendingSettlementCredits)",
                label: "Pending",
                valueColor: engine.pendingSettlementCredits > 0 ? .orange : .secondary
            )
        }
        .padding(.vertical, 10)
        .background(.gray.opacity(0.05))
        .cornerRadius(10)
    }

    private func statItem(value: String, label: String, valueColor: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(valueColor)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Clients section

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clients")
                .font(.headline)

            if engine.clientSummaries.isEmpty && advertiser.connectedClients.isEmpty {
                Text("No clients yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                // Side-by-side grid: 2 cards per row
                let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(engine.clientSummaries) { client in
                        clientCard(client)
                    }
                }
            }
        }
    }

    private func clientCard(_ client: ProviderEngine.ClientSummary) -> some View {
        let deviceName = advertiser.displayName(forSenderIDs: client.senderIDs)
        let shortID = String(client.id.suffix(6))
        let name = deviceName.map { "\($0) (\(shortID))" } ?? "Client \(shortID)"
        let connected = advertiser.isConnected(senderIDs: client.senderIDs)
        let remaining = client.maxCredits - client.totalCreditsUsed

        return VStack(alignment: .leading, spacing: 5) {
            // Name + dot
            HStack(spacing: 5) {
                Circle()
                    .fill(connected ? .green : .gray.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            // 4 stat rows — label left, number right
            statRow("Credits used", value: "\(client.totalCreditsUsed)")
            statRow("Remaining", value: "\(remaining)")
            statRow("Sessions", value: "\(client.sessionIDs.count)")
            statRow("Requests", value: "\(client.requestCount)")

            // Expandable log
            if !client.logs.isEmpty {
                ClientLogDropdown(logs: client.logs, logRowBuilder: logRow)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.gray.opacity(0.1), lineWidth: 1)
        )
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
    }

    // MARK: - All logs section


    private var allLogsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All Activity")
                    .font(.headline)
                Spacer()
                if !engine.requestLog.isEmpty {
                    Text("\(engine.requestLog.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if engine.requestLog.isEmpty {
                Text("No activity yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(engine.requestLog.prefix(20)) { entry in
                    logRow(entry)
                }
                if engine.requestLog.count > 20 {
                    Text("Showing 20 of \(engine.requestLog.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private func logRow(_ entry: ProviderEngine.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(entry.isError ? .red : .green)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.taskType.capitalized)
                        .font(.caption.bold())
                    Spacer()
                    if let credits = entry.credits {
                        Text("+\(credits)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                    Text(entry.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(entry.promptPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let resp = entry.responsePreview {
                    Text(resp)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Controls

    private var controlsBar: some View {
        HStack {
            Button(advertiser.isAdvertising ? "Stop" : "Start") {
                if advertiser.isAdvertising {
                    advertiser.stopAdvertising()
                } else {
                    advertiser.startAdvertising()
                }
            }
            .buttonStyle(.borderedProminent)

            if engine.modelStatus != .ready && engine.modelStatus != .loading {
                Button("Load Model") {
                    Task { await engine.loadModel() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Expandable log dropdown (needs own @State)

/// A tappable "Recent Requests" row that expands to show log entries inside a client card.
private struct ClientLogDropdown: View {
    let logs: [ProviderEngine.LogEntry]
    let logRowBuilder: (ProviderEngine.LogEntry) -> AnyView

    @State private var isExpanded = false

    init(logs: [ProviderEngine.LogEntry],
         logRowBuilder: @escaping (ProviderEngine.LogEntry) -> some View) {
        self.logs = logs
        self.logRowBuilder = { AnyView(logRowBuilder($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tap target
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Recent Requests")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(logs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.gray.opacity(0.1))
                        .cornerRadius(4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if isExpanded {
                Divider()
                    .padding(.vertical, 4)

                ForEach(logs.prefix(8)) { entry in
                    logRowBuilder(entry)
                }

                if logs.count > 8 {
                    Text("+ \(logs.count - 8) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
            }
        }
    }
}
