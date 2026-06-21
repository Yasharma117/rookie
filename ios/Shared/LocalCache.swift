import Foundation

/// On-disk cache for the home library so the app can render the user's links
/// and categories instantly on launch/foreground — before (or instead of) a
/// network round-trip. The server stays the source of truth; this is purely a
/// stale-while-revalidate read cache. Stored as JSON in the app-group container
/// so it persists across launches.
enum LocalCache {
    private static let linksFile = "cache_links_v1.json"
    private static let categoriesFile = "cache_categories_v1.json"
    private static let etagDefaultsPrefix = "etag_v1_"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static var containerURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConstants.appGroupID) ?? .standard
    }

    // MARK: - Links

    static func saveLinks(_ links: [IngestResponse]) {
        write(links, to: linksFile)
    }

    static func loadLinks() -> [IngestResponse] {
        read(linksFile) ?? []
    }

    // MARK: - Categories

    static func saveCategories(_ categories: [Category]) {
        write(categories, to: categoriesFile)
    }

    static func loadCategories() -> [Category] {
        read(categoriesFile) ?? []
    }

    // MARK: - ETags (for conditional requests)

    static func etag(for key: String) -> String? {
        defaults.string(forKey: etagDefaultsPrefix + key)
    }

    static func setEtag(_ etag: String?, for key: String) {
        let k = etagDefaultsPrefix + key
        if let etag { defaults.set(etag, forKey: k) } else { defaults.removeObject(forKey: k) }
    }

    // MARK: - IO

    private static func write<T: Encodable>(_ value: T, to file: String) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: containerURL.appendingPathComponent(file), options: .atomic)
        } catch {
            // Cache is best-effort; a write failure must never affect the user.
            #if DEBUG
            print("LocalCache write \(file) failed: \(error)")
            #endif
        }
    }

    private static func read<T: Decodable>(_ file: String) -> T? {
        let url = containerURL.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
