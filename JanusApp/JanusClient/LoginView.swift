import SwiftUI

/// Login screen shown before the user can access provider discovery.
///
/// Supports Apple Sign-In (OAuth via Privy) and email OTP login.
/// After authentication, Privy creates/restores an embedded Ethereum wallet
/// which is used for Tempo voucher signing and on-chain payments.
struct LoginView: View {
    @ObservedObject var auth: PrivyAuthManager

    @State private var email = ""
    @State private var otpCode = ""
    @State private var showEmailFlow = false
    @State private var codeSent = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo / branding
            VStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                Text("Janus")
                    .font(.largeTitle.bold())
                Text("Local AI, peer-to-peer payments")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if auth.isLoading {
                ProgressView(auth.authStatus)
            } else if showEmailFlow {
                emailLoginSection
            } else {
                loginButtons
            }

            if !auth.authStatus.isEmpty && auth.authStatus != "Not logged in" && !auth.isLoading {
                Text(auth.authStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Subviews

    private var loginButtons: some View {
        VStack(spacing: 16) {
            // Apple Sign-In
            Button {
                Task { await auth.loginWithApple() }
            } label: {
                HStack {
                    Image(systemName: "apple.logo")
                    Text("Sign in with Apple")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)

            // Email option
            Button {
                showEmailFlow = true
            } label: {
                HStack {
                    Image(systemName: "envelope")
                    Text("Sign in with Email")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 32)
    }

    private var emailLoginSection: some View {
        VStack(spacing: 16) {
            if !codeSent {
                TextField("Email address", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)

                Button("Send Code") {
                    Task {
                        try? await auth.sendEmailCode(to: email)
                        codeSent = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text("Enter the code sent to \(email)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("6-digit code", text: $otpCode)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)

                Button("Verify") {
                    Task { await auth.loginWithEmailCode(otpCode, sentTo: email) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(otpCode.count < 6)
            }

            Button("Back") {
                showEmailFlow = false
                codeSent = false
                otpCode = ""
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 32)
    }
}
