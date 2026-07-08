import SwiftUI

@main
struct LinkSaverApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            switch appState.phase {
            case .welcome:
                WelcomeView()
                    .environmentObject(appState)
            case .chooseCategories:
                CategoryPickerView()
                    .environmentObject(appState)
            case .installExtension:
                InstallExtensionView(isDone: Binding(
                    get: { false },
                    set: { if $0 { appState.finishExtensionSetup() } }
                ))
            case .ready:
                InboxView()
                    .environmentObject(appState)
            }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// First-run flow: welcome → (Apple sign-in) → pick categories →
    /// enable the share extension → inbox. Completed steps are remembered
    /// in UserDefaults so relaunches jump straight to the right phase.
    enum Phase {
        case welcome
        case chooseCategories
        case installExtension
        case ready
    }

    @Published var phase: Phase = .welcome

    private let keychain = KeychainStore.shared
    private let queue = OfflineQueue.shared
    private let api = APIClient.shared
    private let defaults = UserDefaults.standard

    private static let onboardedKey = "didCompleteOnboarding"
    private static let extensionKey = "didEnableShareExtension"
    private static let devSkipKey = "didSkipSignInForDev"

    var isSignedIn: Bool { keychain.effectiveIngestToken() != nil }
    var apiToken: String? { keychain.effectiveIngestToken() }

    /// Explicit sign-in (real keychain token or the DEBUG dev skip) — the
    /// silent dev-key fallback alone must not bypass the welcome screen,
    /// or DEBUG builds could never exercise the sign-in flow.
    private var hasCompletedSignIn: Bool {
        keychain.ingestToken() != nil || defaults.bool(forKey: Self.devSkipKey)
    }

    init() {
        phase = resolvedPhase()
        // The server is the source of truth for onboarding — the local flag
        // only exists so relaunches don't flash the picker. Reconcile lazily.
        if phase == .chooseCategories { refreshOnboardingStatus() }
        drainQueueIfNeeded()
    }

    func signIn(ingestToken: String, onboarded: Bool) {
        keychain.setIngestToken(ingestToken)
        defaults.set(onboarded, forKey: Self.onboardedKey)
        phase = resolvedPhase()
        drainQueueIfNeeded()
    }

    func completeOnboarding() {
        defaults.set(true, forKey: Self.onboardedKey)
        phase = resolvedPhase()
    }

    func finishExtensionSetup() {
        defaults.set(true, forKey: Self.extensionKey)
        phase = resolvedPhase()
    }

    func signOut() {
        keychain.clearIngestToken()
        defaults.removeObject(forKey: Self.onboardedKey)
        defaults.removeObject(forKey: Self.extensionKey)
        defaults.removeObject(forKey: Self.devSkipKey)
        phase = resolvedPhase()
    }

    #if DEBUG
    /// Dev shortcut: leaves the keychain untouched so API calls fall back to
    /// the dev API key, then walks the normal onboarding flow (the backend
    /// answers 409 if the dev user already onboarded, which the picker
    /// treats as success).
    func skipSignInForDev() {
        defaults.set(true, forKey: Self.devSkipKey)
        phase = resolvedPhase()
    }
    #endif

    private func resolvedPhase() -> Phase {
        guard hasCompletedSignIn, keychain.effectiveIngestToken() != nil else { return .welcome }
        if !defaults.bool(forKey: Self.onboardedKey) { return .chooseCategories }
        if !defaults.bool(forKey: Self.extensionKey) { return .installExtension }
        return .ready
    }

    /// If the server says this user already onboarded (e.g. reinstall on a
    /// new device), skip the category picker.
    private func refreshOnboardingStatus() {
        guard let token = keychain.effectiveIngestToken() else { return }
        Task {
            guard let me = try? await api.fetchMe(token: token), me.onboarded else { return }
            defaults.set(true, forKey: Self.onboardedKey)
            if phase == .chooseCategories { phase = resolvedPhase() }
        }
    }

    private func drainQueueIfNeeded() {
        guard let token = keychain.effectiveIngestToken(), !queue.peek().isEmpty else { return }
        Task {
            await queue.drain(api: api, token: token)
        }
    }
}
