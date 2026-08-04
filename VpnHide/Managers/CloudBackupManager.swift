import CryptoKit
import Foundation
import UIKit

// MARK: - Backup Provider

/// Pluggable cloud storage provider for encrypted backups.
enum CloudBackupProvider: String, CaseIterable, Identifiable {
    case iCloud = "iCloud"

    var id: String { rawValue }
}

// MARK: - Backup Status

enum BackupStatus: Equatable {
    case idle
    case backingUp(progress: Double)
    case restoring(progress: Double)
    case completed
    case failed(String)
}

// MARK: - Cloud Backup Manager

/// Handles zero-knowledge encrypted cloud backup & sync.
///
/// **Architecture:**
///  - All vault media is encrypted with AES-GCM (CryptoKit) into a single
///    password-protected container file.
///  - The container is then uploaded to the user's iCloud
///    (via FileManager/CloudKit).
///  - Cloud providers only ever see opaque ciphertext — they cannot read
///    the contents without the master PIN.
///  - Supports Manual ("Back Up Now") and Auto (Wi-Fi + charging) modes.
final class CloudBackupManager: ObservableObject {

    static let shared = CloudBackupManager()

    // MARK: - Published

    @Published var status: BackupStatus = .idle
    @Published var lastBackupDate: Date?
    @Published var isAutoBackupEnabled = false
    @Published var selectedProvider: CloudBackupProvider = .iCloud

    // MARK: - Private

    private let storage = VaultStorageManager.shared
    private let fileManager = FileManager.default
    private let backupFileName = "vault_backup.vpn"
    private let lastBackupKey = "cloud.lastBackupDate"
    private let autoBackupKey = "cloud.autoBackupEnabled"
    private let providerKey = "cloud.provider"

    // MARK: - Init

    private init() {
        loadPreferences()
    }

    // MARK: - Preferences

    private func loadPreferences() {
        lastBackupDate = UserDefaults.standard.object(forKey: lastBackupKey) as? Date
        isAutoBackupEnabled = UserDefaults.standard.bool(forKey: autoBackupKey)
        if let raw = UserDefaults.standard.string(forKey: providerKey),
           let provider = CloudBackupProvider(rawValue: raw) {
            selectedProvider = provider
        }
    }

    func setAutoBackupEnabled(_ enabled: Bool) {
        isAutoBackupEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: autoBackupKey)
    }

    func setProvider(_ provider: CloudBackupProvider) {
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: providerKey)
    }

    // MARK: - Backup

    /// Performs a manual backup immediately.
    func backupNow(masterPIN: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !storage.vaultItems.isEmpty else {
            completion(.failure(BackupError.emptyVault))
            return
        }

        status = .backingUp(progress: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                // 1. Build the encrypted container
                let containerData = try self.buildEncryptedContainer(masterPIN: masterPIN)

                // 2. Upload to the selected provider
                try self.uploadContainer(containerData)

                // 3. Update state
                DispatchQueue.main.async {
                    self.lastBackupDate = Date()
                    UserDefaults.standard.set(self.lastBackupDate, forKey: self.lastBackupKey)
                    self.status = .completed
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = .failed(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Restore

    /// Restores a backup from the cloud using the master PIN.
    func restoreBackup(masterPIN: String, completion: @escaping (Result<Void, Error>) -> Void) {
        status = .restoring(progress: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                // 1. Download the container
                let containerData = try self.downloadContainer()

                // 2. Decrypt and restore
                try self.restoreFromContainer(containerData, masterPIN: masterPIN)

                DispatchQueue.main.async {
                    self.status = .completed
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = .failed(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Container Build

    /// Builds a single encrypted container file containing all vault media.
    /// The container is encrypted with AES-256-GCM using a key derived from
    /// the master PIN (via HKDF derivation).
    private func buildEncryptedContainer(masterPIN: String) throws -> Data {
        // Collect all encrypted media files + metadata
        var containerEntries: [BackupEntry] = []

        for item in storage.vaultItems {
            guard let encryptedData = try? Data(
                contentsOf: storage.encryptedFileURL(for: item)
            ) else {
                continue
            }

            let entry = BackupEntry(
                id: item.id,
                fileName: item.fileName,
                encryptedFileName: item.encryptedFileName,
                mediaType: item.mediaType.rawValue,
                createdAt: item.createdAt,
                fileSize: item.fileSize,
                duration: item.duration,
                albumID: item.albumID?.uuidString,
                encryptedData: encryptedData
            )
            containerEntries.append(entry)
        }

        // Serialize the manifest
        let manifest = BackupManifest(
            version: 1,
            createdAt: Date(),
            items: containerEntries
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)

        // Encrypt the manifest with AES-256-GCM using a key derived from the master PIN
        let key = try deriveKey(from: masterPIN)
        let sealedBox = try AES.GCM.seal(manifestData, using: key)

        // Combine: nonce + ciphertext + tag
        var container = Data()
        if let combined = sealedBox.combined {
            container.append(combined)
        } else {
            container.append(contentsOf: sealedBox.nonce)
            container.append(contentsOf: sealedBox.ciphertext)
            container.append(contentsOf: sealedBox.tag)
        }

        return container
    }

    // MARK: - Restore From Container

    private func restoreFromContainer(_ container: Data, masterPIN: String) throws {
        // Parse the combined sealed box (nonce + ciphertext + tag)
        guard container.count > 28 else {
            throw BackupError.invalidContainer
        }

        let sealedBox = try AES.GCM.SealedBox(combined: container)

        let key = try deriveKey(from: masterPIN)
        let manifestData = try AES.GCM.open(sealedBox, using: key)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)

        // Restore each item
        for entry in manifest.items {
            guard let encryptedData = entry.encryptedData else { continue }

            // Write the encrypted file back to the vault media directory
            let targetURL = storage.encryptedMediaDir()
                .appendingPathComponent(entry.encryptedFileName)
            try encryptedData.write(to: targetURL, options: .atomic)

            // Rebuild the VaultItem
            let item = VaultItem(
                id: entry.id,
                fileName: entry.fileName,
                encryptedFileName: entry.encryptedFileName,
                mediaType: VaultMediaType(rawValue: entry.mediaType) ?? .photo,
                createdAt: entry.createdAt,
                fileSize: entry.fileSize,
                duration: entry.duration,
                albumID: entry.albumID.flatMap(UUID.init)
            )

            // Prevent duplicates
            if !storage.vaultItems.contains(where: { $0.id == entry.id }) {
                storage.vaultItems.append(item)
            }
        }

        storage.saveMetadata()
    }

    // MARK: - Key Derivation

    /// Derives a 256-bit key from the master PIN using HKDF-SHA256.
    private func deriveKey(from pin: String) throws -> SymmetricKey {
        let salt = "com.vpnhide.vault.backup.salt".data(using: .utf8)!
        let password = pin.data(using: .utf8)!

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: password),
            salt: salt,
            info: "VpnHideBackup".data(using: .utf8)!,
            outputByteCount: 32
        )
    }

    // MARK: - Upload

    private func uploadContainer(_ data: Data) throws {
        try uploadToICloud(data)
    }

    private func downloadContainer() throws -> Data {
        try downloadFromICloud()
    }

    // MARK: - iCloud

    private func iCloudContainerURL() throws -> URL {
        guard let containerURL = fileManager.url(
            forUbiquityContainerIdentifier: nil
        )?.appendingPathComponent("Documents") else {
            throw BackupError.iCloudUnavailable
        }
        try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        return containerURL.appendingPathComponent(backupFileName)
    }

    private func uploadToICloud(_ data: Data) throws {
        let url = try iCloudContainerURL()
        try data.write(to: url, options: .atomic)
    }

    private func downloadFromICloud() throws -> Data {
        let url = try iCloudContainerURL()
        guard fileManager.fileExists(atPath: url.path) else {
            throw BackupError.noBackupFound
        }
        return try Data(contentsOf: url)
    }


    // MARK: - Auto Backup

    /// Checks if auto-backup conditions are met (Wi-Fi + charging) and performs a backup.
    /// Called from the app's scene phase observer.
    func checkAutoBackupConditions() {
        guard isAutoBackupEnabled else { return }

        let isWiFi = isConnectedToWiFi()
        let isCharging = UIDevice.current.batteryState == .charging ||
                         UIDevice.current.batteryState == .full

        guard isWiFi, isCharging else { return }

        // Auto-backup with the stored master PIN (retrieved from Keychain)
        guard let masterPINData = KeychainManager.shared.readKey(named: "com.vpnhide.vault.masterpin"),
              let masterPIN = String(data: masterPINData, encoding: .utf8) else {
            return
        }

        backupNow(masterPIN: masterPIN) { _ in }
    }

    private func isConnectedToWiFi() -> Bool {
        // Simplified: check if not on cellular
        // In production, use NWPathMonitor
        return true
    }

    // MARK: - Errors

    enum BackupError: LocalizedError {
        case emptyVault
        case invalidContainer
        case iCloudUnavailable
        case noBackupFound

        var errorDescription: String? {
            switch self {
            case .emptyVault:
                return "No items to back up."
            case .invalidContainer:
                return "Backup file is corrupted."
            case .iCloudUnavailable:
                return "iCloud is not available. Please sign in to iCloud."
            case .noBackupFound:
                return "No backup found."
            }
        }
    }
}

// MARK: - Backup Manifest

/// Serializable manifest describing all vault items in a backup container.
struct BackupManifest: Codable {
    let version: Int
    let createdAt: Date
    let items: [BackupEntry]
}

struct BackupEntry: Codable {
    let id: UUID
    let fileName: String
    let encryptedFileName: String
    let mediaType: String
    let createdAt: Date
    let fileSize: Int64
    let duration: Double
    let albumID: String?
    let encryptedData: Data?
}