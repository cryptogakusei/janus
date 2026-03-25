import SwiftUI

@main
struct JanusClientApp: App {
    @StateObject private var auth = PrivyAuthManager()

    var body: some Scene {
        WindowGroup {
            if auth.isAuthenticated {
                DiscoveryView(auth: auth)
            } else {
                LoginView(auth: auth)
            }
        }
    }
}
