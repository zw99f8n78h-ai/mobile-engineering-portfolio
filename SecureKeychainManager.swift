import Foundation
import Security

/// Thread-safe wrapper around the iOS Keychain for sensitive user session token storage.
final class SecureKeychainManager {
    
    static let shared = SecureKeychainManager()
    private let lock = NSLock()
    private let serviceIdentifier = "com.portfolio.mobile.session"
    
    private init() {}
    
    /// Atomically saves or updates a generic password string in the iOS secure enclave.
    func saveToken(_ token: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let tokenData = token.data(using: .utf8) else { return false }
        
        // Formulate standard security dictionary query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: account,
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock // Strict encryption at rest
        ]
        
        // Remove existing item to avoid conflicts if present
        SecItemDelete(query as CFDictionary)
        
        // Commit new cryptographic entry
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Reads tokens directly from secure storage fallback. Returns nil if missing.
    func fetchToken(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess, let data = dataTypeRef as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
