import Vapor
import JanusShared

// Extend JanusShared types with Vapor's Content protocol
// so they can be used directly in request/response bodies.
// Content = Codable + Sendable + RequestDecodable + ResponseEncodable
extension SessionGrant: @retroactive Content {}
extension Receipt: @retroactive Content {}
