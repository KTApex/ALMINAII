import CryptoKit
import Foundation
import Security

/// Wrapper around the iOS Keychain Services API.
/// Used to store the vault master key and PIN hashes securely.
final class KeychainManager {

    static let shared = KeychainManager()

    private let service = "com.vpnhide.keychain"

    private init() {}

    // MARK: - Save

    @discardableResult
    func saveKey(_ data: Data, named name: String) throws -> Bool {
        // Delete any existing item first to avoid duplicate-key errors
        try? deleteKey(named: name)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoError.keychainSaveFailed(status)
        }
        return true
    }

    // MARK: - Read

    func readKey(named name: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    // MARK: - Delete

    @discardableResult
    func deleteKey(named name: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychainDeleteFailed(status)
        }
        return true
    }

    // MARK: - PIN Storage (hashed)

    /// Stores a salted SHA-256 hash of the PIN. The raw PIN is never stored.
    func savePINHash(_ hash: Data, named name: String) throws {
        try saveKey(hash, named: name)
    }

    func readPINHash(named name: String) -> Data? {
        readKey(named: name)
    }

    // MARK: - Utility

    /// Generates a salted SHA-256 hash for a given PIN string.
    func hashPIN(_ pin: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(pin.utf8))
        return Data(hasher.finalize())
    }

    /// Generates a random 16-byte salt.
    func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        }
        return Data(bytes)
    }
}