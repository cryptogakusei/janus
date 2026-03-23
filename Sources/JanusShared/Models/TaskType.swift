import Foundation

/// The three supported inference task types for v1.
public enum TaskType: String, Codable, Sendable, CaseIterable {
    case translate
    case rewrite
    case summarize
}
