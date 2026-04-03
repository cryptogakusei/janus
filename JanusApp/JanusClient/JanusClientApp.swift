import SwiftUI

@main
struct JanusClientApp: App {
    @StateObject private var auth = PrivyAuthManager()
    @AppStorage("appMode") private var appMode: String = "client"

    var body: some Scene {
        WindowGroup {
            if auth.isAuthenticated {
                if appMode == "relay" {
                    relayRoot
                } else {
                    DiscoveryView(auth: auth, switchToRelay: { appMode = "relay" })
                }
            } else {
                LoginView(auth: auth)
            }
        }
    }

    private var relayRoot: some View {
        RelayView(switchToClient: { appMode = "client" })
    }
}
