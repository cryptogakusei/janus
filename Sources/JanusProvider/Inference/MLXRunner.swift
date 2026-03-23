import Foundation
import MLXLMCommon
import MLXLLM
import JanusShared

/// Wraps mlx-swift-lm to load a model and run inference.
///
/// Uses ChatSession for stateless single-turn interactions.
/// Each request gets a fresh ChatSession to avoid carrying conversation history
/// between unrelated requests — this is a utility service, not a chatbot.
actor MLXRunner {

    private let modelID: String
    private var modelContainer: ModelContainer?

    init(modelID: String = "mlx-community/Qwen3-4B-4bit") {
        self.modelID = modelID
    }

    /// Load the model from Hugging Face Hub (downloads on first run, cached after).
    func loadModel(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        // loadModelContainer is a free function from MLXLMCommon.
        // Importing MLXLLM registers Qwen3 and other model types with the factory.
        let container = try await MLXLMCommon.loadModelContainer(
            id: modelID,
            progressHandler: progressHandler
        )
        self.modelContainer = container
    }

    /// Run a single inference request.
    ///
    /// Returns the generated text. The caller is responsible for pricing tier
    /// classification and payment verification — this layer only does inference.
    func generate(
        prompt: String,
        taskType: TaskType,
        maxOutputTokens: Int
    ) async throws -> String {
        guard let container = modelContainer else {
            throw MLXRunnerError.modelNotLoaded
        }

        let session = ChatSession(container)
        session.generateParameters.maxTokens = maxOutputTokens

        let systemPrompt = PromptTemplates.systemPrompt(for: taskType)
        let userPrompt = PromptTemplates.formatUserPrompt(prompt, taskType: taskType)

        // Set the system prompt as the first message, then send the user prompt
        let fullPrompt = "\(systemPrompt)\n\nUser: \(userPrompt)"
        let rawResponse = try await session.respond(to: fullPrompt)

        return Self.stripThinkingTags(rawResponse)
    }

    var isLoaded: Bool {
        modelContainer != nil
    }

    /// Strip Qwen3's <think>...</think> reasoning blocks from the output.
    /// The /no_think prompt flag should prevent these, but this is a safety net.
    private static func stripThinkingTags(_ text: String) -> String {
        var result = text
        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>") {
            guard thinkStart.lowerBound <= thinkEnd.lowerBound else { break }
            result.removeSubrange(thinkStart.lowerBound...thinkEnd.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MLXRunnerError: Error, LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model not loaded. Call loadModel() first."
        }
    }
}
