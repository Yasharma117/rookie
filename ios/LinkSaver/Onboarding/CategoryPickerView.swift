import SwiftUI

/// Onboarding step 2: pick the categories links get sorted into.
/// Loads the fixed catalog from the backend, requires at least one pick,
/// and completes onboarding via POST /v1/onboarding.
struct CategoryPickerView: View {
    @EnvironmentObject private var appState: AppState

    @State private var catalog: [APIClient.CatalogEntry] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("What do you save?")
                    .font(.title2.bold())
                Text("Pick a few categories — links you share get sorted into them automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 28)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(catalog) { entry in
                            chip(for: entry)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }

            VStack(spacing: 12) {
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submit()
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text(selected.isEmpty
                                 ? "Pick at least one"
                                 : "Continue with \(selected.count) selected")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(
                        selected.isEmpty ? Color.gray.opacity(0.5) : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty || isSubmitting)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .task { await loadCatalog() }
    }

    private func chip(for entry: APIClient.CatalogEntry) -> some View {
        let isOn = selected.contains(entry.slug)
        return Button {
            if isOn { selected.remove(entry.slug) } else { selected.insert(entry.slug) }
        } label: {
            VStack(spacing: 6) {
                Text(entry.emoji).font(.system(size: 28))
                Text(entry.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isOn ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func loadCatalog() async {
        isLoading = true
        do {
            catalog = try await APIClient.shared.fetchCatalog()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func submit() {
        guard let token = appState.apiToken, !selected.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        // Preserve catalog order in the request
        let slugs = catalog.map(\.slug).filter { selected.contains($0) }
        Task {
            do {
                try await APIClient.shared.completeOnboarding(slugs: slugs, token: token)
                appState.completeOnboarding()
            } catch APIError.serverError(409) {
                // Already onboarded server-side (e.g. retry after timeout)
                appState.completeOnboarding()
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
