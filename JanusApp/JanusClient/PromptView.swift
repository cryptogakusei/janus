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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                balanceBar

                if engine.disconnectedDuringRequest || engine.connectedProvider == nil {
                    disconnectedBanner
                }

                taskPicker

                promptInput

                submitButton

                if engine.requestState != .idle {
                    statusSection
                }

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
        .onChange(of: engine.connectedProvider == nil) { disconnected in
            // If provider disappears while on this screen and no active request,
            // pop back to discovery after a short delay
            if disconnected && engine.requestState != .waitingForQuote && engine.requestState != .waitingForResponse {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if engine.connectedProvider == nil {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var balanceBar: some View {
        let total = engine.sessionManager?.sessionGrant.maxCredits ?? 100
        let remaining = engine.sessionManager?.remainingCredits ?? 0
        let fraction = total > 0 ? Double(remaining) / Double(total) : 0

        return VStack(spacing: 6) {
            HStack {
                Image(systemName: "creditcard")
                Text("\(remaining) credits remaining")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(engine.sessionManager?.receipts.count ?? 0) receipts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                if engine.requestState == .waitingForQuote || engine.requestState == .waitingForResponse {
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
        case .waitingForQuote: return "Getting quote..."
        case .waitingForResponse: return "Processing..."
        }
    }

    private var canSubmit: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (engine.requestState == .idle || engine.requestState == .complete || engine.requestState == .error)
        && engine.canAffordRequest
        && engine.connectedProvider != nil
    }

    private var statusSection: some View {
        HStack {
            if let quote = engine.currentQuote {
                Label("\(quote.priceCredits) credits (\(quote.priceTier))", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(engine.requestState.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

        // Clear prompt on submit for quick next entry
        promptText = ""
    }
}
