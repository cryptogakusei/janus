import Foundation
import PrivySDK
import JanusShared

/// Manages Privy authentication and embedded wallet lifecycle.
///
/// Handles: initialization, Apple/email login, wallet creation/restoration,
/// and provides a `WalletProvider` for voucher signing and transaction sending.
@MainActor
class PrivyAuthManager: ObservableObject {

    @Published var isAuthenticated = false
    @Published var walletAddress: String?
    @Published var authStatus: String = "Not logged in"
    @Published var isLoading = false

    private var privy: (any Privy)?
    /// Keep a reference to the current user for logout etc.
    private var currentUser: (any PrivyUser)?

    /// The embedded wallet provider, available after login + wallet creation.
    private(set) var walletProvider: PrivyWalletProvider?

    static let appId = "cmn6gi9wi01050ci511svlp7g"
    static let clientId = "client-WY6Xc1bNA13qCuLnc1oZkvy2TCVy1m1cooV8ujyL5bSAw"

    init() {
        let config = PrivyConfig(
            appId: Self.appId,
            appClientId: Self.clientId
        )
        self.privy = PrivySdk.initialize(config: config)
        Task { await checkExistingSession() }
    }

    /// Check if the user already has an active Privy session (app restart case).
    private func checkExistingSession() async {
        guard let privy else { return }
        let state = await privy.getAuthState()
        switch state {
        case .authenticated(let user):
            currentUser = user
            await setupWallet(for: user)
        case .notReady, .unauthenticated, .authenticatedUnverified:
            authStatus = "Not logged in"
        @unknown default:
            authStatus = "Not logged in"
        }
    }

    /// Login with Apple Sign-In (via Privy OAuth).
    func loginWithApple() async {
        guard let privy else { return }
        isLoading = true
        authStatus = "Signing in with Apple..."

        do {
            let user = try await privy.oAuth.login(with: .apple)
            currentUser = user
            await setupWallet(for: user)
        } catch {
            authStatus = "Login failed: \(error.localizedDescription)"
            print("Privy Apple login failed: \(error)")
        }
        isLoading = false
    }

    /// Login with email OTP.
    func sendEmailCode(to email: String) async throws {
        guard let privy else { return }
        try await privy.email.sendCode(to: email)
        authStatus = "Code sent to \(email)"
    }

    func loginWithEmailCode(_ code: String, sentTo email: String) async {
        guard let privy else { return }
        isLoading = true
        authStatus = "Verifying code..."

        do {
            let user = try await privy.email.loginWithCode(code, sentTo: email)
            currentUser = user
            await setupWallet(for: user)
        } catch {
            authStatus = "Login failed: \(error.localizedDescription)"
            print("Privy email login failed: \(error)")
        }
        isLoading = false
    }

    /// Logout and clear wallet state.
    func logout() async {
        await currentUser?.logout()
        currentUser = nil
        isAuthenticated = false
        walletAddress = nil
        walletProvider = nil
        authStatus = "Not logged in"
    }

    // MARK: - Wallet Setup

    /// After authentication, ensure an embedded Ethereum wallet exists.
    private func setupWallet(for user: any PrivyUser) async {
        isAuthenticated = true

        let wallets = user.embeddedEthereumWallets
        if let wallet = wallets.first {
            configureProvider(wallet: wallet)
            authStatus = "Logged in"
        } else {
            authStatus = "Creating wallet..."
            do {
                let wallet = try await user.createEthereumWallet()
                configureProvider(wallet: wallet)
                authStatus = "Logged in"
            } catch {
                authStatus = "Wallet creation failed: \(error.localizedDescription)"
                print("Privy wallet creation failed: \(error)")
            }
        }
    }

    private func configureProvider(wallet: any EmbeddedEthereumWallet) {
        walletAddress = wallet.address
        walletProvider = PrivyWalletProvider(wallet: wallet)
        print("Privy wallet ready: \(wallet.address)")
    }
}
