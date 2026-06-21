import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()

    private let service = AppConstants.keychainService
    private let account = AppConstants.keychainAccount
    private let accessGroup = AppConstants.keychainAccessGroup

    private init() {}

    func ingestToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the stored ingest token, or the dev API key as a DEBUG-only
    /// fallback so the simulator can talk to the local backend without
    /// completing the sign-in flow. In RELEASE this is identical to
    /// `ingestToken()`.
    func effectiveIngestToken() -> String? {
        if let token = ingestToken() { return token }
        #if DEBUG
        return "rookie_dev_api_key_123"
        #else
        return nil
        #endif
    }

    func setIngestToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func clearIngestToken() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }
}
