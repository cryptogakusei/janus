import SwiftUI

@main
struct JanusClientApp: App {
    @StateObject private var auth = PrivyAuthManager()
    @AppStorage("appMode") private var appMode: String = "client"

    /// Shared relay and engine for dual mode — created once, reused across mode switches.
    @StateObject private var dualRelay = MPCRelay()
    @State private var dualEngine: ClientEngine?

    var body: some Scene {
        WindowGroup {
            if auth.isAuthenticated {
                switch appMode {
                case "relay":
                    RelayView(switchToClient: { appMode = "client" },
                              switchToDual: { appMode = "dual" })
                case "dual":
                    dualModeRoot
                default:
                    DiscoveryView(auth: auth,
                                  switchToRelay: { appMode = "relay" },
                                  switchToDual: { appMode = "dual" })
                }
            } else {
                LoginView(auth: auth)
            }
        }
    }

    private var dualModeRoot: some View {
        Group {
            if let engine = dualEngine {
                DualModeView(
                    auth: auth,
                    relay: dualRelay,
                    engine: engine,
                    switchToClient: {
                        dualRelay.stop()
                        appMode = "client"
                    },
                    switchToRelay: { appMode = "relay" }
                )
            } else {
                ProgressView("Starting dual mode...")
                    .onAppear { setupDualMode() }
            }
        }
    }

    private func setupDualMode() {
        let transport = dualRelay.enableLocalClient()
        let engine = ClientEngine(transport: transport)
        dualEngine = engine
    }
}
