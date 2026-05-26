import Foundation

struct IngestTokenOut: Decodable, Identifiable {
    let id: UUID
    let deviceLabel: String?
    let createdAt: Date
    let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceLabel = "device_label"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
    }
}
