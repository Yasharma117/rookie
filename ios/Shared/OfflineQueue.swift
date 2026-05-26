import Foundation

final class OfflineQueue {
    static let shared = OfflineQueue()

    private let defaults: UserDefaults
    private let key = "offline_queue_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        defaults = UserDefaults(suiteName: AppConstants.appGroupID) ?? .standard
    }

    func enqueue(_ save: QueuedSave) {
        var current = peek()
        current.append(save)
        persist(current)
    }

    func peek() -> [QueuedSave] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? decoder.decode([QueuedSave].self, from: data)) ?? []
    }

    func remove(id: UUID) {
        persist(peek().filter { $0.id != id })
    }

    func drain(api: APIClient, token: String) async {
        for save in peek() {
            do {
                _ = try await api.ingest(
                    IngestRequest(url: save.url),
                    token: token,
                    idempotencyKey: save.idempotencyKey
                )
                remove(id: save.id)
            } catch {
                // Keep in queue; retry on next drain
            }
        }
    }

    private func persist(_ saves: [QueuedSave]) {
        defaults.set(try? encoder.encode(saves), forKey: key)
    }
}
