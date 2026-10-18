import Foundation
import CryptoKit
import Combine

/// Protocol defining secure storage operations
protocol SecureStorageProtocol {
    func saveEncryptedData(_ data: Data, forKey key: String) throws
    func fetchDecryptedData(forKey key: String) throws -> Data?
}

/// A high-performance, threat-modeled network and storage synchronization module.
final class SecureNetworkManager: SecureStorageProtocol {
    
    private let session: URLSession
    private let encryptionKey: SymmetricKey
    private var cancellables = Set<AnyCancellable>()
    
    // In-memory atomic cache for sub-millisecond lookups
    private let cacheLock = NSRecursiveLock()
    private var memoryCache: [String: Data] = [:]
    
    init(session: URLSession = .shared) {
        self.session = session
        // Generate or retrieve a secure key from the iOS Keychain (simplified for display)
        self.encryptionKey = SymmetricKey(size: .bits256)
    }
    
    // MARK: - Secure Storage Protocol Implementation
    
    func saveEncryptedData(_ data: Data, forKey key: String) throws {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // 1. Encrypt payload using AES-GCM to ensure confidentiality and integrity
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
        guard let encryptedData = sealedBox.combined else {
            throw NSError(domain: "SecurityError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        
        // 2. Commit safely to disk and update internal cache memory atomically
        memoryCache[key] = data
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        try encryptedData.write(to: fileURL, options: .atomic)
    }
    
    func fetchDecryptedData(forKey key: String) throws -> Data? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // Hit in-memory cache first for optimal processing speed
        if let cached = memoryCache[key] { return cached }
        
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        
        let rawDiskData = try Data(contentsOf: fileURL)
        let sealedBox = try AES.GCM.SealedBox(combined: rawDiskData)
        
        // Decrypt payload safely
        let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
        memoryCache[key] = decryptedData
        return decryptedData
    }
    
    // MARK: - Offline-First API Synchronization Layer
    
    /// Executes an API request with an immediate encrypted fallback policy if offline.
    func fetchRemoteData<T: Decodable>(from url: URL, cacheKey: String) -> AnyPublisher<T, Error> {
        return session.dataTaskPublisher(for: url)
            .tryMap { [weak self] element -> Data in
                guard let httpResponse = element.response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                // Async fallback save
                try? self?.saveEncryptedData(element.data, forKey: cacheKey)
                return element.data
            }
            .decode(type: T.self, decoder: JSONDecoder())
            .catch { [weak self] error -> AnyPublisher<T, Error> in
                // Network failed or device is offline: attempt decryption from local disk cache
                guard let cachedData = try? self?.fetchDecryptedData(forKey: cacheKey),
                      let decodedFallback = try? JSONDecoder().decode(T.self, from: cachedData) else {
                    return Fail(error: error).eraseToAnyPublisher()
                }
                return Just(decodedFallback)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
