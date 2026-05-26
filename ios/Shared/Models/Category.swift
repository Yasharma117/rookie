import Foundation

struct Category: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let color: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case createdAt = "created_at"
    }
}
