import JanusShared

/// Builds system prompts for each task type.
///
/// These wrap the user's raw input into an instruction the model can follow reliably.
/// Designed for short, focused utility tasks — not open-ended chat.
enum PromptTemplates {

    static func systemPrompt(for taskType: TaskType) -> String {
        // /no_think disables Qwen3's chain-of-thought reasoning mode.
        // This gives faster, shorter responses — ideal for utility tasks.
        let base: String
        switch taskType {
        case .translate:
            base = """
            You are a translation assistant. Translate the user's text into the requested \
            target language. Output only the translation, nothing else.
            """
        case .rewrite:
            base = """
            You are a rewriting assistant. Rewrite the user's text according to their \
            instructions (e.g. more professional, simpler, more formal). Output only the \
            rewritten text, nothing else.
            """
        case .summarize:
            base = """
            You are a summarization assistant. Summarize the user's text concisely. \
            Output only the summary, nothing else.
            """
        }
        return "/no_think\n\(base)"
    }

    /// Formats the user's raw prompt text into a complete message for the model.
    ///
    /// For translate tasks, the user prompt should include the target language,
    /// e.g. "Translate into Spanish: Hello, how are you?"
    static func formatUserPrompt(_ text: String, taskType: TaskType) -> String {
        switch taskType {
        case .translate:
            return text
        case .rewrite:
            return text
        case .summarize:
            return "Summarize the following:\n\n\(text)"
        }
    }
}
