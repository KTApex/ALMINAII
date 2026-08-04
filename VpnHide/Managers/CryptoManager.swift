import CryptoKit
import Foundation
import Security

// MARK: - Crypto Errors

enum CryptoError: Error, LocalizedError {
    case keyGenerationFailed
    case keychainSaveFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case encryptionFailed
    case decryptionFailed
    case invalidData
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate a cryptographic key."
        case .keychainSaveFailed(let status):
            return "Failed to save key to Keychain. OSStatus: \(status)"
        case .keychainReadFailed(let status):
            return "Failed to read key from Keychain. OSStatus: \(status)"
        case .keychainDeleteFailed(let status):
            return "Failed to delete key from Keychain. OSStatus: \(status)"
        case .encryptionFailed:
            return "Failed to encrypt data."
        case .decryptionFailed:
            return "Failed to decrypt data."
        case .invalidData:
            return "The provided data is invalid."
        case .authenticationFailed:
            return "Authentication failed. The data may have been tampered with."
        }
    }
}

// MARK: - Crypto Manager

/// Central cryptographic engine using Apple's CryptoKit.
/// Provides AES-256-GCM sealed-box encryption for file-level protection.
final class CryptoManager {

    static let shared = CryptoManager()

    private init() {}

    // MARK: - Key Management (Keychain)

    /// The symmetric key used to encrypt/decrypt vault media.
    /// Stored securely in the iOS Keychain, never persisted to disk in plaintext.
    var vaultKey: SymmetricKey? {
        get {
            guard let keyData = KeychainManager.shared.readKey(named: Constants.vaultKeyName) else {
                return nil
            }
            return SymmetricKey(data: keyData)
        }
    }

    /// Creates a new 256-bit AES key and stores it in the Keychain.
    @discardableResult
    func createVaultKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data(Array($0)) }
        try KeychainManager.shared.saveKey(keyData, named: Constants.vaultKeyName)
        return key
    }

    /// Retrieves or creates the vault master key.
    func getOrCreateVaultKey() throws -> SymmetricKey {
        if let existing = vaultKey {
            return existing
        }
        return try createVaultKey()
    }

    // MARK: - Encryption

    /// Encrypts arbitrary `Data` using AES-GCM with the vault key.
    /// Returns a single `Data` blob: [12-byte nonce][ciphertext + 16-byte tag].
    func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateVaultKey()
        return try encrypt(data, with: key)
    }

    func encrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw CryptoError.encryptionFailed
            }
            return combined
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.encryptionFailed
        }
    }

    // MARK: - Decryption

    /// Decrypts a sealed box produced by `encrypt(_:)`.
    func decrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateVaultKey()
        return try decrypt(data, with: key)
    }

    func decrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    // MARK: - Constants

    enum Constants {
        static let vaultKeyName = "com.vpnhide.vault.masterkey"
        static let pinKeyName = "com.vpnhide.vault.pin"
        static let panicPinKeyName = "com.vpnhide.vault.panicpin"
    }
}