import CryptoKit
import Foundation
import Photos
import UIKit

// MARK: - ZIP Errors

enum ZipError: LocalizedError {
    case emptySelection
    case encryptionFailed
    case decryptionFailed
    case invalidArchive
    case wrongPassword
    case photoSaveFailed
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No items selected for export."
        case .encryptionFailed:
            return "Failed to encrypt the ZIP archive."
        case .decryptionFailed:
            return "Failed to decrypt the ZIP archive."
        case .invalidArchive:
            return "The ZIP archive is corrupted or invalid."
        case .wrongPassword:
            return "Incorrect password. Please try again."
        case .photoSaveFailed:
            return "Failed to save photos to the Photos library."
        case .importFailed(let message):
            return "Import failed: \(message)"
        }
    }
}

// MARK: - ZIP Entry

/// Represents a single file entry inside the encrypted ZIP archive.
struct ZipEntry {
    let fileName: String
    let data: Data
    let isPhoto: Bool
}

// MARK: - ZIP Manager

/// Handles creating password-protected ZIP archives from vault items
/// and importing/unzipping them with auto-save to Photos library.
final class ZipManager: ObservableObject {

    static let shared = ZipManager()

    private let fileManager = FileManager.default
    private let crypto = CryptoManager.shared

    // MARK: - UserDefaults Keys

    private let autoSavePhotosKey = "zip.autoSavePhotos"

    /// Whether photos should be auto-saved to the Photos library after unzipping.
    @Published var autoSavePhotosToLibrary: Bool {
        didSet {
            UserDefaults.standard.set(autoSavePhotosToLibrary, forKey: autoSavePhotosKey)
        }
    }

    private init() {
        autoSavePhotosToLibrary = UserDefaults.standard.bool(forKey: autoSavePhotosKey)
    }

    // MARK: - Export: Create Password-Protected ZIP

    /// Creates a password-protected ZIP archive from the given vault items.
    ///
    /// - Parameters:
    ///   - items: The vault items to include in the ZIP.
    ///   - password: The password used to encrypt the archive.
    ///   - storage: The vault storage manager.
    /// - Returns: The URL of the created encrypted ZIP file.
    func exportToZip(
        items: [VaultItem],
        password: String,
        storage: VaultStorageManager
    ) throws -> URL {
        guard !items.isEmpty else {
            throw ZipError.emptySelection
        }
        guard !password.isEmpty else {
            throw ZipError.encryptionFailed
        }

        // 1. Decrypt all items and build ZIP entries
        var entries: [ZipEntry] = []
        for item in items {
            guard let data = storage.decryptItem(item) else {
                throw ZipError.encryptionFailed
            }
            let entry = ZipEntry(
                fileName: item.fileName,
                data: data,
                isPhoto: item.mediaType == .photo
            )
            entries.append(entry)
        }

        // 2. Build the ZIP archive data
        let zipData = try buildZipData(entries: entries)

        // 3. Encrypt the ZIP data with the password
        let encryptedData = try encryptZipData(zipData, password: password)

        // 4. Write to a temporary file
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("VpnHideZipExport", isDirectory: true)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileName = "Vault_Export_\(Date().formatted(date: .numeric, time: .shortened)).vpnzip"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = tempDir.appendingPathComponent(fileName)

        try encryptedData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    // MARK: - Import: Unzip and Auto-Save

    /// Imports a password-protected ZIP archive.
    ///
    /// - Parameters:
    ///   - url: The URL of the encrypted ZIP file.
    ///   - password: The password to decrypt the archive.
    ///   - storage: The vault storage manager.
    ///   - autoSavePhotos: Whether to auto-save photos to the Photos library.
    /// - Returns: The number of items imported.
    func importFromZip(
        url: URL,
        password: String,
        storage: VaultStorageManager,
        autoSavePhotos: Bool? = nil
    ) async throws -> Int {
        // 1. Read the encrypted ZIP data
        guard let encryptedData = try? Data(contentsOf: url) else {
            throw ZipError.invalidArchive
        }

        // 2. Decrypt the ZIP data
        let zipData: Data
        do {
            zipData = try decryptZipData(encryptedData, password: password)
        } catch {
            throw ZipError.wrongPassword
        }

        // 3. Parse the ZIP entries
        let entries = try parseZipData(zipData)

        // 4. Import each entry into the vault
        var importedCount = 0
        var photosToSave: [Data] = []

        for entry in entries {
            // Write to temp file and import
            let tempURL = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try entry.data.write(to: tempURL)

            let ext = (entry.fileName as NSString).pathExtension
            let renamedURL = tempURL.appendingPathExtension(ext.isEmpty ? "jpg" : ext)
            try? fileManager.moveItem(at: tempURL, to: renamedURL)

            try await storage.importMedia(from: renamedURL)
            try? fileManager.removeItem(at: renamedURL)

            // Collect photos for auto-save
            if entry.isPhoto {
                photosToSave.append(entry.data)
            }

            importedCount += 1
        }

        // 5. Auto-save photos to Photos library if enabled
        let shouldAutoSave = autoSavePhotos ?? autoSavePhotosToLibrary
        if shouldAutoSave && !photosToSave.isEmpty {
            savePhotosToLibrary(photosToSave)
        }

        return importedCount
    }

    // MARK: - Auto-Save Photos to Library

    /// Saves the given photo data to the user's Photos library.
    private func savePhotosToLibrary(_ photos: [Data]) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }

            PHPhotoLibrary.shared().performChanges {
                for photoData in photos {
                    if let image = UIImage(data: photoData) {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                }
            } completionHandler: { _, _ in }
        }
    }

    // MARK: - ZIP Building

    /// Builds a standard ZIP archive from the given entries.
    private func buildZipData(entries: [ZipEntry]) throws -> Data {
        var data = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let fileNameData = Data(entry.fileName.utf8)
            let fileData = entry.data

            // Local file header
            var localHeader = Data()
            localHeader.appendUInt32(0x04034b50) // Local file header signature
            localHeader.appendUInt16(20)         // Version needed to extract
            localHeader.appendUInt16(0)          // General purpose bit flag
            localHeader.appendUInt16(0)          // Compression method (stored)
            localHeader.appendUInt16(0)          // Last mod time
            localHeader.appendUInt16(0x21)       // Last mod date
            localHeader.appendUInt32(0)          // CRC-32 (not computed, set to 0)
            localHeader.appendUInt32(UInt32(fileData.count)) // Compressed size
            localHeader.appendUInt32(UInt32(fileData.count)) // Uncompressed size
            localHeader.appendUInt16(UInt16(fileNameData.count)) // File name length
            localHeader.appendUInt16(0)          // Extra field length

            data.append(localHeader)
            data.append(fileNameData)
            data.append(fileData)

            // Central directory entry
            var centralEntry = Data()
            centralEntry.appendUInt32(0x02014b50) // Central directory signature
            centralEntry.appendUInt16(20)         // Version made by
            centralEntry.appendUInt16(20)         // Version needed to extract
            centralEntry.appendUInt16(0)          // General purpose bit flag
            centralEntry.appendUInt16(0)          // Compression method
            centralEntry.appendUInt16(0)          // Last mod time
            centralEntry.appendUInt16(0x21)       // Last mod date
            centralEntry.appendUInt32(0)          // CRC-32
            centralEntry.appendUInt32(UInt32(fileData.count)) // Compressed size
            centralEntry.appendUInt32(UInt32(fileData.count)) // Uncompressed size
            centralEntry.appendUInt16(UInt16(fileNameData.count)) // File name length
            centralEntry.appendUInt16(0)          // Extra field length
            centralEntry.appendUInt16(0)          // File comment length
            centralEntry.appendUInt16(0)          // Disk number start
            centralEntry.appendUInt16(0)          // Internal file attributes
            centralEntry.appendUInt32(0)          // External file attributes
            centralEntry.appendUInt32(offset)     // Local header offset

            centralDirectory.append(centralEntry)
            centralDirectory.append(fileNameData)

            offset += UInt32(localHeader.count + fileNameData.count + fileData.count)
        }

        // End of central directory record
        var endRecord = Data()
        endRecord.appendUInt32(0x06054b50) // End of central directory signature
        endRecord.appendUInt16(0)          // Number of this disk
        endRecord.appendUInt16(0)          // Disk where central directory starts
        endRecord.appendUInt16(UInt16(entries.count)) // Number of central directory records on this disk
        endRecord.appendUInt16(UInt16(entries.count)) // Total number of central directory records
        endRecord.appendUInt32(UInt32(centralDirectory.count)) // Size of central directory
        endRecord.appendUInt32(offset)     // Offset of start of central directory
        endRecord.appendUInt16(0)          // Comment length

        data.append(centralDirectory)
        data.append(endRecord)

        return data
    }

    // MARK: - ZIP Parsing

    /// Parses a ZIP archive and extracts all file entries.
    private func parseZipData(_ data: Data) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var index = 0

        while index < data.count {
            // Check for local file header signature
            guard index + 4 <= data.count else { break }
            let signature = data.readUInt32(at: index)
            guard signature == 0x04034b50 else {
                // Not a local file header, try to find the next one
                index += 1
                continue
            }

            // Parse local file header
            let fileNameLength = Int(data.readUInt16(at: index + 26))
            let extraLength = Int(data.readUInt16(at: index + 28))
            let compressedSize = Int(data.readUInt32(at: index + 18))

            let fileNameStart = index + 30
            let fileNameEnd = fileNameStart + fileNameLength
            let dataStart = fileNameEnd + extraLength
            let dataEnd = dataStart + compressedSize

            guard fileNameEnd <= data.count, dataEnd <= data.count else { break }

            let fileName = String(data: data.subdata(in: fileNameStart..<fileNameEnd), encoding: .utf8) ?? "file"
            let fileData = data.subdata(in: dataStart..<dataEnd)

            let isPhoto = isImageFile(fileName)
            entries.append(ZipEntry(fileName: fileName, data: fileData, isPhoto: isPhoto))

            index = dataEnd
        }

        guard !entries.isEmpty else {
            throw ZipError.invalidArchive
        }

        return entries
    }

    private func isImageFile(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "webp"].contains(ext)
    }

    // MARK: - Encryption

    /// Encrypts ZIP data with AES-256-GCM using a key derived from the password.
    private func encryptZipData(_ data: Data, password: String) throws -> Data {
        let key = try deriveKey(from: password)
        let sealedBox = try AES.GCM.seal(data, using: key)

        // Format: [magic][version][nonce][ciphertext+tag]
        var result = Data()
        result.append("VPNZIP".data(using: .utf8)!)
        result.appendUInt16(1) // Version
        result.append(Data(sealedBox.nonce))
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        return result
    }

    /// Decrypts ZIP data with AES-256-GCM using a key derived from the password.
    private func decryptZipData(_ data: Data, password: String) throws -> Data {
        // Check magic bytes
        let magic = "VPNZIP".data(using: .utf8)!
        guard data.count > magic.count + 2 + 12 + 16,
              data.prefix(magic.count) == magic else {
            throw ZipError.invalidArchive
        }

        // Skip magic + version
        var offset = magic.count + 2

        // Read nonce
        let nonce = data.subdata(in: offset..<(offset + 12))
        offset += 12

        // Read ciphertext + tag
        let ciphertextAndTag = data.subdata(in: offset..<data.count)

        let key = try deriveKey(from: password)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertextAndTag.dropLast(16),
            tag: ciphertextAndTag.suffix(16)
        )

        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Derives a 256-bit key from the password using HKDF-SHA256.
    private func deriveKey(from password: String) throws -> SymmetricKey {
        let salt = "com.vpnhide.zip.export.salt".data(using: .utf8)!
        let passwordData = password.data(using: .utf8)!

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: salt,
            info: "VpnHideZipExport".data(using: .utf8)!,
            outputByteCount: 32
        )
    }
}

// MARK: - Data Extensions for Binary Reading/Writing

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let bytes = [self[offset], self[offset + 1]]
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let bytes = [self[offset], self[offset + 1], self[offset + 2], self[offset + 3]]
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }
}