import SwiftUI
import JanusShared

/// Main prompt entry and response display view.
///
/// Shown after connecting to a provider. Lets the user select a task type,
/// enter a prompt, submit it, and see the inference result with history.
struct PromptView: View {
    @ObservedObject var engine: ClientEngine
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTask: TaskType = .translate
    @State private var promptText = ""
    @State private var targetLanguage = "Spanish"
    @State private var rewriteStyle = "professional"
    @State private var showHistory = false
    @State private var showTopUp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                balanceBar

                if engine.sessionManager?.spendState.cumulativeSpend ?? 0 > 0 {
                    settlementSection
                }

                if engine.requestState == .awaitingSettlement {
                    settlementPendingBanner
                } else if engine.disconnectedDuringRequest {
                    disconnectedBanner
                } else if !engine.sessionReady {
                    reconnectingBanner
                } else if !engine.channelStatus.isEmpty {
                    channelStatusBanner
                }

                taskPicker

                promptInput

                submitButton

                statusSection

                if let result = engine.lastResult {
                    resultCard(result)
                }

                if let error = engine.errorMessage, engine.requestState == .error {
                    errorCard(error)
                }

                if !engine.responseHistory.isEmpty {
                    historySection
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showTopUp) {
            TopUpSheet(engine: engine, isPresented: $showTopUp)
        }
    }

    // MARK: - Subviews

    private var balanceBar: some View {
        let total = engine.sessionManager?.totalDeposit ?? 100
        let remaining = engine.sessionManager?.remainingCredits ?? 0
        let fraction = total > 0 ? Double(remaining) / Double(total) : 0

        return VStack(spacing: 6) {
            HStack {
                Image(systemName: "creditcard")
                Text("\(remaining) credits remaining")
                    .font(.subheadline.bold())
                Spacer()
                Button("Top Up") { showTopUp = true }
                    .font(.caption.bold())
                    .disabled(engine.isWaitingForResponse || !engine.sessionReady)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.gray.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(fraction > 0.2 ? .blue : .red)
                        .frame(width: geo.size.width * fraction, height: 6)
                }
            }
            .frame(height: 6)

            if !engine.canAffordRequest {
                Text("Insufficient credits for any request")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.08))
        .cornerRadius(10)
    }

    private var disconnectedBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text("Provider disconnected")
                .font(.subheadline)
            Spacer()
            Button("Back") { dismiss() }
                .font(.subheadline.bold())
        }
        .padding()
        .background(.orange.opacity(0.15))
        .cornerRadius(10)
    }

    private var reconnectingBanner: some View {
        VStack(spacing: 6) {
            HStack {
                if engine.connectedProvider != nil {
                    let isFailed = engine.channelStatus.contains("failed")
                    if isFailed {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isFailed ? "Channel setup failed" : "Setting up payment channel...")
                            .font(.subheadline)
                        if !engine.channelStatus.isEmpty {
                            Text(engine.channelStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isFailed {
                        Button("Retry") {
                            engine.sessionManager?.retryChannelOpenIfNeeded()
                        }
                        .font(.subheadline.bold())
                    }
                } else {
                    Image(systemName: "wifi.slash")
                    Text("Reconnecting to provider...")
                        .font(.subheadline)
                    Spacer()
                    Button("Back") { dismiss() }
                        .font(.subheadline.bold())
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.15))
        .cornerRadius(10)
    }

    private var channelStatusBanner: some View {
        let status = engine.channelStatus
        let isComplete = status.hasPrefix("Top-up complete")
            || status.hasPrefix("Channel already open")
            || status.hasPrefix("Channel open on-chain")
        let isFailed = status.contains("failed") || status.contains("Failed")
        let isInProgress = !isComplete && !isFailed
        return HStack(spacing: 8) {
            if isFailed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isInProgress {
                ProgressView().scaleEffect(0.7)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(isFailed ? .red : isComplete ? .green : .primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isFailed ? .red.opacity(0.08) : isComplete ? .green.opacity(0.08) : .blue.opacity(0.08))
        .cornerRadius(10)
    }

    private var taskPicker: some View {
        Picker("Task", selection: $selectedTask) {
            ForEach(TaskType.allCases, id: \.self) { task in
                Text(task.rawValue.capitalized).tag(task)
            }
        }
        .pickerStyle(.segmented)
    }

    private var promptInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedTask == .translate {
                HStack {
                    Text("Target language:")
                        .font(.subheadline)
                    TextField("Language", text: $targetLanguage)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if selectedTask == .rewrite {
                HStack {
                    Text("Style:")
                        .font(.subheadline)
                    Picker("Style", selection: $rewriteStyle) {
                        Text("Professional").tag("professional")
                        Text("Simple").tag("simple")
                        Text("Formal").tag("formal")
                    }
                    .pickerStyle(.segmented)
                }
            }

            TextField("Enter your text...", text: $promptText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
        }
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack {
                if engine.requestState == .waitingForResponse || engine.requestState == .awaitingSettlement {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Text(buttonLabel)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
    }

    private var buttonLabel: String {
        switch engine.requestState {
        case .idle, .complete, .error: return "Submit"
        case .waitingForResponse: return "Processing..."
        case .awaitingSettlement: return "Settling tab..."
        }
    }

    private var canSubmit: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (engine.requestState == .idle || engine.requestState == .complete || engine.requestState == .error)
        && engine.canAffordRequest
        && engine.sessionReady
    }

    private var statusSection: some View {
        HStack {
            if let session = engine.sessionManager, session.tabThreshold > 0 {
                Label("Tab: \(session.currentTabTokens) / \(session.tabThreshold) tokens",
                      systemImage: "chart.bar.fill")
                    .font(.caption)
                    .foregroundStyle(session.currentTabTokens >= session.tabThreshold * 9 / 10 ? .orange : .secondary)
            }
            Spacer()
            Text(engine.requestState.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var settlementPendingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settling tab payment...")
                    .font(.subheadline.bold())
                if let req = engine.pendingSettlement {
                    Text("\(req.tabCredits) credits owed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .cornerRadius(10)
    }

    private func resultCard(_ result: InferenceResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Response")
                    .font(.headline)
                Spacer()
                Text("-\(result.creditsCharged) credits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(result.outputText)
                .font(.body)
                .textSelection(.enabled)

            Divider()

            HStack {
                Image(systemName: "doc.text")
                Text("Receipt: \(result.receipt.receiptID.prefix(8))...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 1)
    }

    private func errorCard(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Dismiss") {
                engine.errorMessage = nil
                engine.requestState = .idle
            }
            .font(.caption.bold())
        }
        .padding()
        .background(.red.opacity(0.1))
        .cornerRadius(10)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showHistory.toggle() }
            } label: {
                HStack {
                    Text("History (\(engine.responseHistory.count))")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showHistory ? "chevron.up" : "chevron.down")
                }
                .foregroundStyle(.primary)
            }

            if showHistory {
                ForEach(Array(engine.responseHistory.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.task.rawValue.capitalized)
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1))
                                .cornerRadius(4)
                            Spacer()
                            Text("-\(entry.response.creditsCharged)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.prompt.prefix(80) + (entry.prompt.count > 80 ? "..." : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.response.outputText)
                            .font(.caption)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(.gray.opacity(0.06))
                    .cornerRadius(8)
                }
            }
        }
    }

    private var settlementSection: some View {
        let spent = engine.sessionManager?.spendState.cumulativeSpend ?? 0
        let status = engine.settlementStatus

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.shield")
                Text("Settlement")
                    .font(.subheadline.bold())
                Spacer()
                settlementBadge(status)
            }
            HStack {
                Text("\(spent) credits spent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .unverified = status {
                    // not yet verified
                } else {
                    Text("\(status.settled) settled on-chain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if case .match = status {
                // fully verified — no button needed
            } else {
                Button(status == .unverified ? "Verify On-Chain" : "Re-verify") {
                    engine.verifySettlement()
                }
                .font(.caption.bold())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(settlementBackground(status))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func settlementBadge(_ status: SettlementStatus) -> some View {
        switch status {
        case .match:
            Text("Verified")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.1))
                .cornerRadius(4)
        case .overpayment:
            Text("Overpayment")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.1))
                .cornerRadius(4)
        case .underpayment:
            Text("Partial")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.1))
                .cornerRadius(4)
        case .unverified:
            EmptyView()
        }
    }

    private func settlementBackground(_ status: SettlementStatus) -> Color {
        switch status {
        case .match: return .green.opacity(0.05)
        case .overpayment: return .red.opacity(0.05)
        case .underpayment: return .orange.opacity(0.05)
        case .unverified: return .gray.opacity(0.05)
        }
    }

    // MARK: - Top Up sheet

    // MARK: - Actions

    private func submit() {
        let params: PromptRequest.Parameters
        var fullPrompt = promptText

        switch selectedTask {
        case .translate:
            params = PromptRequest.Parameters(targetLanguage: targetLanguage)
            fullPrompt = "Translate into \(targetLanguage): \(promptText)"
        case .rewrite:
            params = PromptRequest.Parameters(style: rewriteStyle)
            fullPrompt = "Rewrite this \(rewriteStyle)ly: \(promptText)"
        case .summarize:
            params = PromptRequest.Parameters()
        }

        engine.submitRequest(taskType: selectedTask, promptText: fullPrompt, parameters: params)

        // Clear prompt on submit for quick next entry (preserve if guard rejected)
        if engine.requestState != .error {
            promptText = ""
        }
    }
}

// MARK: - Top Up sheet

private struct TopUpSheet: View {
    let engine: ClientEngine
    @Binding var isPresented: Bool
    @State private var selectedAmount: UInt64 = 50

    private let tiers: [(label: String, amount: UInt64)] = [
        ("+50 credits", 50),
        ("+100 credits", 100),
        ("+200 credits", 200),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Select amount to add")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    ForEach(tiers, id: \.amount) { tier in
                        Button {
                            selectedAmount = tier.amount
                        } label: {
                            HStack {
                                Text(tier.label)
                                    .font(.body.bold())
                                Spacer()
                                if selectedAmount == tier.amount {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding()
                            .background(selectedAmount == tier.amount ? .blue.opacity(0.1) : .gray.opacity(0.07))
                            .cornerRadius(10)
                        }
                        .foregroundStyle(.primary)
                    }
                }

                if !engine.channelStatus.isEmpty {
                    Text(engine.channelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    engine.topUpChannel(additionalDeposit: selectedAmount)
                    isPresented = false
                } label: {
                    Text("Confirm Top Up (+\(selectedAmount))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .navigationTitle("Top Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
