import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showSignIn = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "bookmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 10) {
                    Text("LinkSaver")
                        .font(.largeTitle.bold())
                    Text("Save any link from any app.\nOrganised, categorised, always there.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    showSignIn = true
                } label: {
                    Label("Continue with Apple", systemImage: "apple.logo")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(Color(.systemBackground))
                        .background(.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("By continuing you agree to our Terms and Privacy Policy.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                #if DEBUG
                Button("Skip sign-in (dev)") {
                    appState.skipSignInForDev()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                #endif
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(appState)
        }
    }
}
