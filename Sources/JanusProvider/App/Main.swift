import Foundation
import JanusShared

/// Janus Provider — M1 CLI
///
/// Loads the MLX model and runs an interactive prompt loop.
/// Usage: janus-provider [--model <model-id>]
@main
struct ProviderCLI {
    static func main() async throws {
        let modelID = parseModelID()

        print("=== Janus Provider (M1) ===")
        print("Model: \(modelID)")
        print("Loading model...")

        let runner = MLXRunner(modelID: modelID)

        try await runner.loadModel { progress in
            let pct = Int(progress.fractionCompleted * 100)
            print("\rDownloading: \(pct)%", terminator: "")
            fflush(stdout)
        }
        print("\nModel loaded.\n")

        print("Available tasks: translate, rewrite, summarize")
        print("Type 'quit' to exit.\n")

        let maxOutputTokens = 1024

        while true {
            // Get task type
            print("Task (translate/rewrite/summarize): ", terminator: "")
            fflush(stdout)
            guard let taskInput = readLine()?.trimmingCharacters(in: .whitespaces),
                  !taskInput.isEmpty else { continue }

            if taskInput.lowercased() == "quit" { break }

            guard let taskType = TaskType(rawValue: taskInput.lowercased()) else {
                print("Unknown task. Use: translate, rewrite, summarize\n")
                continue
            }

            // Get prompt
            print("Prompt: ", terminator: "")
            fflush(stdout)
            guard let prompt = readLine()?.trimmingCharacters(in: .whitespaces),
                  !prompt.isEmpty else { continue }

            // Run inference
            print("Generating...\n")
            let startTime = Date()

            do {
                let result = try await runner.generate(
                    prompt: prompt,
                    taskType: taskType,
                    maxOutputTokens: maxOutputTokens
                )

                let elapsed = Date().timeIntervalSince(startTime)
                print("--- Response ---")
                print(result.outputText)
                print("--- End ---")
                print(String(format: "Time: %.1fs | Tokens: %d\n",
                             elapsed, result.outputTokenCount))
            } catch {
                print("Inference error: \(error.localizedDescription)\n")
            }
        }

        print("Goodbye.")
    }

    /// Parse --model flag from command line arguments, default to Qwen3-4B-4bit.
    private static func parseModelID() -> String {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
            return args[idx + 1]
        }
        return "mlx-community/Qwen3-4B-4bit"
    }
}
