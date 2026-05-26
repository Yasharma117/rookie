import Foundation

struct IngestResponse: Decodable, Identifiable, Hashable {
    let id: UUID
    let sourceURL: String
    let canonicalURL: String
    let sourcePlatform: SourcePlatform
    let status: LinkStatus
    let title: String?
    let description: String?
    let author: String?
    let thumbnailURL: String?
    let ingestedAt: Date
    let enrichedAt: Date?
    let categories: [CategoryRef]

    enum CodingKeys: String, CodingKey {
        case id
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
        case sourcePlatform = "source_platform"
        case status, title, description, author
        case thumbnailURL = "thumbnail_url"
        case ingestedAt = "ingested_at"
        case enrichedAt = "enriched_at"
        case categories
    }

    var isDuplicate: Bool {
        Date().timeIntervalSince(ingestedAt) > AppConstants.duplicateThresholdSeconds
    }

    var displayTitle: String {
        title?.nilIfEmpty ?? canonicalURL
    }

    var displayDomain: String? {
        URL(string: canonicalURL)?.host
    }
}

struct CategoryRef: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let confidence: Double?
}

enum LinkStatus: String, Decodable, Hashable {
    case pending, enriched, failed
}

enum SourcePlatform: String, Decodable, Hashable {
    case instagram, linkedin, youtube, x, tiktok, vimeo, reddit, web

    var sfSymbol: String {
        switch self {
        case .instagram: return "camera.fill"
        case .linkedin: return "briefcase.fill"
        case .youtube: return "play.rectangle.fill"
        case .x: return "at"
        case .tiktok: return "music.note"
        case .vimeo: return "play.circle.fill"
        case .reddit: return "bubble.left.and.bubble.right.fill"
        case .web: return "globe"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
extension IngestResponse {
    static func mock(
        status: LinkStatus = .enriched,
        title: String? = "Apple unveils M5 MacBook Pro",
        ingestedAt: Date = Date(),
        categories: [CategoryRef] = [
            CategoryRef(id: UUID(), name: "Tech", confidence: 0.92),
            CategoryRef(id: UUID(), name: "Reading list", confidence: nil),
            CategoryRef(id: UUID(), name: "Apple", confidence: nil)
        ],
        platform: SourcePlatform = .web
    ) -> IngestResponse {
        IngestResponse(
            id: UUID(),
            sourceURL: "https://www.apple.com/newsroom/2026/01/m5-macbook-pro/",
            canonicalURL: "https://www.apple.com/newsroom/2026/01/m5-macbook-pro/",
            sourcePlatform: platform,
            status: status,
            title: title,
            description: "Faster, brighter, lighter — the new MacBook Pro is here.",
            author: "Apple Newsroom",
            thumbnailURL: nil,
            ingestedAt: ingestedAt,
            enrichedAt: status == .enriched ? Date() : nil,
            categories: categories
        )
    }
}
#endif
