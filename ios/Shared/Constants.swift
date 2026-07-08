import Foundation

enum AppConstants {
    static let appGroupID = "group.com.becauseyssaidso.shared"
    static let keychainService = "com.becauseyssaidso.LinkSaver"
    static let keychainAccount = "ingest_token"
    static let keychainAccessGroup = "com.becauseyssaidso.shared"
    static let apiBaseURL = URL(string: "https://rookie-x5yh.onrender.com")!
    static let clientVersion = "ios-share-ext/0.1.0"
    static let ingestTimeout: TimeInterval = 30.0
    static let duplicateThresholdSeconds: TimeInterval = 120
}
