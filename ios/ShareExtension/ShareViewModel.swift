import Foundation
import UIKit
import SwiftUI

enum SheetState {
    case idle
    case fetching
    case ready(IngestResponse)
    case partial(IngestResponse)
    case duplicate(IngestResponse)
    case offline(URL)
    case authExpired
    case saved

    var response: IngestResponse? {
        switch self {
        case .ready(let r), .partial(let r), .duplicate(let r): return r
        default: return nil
        }
    }

    var isLoading: Bool {
        switch self {
        case .idle, .fetching: return true
        default: return false
        }
    }

    var canSave: Bool {
        switch self {
        case .idle, .authExpired, .saved: return false
        default: return true
        }
    }
}

@MainActor
final class ShareViewModel: ObservableObject {
    @Published var state: SheetState = .idle
    @Published var selectedCategoryID: UUID?
    @Published var noteText: String = ""
    @Published var reminderDate: Date?
    @Published var isNoteExpanded: Bool = false
    @Published var debugError: String?

    private let url: URL
    private let token: String
    private let api = APIClient.shared

    weak var extensionContext: NSExtensionContext?

    init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    #if DEBUG
    convenience init(previewState: SheetState) {
        self.init(url: URL(string: "https://example.com")!, token: "preview")
        self.state = previewState
        if case .ready(let response) = previewState {
            self.selectedCategoryID = response.categories.first?.id
        }
    }

    /// Cycles through all 8 sheet states for visual QA.
    /// Tap the header in a DEBUG build to trigger this.
    func cycleState() {
        let allStates: [SheetState] = [
            .idle,
            .fetching,
            .ready(.mock()),
            .partial(.mock(status: .pending, title: nil)),
            .duplicate(.mock(ingestedAt: Date().addingTimeInterval(-86400 * 3))),
            .offline(url),
            .authExpired,
            .saved,
        ]

        // Find current index by matching the discriminator
        let currentIndex = allStates.firstIndex(where: { stateTag($0) == stateTag(state) }) ?? -1
        let nextIndex = (currentIndex + 1) % allStates.count
        let next = allStates[nextIndex]

        state = next

        // Auto-select top category for ready state
        if case .ready(let response) = next {
            autoSelectTopCategory(from: response)
        } else {
            selectedCategoryID = nil
        }
    }

    private func stateTag(_ s: SheetState) -> Int {
        switch s {
        case .idle: return 0
        case .fetching: return 1
        case .ready: return 2
        case .partial: return 3
        case .duplicate: return 4
        case .offline: return 5
        case .authExpired: return 6
        case .saved: return 7
        }
    }
    #endif

    func beginSave() {
        state = .fetching
        debugError = nil
        Task {
            do {
                print("DEBUG: beginSave() calling \(api.baseURL)/v1/links with token=\(token.prefix(8))...")
                let response = try await api.ingest(
                    IngestRequest(url: url.absoluteString),
                    token: token
                )
                print("DEBUG: beginSave() got response id=\(response.id) status=\(response.status)")
                if response.isDuplicate {
                    state = .duplicate(response)
                } else if response.status == .enriched {
                    state = .ready(response)
                    autoSelectTopCategory(from: response)
                } else {
                    state = .partial(response)
                    startPolling(linkID: response.id)
                }
            } catch APIError.unauthorized {
                debugError = "401 Unauthorized (token: \(token.prefix(8))...)"
                state = .authExpired
            } catch APIError.networkUnavailable {
                debugError = "Network unavailable"
                state = .offline(url)
            } catch APIError.timeout {
                debugError = "Timed out (\(Int(AppConstants.ingestTimeout))s)"
                state = .offline(url)
            } catch APIError.decodingError(let inner) {
                debugError = "Decode: \(inner.localizedDescription)"
                state = .offline(url)
            } catch APIError.serverError(let code) {
                debugError = "Server \(code)"
                state = .offline(url)
            } catch {
                debugError = "\(error)"
                state = .offline(url)
            }
            if let err = debugError {
                print("DEBUG: beginSave() FAILED: \(err)")
            }
        }
    }

    func commitSave() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if case .offline = state {
            enqueueOffline()
            transitionToSaved()
            return
        }

        if let response = state.response {
            let categoryIDs: [UUID]? = selectedCategoryID.map { [$0] }
            Task {
                try? await api.patchLink(id: response.id, categoryIDs: categoryIDs, token: token)
            }
        }

        transitionToSaved()
    }

    func saveOffline() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        enqueueOffline()
        transitionToSaved()
    }

    func cancel() {
        complete()
    }

    func openMainApp() {
        if let url = URL(string: "linksaver://") {
            extensionContext?.open(url, completionHandler: nil)
        }
    }

    // MARK: - Private

    private func autoSelectTopCategory(from response: IngestResponse) {
        selectedCategoryID = response.categories
            .max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) })?.id
    }

    private func startPolling(linkID: UUID) {
        Task {
            // Quick ramp instead of a flat 2s: the category now lands ~1-2s
            // server-side, so poll early and often, then back off. Total ~7s.
            let delaysMs: [UInt64] = [500, 800, 1200, 1800, 2500]
            for (attempt, delayMs) in delaysMs.enumerated() {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)

                guard case .partial(let currentResponse) = state, currentResponse.id == linkID else {
                    break
                }

                do {
                    print("DEBUG: polling link \(linkID) (attempt \(attempt + 1))...")
                    let updatedResponse = try await api.fetchLink(id: linkID, token: token)
                    print("DEBUG: polled link status = \(updatedResponse.status)")

                    if updatedResponse.status == .enriched {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            self.state = .ready(updatedResponse)
                            self.autoSelectTopCategory(from: updatedResponse)
                        }
                        break
                    }
                } catch {
                    print("DEBUG: polling failed: \(error)")
                }
            }
        }
    }

    private func enqueueOffline() {
        let save = QueuedSave(
            url: url.absoluteString,
            categoryID: selectedCategoryID,
            note: noteText.nilIfEmpty
        )
        OfflineQueue.shared.enqueue(save)
    }

    private func transitionToSaved() {
        state = .saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.complete()
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
