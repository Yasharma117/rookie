import Foundation

enum AppConstants {
    static let appGroupID = "group.com.becauseyssaidso.shared"
    static let keychainService = "com.becauseyssaidso.LinkSaver"
    static let keychainAccount = "ingest_token"
    static let keychainAccessGroup = "com.becauseyssaidso.shared"
    #if DEBUG
    static let apiBaseURL = URL(string: "http://127.0.0.1:8089")!
    #else
    static let apiBaseURL = URL(string: "https://rookie-x5yh.onrender.com")!
    #endif
    static let clientVersion = "ios-share-ext/0.1.0"
    static let ingestTimeout: TimeInterval = 30.0
    static let duplicateThresholdSeconds: TimeInterval = 120
}
