import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section("Account") {
                Button(role: .destructive) {
                    appState.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DevicesView: View {
    @State private var tokens: [IngestTokenOut] = []
    @State private var isLoading = false
    @State private var revokeTarget: IngestTokenOut?

    var body: some View {
        List {
            if isLoading && tokens.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(tokens) { token in
                    tokenRow(token)
                }
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTokens() }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let t = revokeTarget { Task { await revoke(t) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func tokenRow(_ token: IngestTokenOut) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(token.deviceLabel ?? "Unknown device")
                    .font(.subheadline.weight(.medium))
                Text("Added \(token.createdAt.formatted(.dateTime.month().day().year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if token.revokedAt != nil {
                Text("Revoked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
            } else {
                Button {
                    revokeTarget = token
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadTokens() async {
        guard let token = KeychainStore.shared.ingestToken() else { return }
        isLoading = true
        defer { isLoading = false }
        tokens = (try? await APIClient.shared.fetchTokens(token: token)) ?? []
    }

    private func revoke(_ target: IngestTokenOut) async {
        guard let token = KeychainStore.shared.ingestToken() else { return }
        try? await APIClient.shared.revokeToken(id: target.id, token: token)
        await loadTokens()
    }
}

