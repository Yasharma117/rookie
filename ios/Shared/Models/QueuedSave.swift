import Foundation

struct QueuedSave: Codable, Identifiable {
    let id: UUID
    let url: String
    let idempotencyKey: String
    let queuedAt: Date
    let categoryID: UUID?
    let note: String?

    init(url: String, categoryID: UUID? = nil, note: String? = nil) {
        self.id = UUID()
        self.url = url
        self.idempotencyKey = UUID().uuidString
        self.queuedAt = Date()
        self.categoryID = categoryID
        self.note = note
    }
}
