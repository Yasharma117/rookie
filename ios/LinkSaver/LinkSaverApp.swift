import SwiftUI

@main
struct LinkSaverApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if appState.isSignedIn {
                InboxView()
                    .environmentObject(appState)
            } else {
                WelcomeView()
                    .environmentObject(appState)
            }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isSignedIn: Bool = false

    private let keychain = KeychainStore.shared
    private let queue = OfflineQueue.shared
    private let api = APIClient.shared

    init() {
        isSignedIn = keychain.effectiveIngestToken() != nil
        drainQueueIfNeeded()
    }

    func signIn(ingestToken: String) {
        keychain.setIngestToken(ingestToken)
        isSignedIn = true
        drainQueueIfNeeded()
    }

    func signOut() {
        keychain.clearIngestToken()
        isSignedIn = false
    }

    private func drainQueueIfNeeded() {
        guard let token = keychain.effectiveIngestToken(), !queue.peek().isEmpty else { return }
        Task {
            await queue.drain(api: api, token: token)
        }
    }
}
