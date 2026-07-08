import SwiftUI
import UIKit
import AuthenticationServices

struct SignInView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                    Text("Sign in")
                        .font(.title.bold())
                    Text("We'll create your account and set up\nthe share extension automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                VStack(spacing: 16) {
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.email, .fullName]
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 52)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isLoading { ProgressView().scaleEffect(1.4) }
            }
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            switch (error as? ASAuthorizationError)?.code {
            case .canceled:
                break
            case .unknown:
                // Typical cause: build signed without the Sign in with Apple
                // entitlement (personal teams can't provision it).
                errorMessage = "Sign in with Apple isn't available in this build. "
                    + "It needs a paid Apple Developer team — use the dev skip on the welcome screen for now."
            default:
                errorMessage = error.localizedDescription
            }
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let jwt = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Sign-in failed. Please try again."
                return
            }
            isLoading = true
            Task {
                do {
                    let result = try await APIClient.shared.mintIngestToken(
                        appleJWT: jwt,
                        deviceLabel: UIDevice.current.name
                    )
                    appState.signIn(ingestToken: result.token, onboarded: result.onboarded)
                    dismiss()
                } catch {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
