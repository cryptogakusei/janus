import Vapor
import JanusShared

@main
struct JanusBackendApp {
    static func main() async throws {
        let app = try await Application.make(.detect())

        // Use the same deterministic backend keypair as DemoConfig.
        // Grants signed by this server are verifiable by providers
        // using DemoConfig.backendPublicKeyBase64.
        let backendSigner = JanusSigner(privateKey: DemoConfig.backendPrivateKey)

        let sessionStore = InMemorySessionStore()
        let providerStore = InMemoryProviderStore()

        try routes(app, backendSigner: backendSigner, sessionStore: sessionStore, providerStore: providerStore)

        try await app.execute()
    }
}
