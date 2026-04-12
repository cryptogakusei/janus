import Foundation

/// Client → Provider: request inference on a prompt.
///
/// On first request for a session, the client includes the full `sessionGrant`
/// so the provider can verify and cache it.
public struct PromptRequest: Codable, Sendable {
    public let requestID: String
    public let sessionID: String
    public let taskType: TaskType
    public let promptText: String
    public let parameters: Parameters
    public let maxOutputTokens: Int?
    /// Included on first request so the provider can verify and cache the grant.
    public let sessionGrant: SessionGrant?
    /// Tempo channel info — included on first request for voucher-based sessions.
    public let channelInfo: ChannelInfo?
    /// Stable device identity (Ed25519 pubkey base64). Used by provider to group sessions from the same device.
    public let clientIdentity: String?

    public init(
        requestID: String = UUID().uuidString,
        sessionID: String,
        taskType: TaskType,
        promptText: String,
        parameters: Parameters = Parameters(),
        maxOutputTokens: Int? = nil,
        sessionGrant: SessionGrant? = nil,
        channelInfo: ChannelInfo? = nil,
        clientIdentity: String? = nil
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.taskType = taskType
        self.promptText = promptText
        self.parameters = parameters
        self.maxOutputTokens = maxOutputTokens
        self.sessionGrant = sessionGrant
        self.channelInfo = channelInfo
        self.clientIdentity = clientIdentity
    }

    public struct Parameters: Codable, Sendable {
        public let targetLanguage: String?
        public let style: String?

        public init(targetLanguage: String? = nil, style: String? = nil) {
            self.targetLanguage = targetLanguage
            self.style = style
        }
    }
}
