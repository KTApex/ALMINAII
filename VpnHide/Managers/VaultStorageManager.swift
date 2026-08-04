import AVFoundation
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Manages encrypted storage of vault media in the app's Application Support directory.
/// All files are encrypted with AES-GCM via CryptoManager before being written to disk.
final class VaultStorageManager: ObservableObject {

    static let shared = VaultStorageManager()

    // MARK: - Published

    @Published var vaultItems: [VaultItem] = []
    @Published var decoyItems: [VaultItem] = []
    @Published var albums: [VaultAlbum] = []
    @Published var trashedItems: [VaultItem] = []
    @Published var decoyTrashedItems: [VaultItem] = []

    /// 30-day retention period for the recycle bin.
    let trashRetentionDays = 30

    // MARK: - Private

    private let crypto = CryptoManager.shared
    private let fileManager = FileManager.default
    private let metadataFileName = "vault_metadata.json"
    private let decoyMetadataFileName = "decoy_metadata.json"
    private let albumsFileName = "vault_albums.json"

    private init() {
        loadMetadata()
        loadAlbums()
    }

    // MARK: - Directory Paths

    /// Root Application Support directory for the app.
    private var vaultAppSupportDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("VpnHide", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Directory for encrypted vault media.
    func encryptedMediaDir() -> URL {
        let dir = vaultAppSupportDir.appendingPathComponent("Media", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Backwards-compatible alias for `encryptedMediaDir()`.
    private var vaultMediaDir: URL {
        encryptedMediaDir()
    }

    /// Directory for decoy (fake) vault media.
    private var decoyMediaDir: URL {
        let dir = vaultAppSupportDir.appendingPathComponent("Decoy", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Directory for trashed vault media.
    private var trashMediaDir: URL {
        let dir = vaultAppSupportDir.appendingPathComponent("Trash", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Metadata Persistence

    private var metadataFileURL: URL {
        vaultAppSupportDir.appendingPathComponent(metadataFileName)
    }

    private var decoyMetadataFileURL: URL {
        vaultAppSupportDir.appendingPathComponent(decoyMetadataFileName)
    }

    private var albumsFileURL: URL {
        vaultAppSupportDir.appendingPathComponent(albumsFileName)
    }

    private func loadMetadata() {
        vaultItems = loadItems(from: metadataFileURL)
        decoyItems = loadItems(from: decoyMetadataFileURL)

        // Load trashed items and purge any past 30 days
        let allItems = vaultItems + decoyItems
        trashedItems = allItems.filter { $0.isTrashed }
        purgeExpiredTrash()
    }

    // MARK: - Album Management

    private func loadAlbums() {
        guard let data = try? Data(contentsOf: albumsFileURL) else {
            // Seed default albums on first launch
            albums = [
                VaultAlbum(name: "Personal", icon: "person.fill"),
                VaultAlbum(name: "Documents", icon: "doc.fill"),
                VaultAlbum(name: "Favorites", icon: "star.fill")
            ]
            saveAlbums()
            return
        }
        let decoder = JSONDecoder()
        albums = (try? decoder.decode([VaultAlbum].self, from: data)) ?? []
    }

    private func saveAlbums() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(albums) else { return }
        try? data.write(to: albumsFileURL, options: .atomic)
    }

    func createAlbum(name: String, icon: String = "folder.fill") {
        let album = VaultAlbum(name: name, icon: icon)
        albums.append(album)
        saveAlbums()
    }

    func deleteAlbum(_ album: VaultAlbum) {
        albums.removeAll { $0.id == album.id }
        // Remove album reference from items
        for index in vaultItems.indices where vaultItems[index].albumID == album.id {
            vaultItems[index].albumID = nil
        }
        saveAlbums()
        saveMetadata()
    }

    func renameAlbum(_ album: VaultAlbum, to newName: String) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        albums[index].name = newName
        saveAlbums()
    }

    func moveItems(_ items: [VaultItem], to album: VaultAlbum?) {
        for item in items {
            if let index = vaultItems.firstIndex(where: { $0.id == item.id }) {
                vaultItems[index].albumID = album?.id
            }
        }
        saveMetadata()
    }

    private func loadItems(from url: URL) -> [VaultItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([VaultItem].self, from: data)) ?? []
    }

    func saveMetadata() {
        saveItems(vaultItems, to: metadataFileURL)
        saveItems(decoyItems, to: decoyMetadataFileURL)
    }

    private func saveItems(_ items: [VaultItem], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Import Media

    /// Imports a photo/video from the Photos library, encrypts it, and stores it in the vault.
    func importMedia(from url: URL, isDecoy: Bool = false) async throws {
        let data = try Data(contentsOf: url)
        let encryptedData = try crypto.encrypt(data)

        let originalName = url.lastPathComponent
        let ext = (originalName as NSString).pathExtension.lowercased()
        let mediaType: VaultMediaType = (ext == "mp4" || ext == "mov" || ext == "m4v") ? .video : .photo

        // Get video duration if it's a video (using the modern async API)
        var duration: Double = 0
        if mediaType == .video {
            let asset = AVURLAsset(url: url)
            duration = try await asset.load(.duration).seconds
        }

        let encryptedFileName = "\(UUID().uuidString).enc"
        let targetDir = isDecoy ? decoyMediaDir : vaultMediaDir
        let targetURL = targetDir.appendingPathComponent(encryptedFileName)
        try encryptedData.write(to: targetURL, options: .atomic)

        let item = VaultItem(
            fileName: originalName,
            encryptedFileName: encryptedFileName,
            mediaType: mediaType,
            fileSize: Int64(data.count),
            duration: duration,
            isDecoy: isDecoy
        )

        if isDecoy {
            decoyItems.append(item)
        } else {
            vaultItems.append(item)
        }
        saveMetadata()
    }

    // MARK: - Read / Decrypt

    /// Returns the encrypted file URL for a vault item.
    func encryptedFileURL(for item: VaultItem) -> URL {
        let dir = item.isDecoy ? decoyMediaDir : vaultMediaDir
        return dir.appendingPathComponent(item.encryptedFileName)
    }

    /// Decrypts a vault item and returns the raw media data.
    func decryptItem(_ item: VaultItem) -> Data? {
        let url = encryptedFileURL(for: item)
        guard let encryptedData = try? Data(contentsOf: url) else { return nil }
        return try? crypto.decrypt(encryptedData)
    }

    /// Returns a temporary file URL with decrypted content (for video playback).
    func decryptedFileURL(for item: VaultItem) -> URL? {
        guard let data = decryptItem(item) else { return nil }

        let tempDir = fileManager.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("\(item.id.uuidString).\(item.fileExtension)")
        try? data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    /// Returns a thumbnail image for a photo item.
    func thumbnail(for item: VaultItem) -> UIImage? {
        guard item.mediaType == .photo,
              let data = decryptItem(item) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Trash / Recycle Bin

    /// Moves items to the trash. They remain recoverable for 30 days.
    func moveToTrash(_ items: [VaultItem]) {
        let now = Date()

        for item in items {
            if let index = vaultItems.firstIndex(where: { $0.id == item.id }) {
                vaultItems[index].deletedAt = now
            }
            if let index = decoyItems.firstIndex(where: { $0.id == item.id }) {
                decoyItems[index].deletedAt = now
            }
        }

        // Move the physical files to the trash directory
        for item in items {
            let sourceURL = encryptedFileURL(for: item)
            let trashURL = trashMediaDir.appendingPathComponent(item.encryptedFileName)
            if fileManager.fileExists(atPath: sourceURL.path) {
                try? fileManager.moveItem(at: sourceURL, to: trashURL)
            }
        }

        refreshTrash()
        saveMetadata()
    }

    /// Restores items from the trash back to the main vault.
    func restoreFromTrash(_ items: [VaultItem]) {
        for item in items {
            let trashURL = trashMediaDir.appendingPathComponent(item.encryptedFileName)
            let destDir = item.isDecoy ? decoyMediaDir : vaultMediaDir
            let destURL = destDir.appendingPathComponent(item.encryptedFileName)

            if fileManager.fileExists(atPath: trashURL.path) {
                try? fileManager.moveItem(at: trashURL, to: destURL)
            }

            if let index = vaultItems.firstIndex(where: { $0.id == item.id }) {
                vaultItems[index].deletedAt = nil
            }
            if let index = decoyItems.firstIndex(where: { $0.id == item.id }) {
                decoyItems[index].deletedAt = nil
            }
        }

        refreshTrash()
        saveMetadata()
    }

    /// Permanently deletes items from the trash.
    func permanentlyDelete(_ items: [VaultItem]) {
        for item in items {
            let trashURL = trashMediaDir.appendingPathComponent(item.encryptedFileName)
            try? fileManager.removeItem(at: trashURL)

            vaultItems.removeAll { $0.id == item.id }
            decoyItems.removeAll { $0.id == item.id }
        }

        refreshTrash()
        saveMetadata()
    }

    /// Empties the entire trash immediately.
    func emptyTrash() {
        try? fileManager.removeItem(at: trashMediaDir)

        vaultItems.removeAll { $0.isTrashed }
        decoyItems.removeAll { $0.isTrashed }

        refreshTrash()
        saveMetadata()
    }

    /// Purges items that have been in the trash for more than 30 days.
    func purgeExpiredTrash() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -trashRetentionDays, to: Date()) ?? Date()
        let expired = trashedItems.filter { ($0.deletedAt ?? Date()) < cutoff }

        guard !expired.isEmpty else { return }
        permanentlyDelete(expired)
    }

    private func refreshTrash() {
        let allItems = vaultItems + decoyItems
        trashedItems = allItems.filter { $0.isTrashed }
        decoyTrashedItems = trashedItems.filter { $0.isDecoy }
    }

    // MARK: - Delete (Direct - bypasses trash)

    func deleteItems(_ items: [VaultItem]) {
        for item in items {
            let url = encryptedFileURL(for: item)
            try? fileManager.removeItem(at: url)

            if item.isDecoy {
                decoyItems.removeAll { $0.id == item.id }
            } else {
                vaultItems.removeAll { $0.id == item.id }
            }
        }
        refreshTrash()
        saveMetadata()
    }

    // MARK: - Clear All

    func clearVault() {
        try? fileManager.removeItem(at: vaultMediaDir)
        try? fileManager.removeItem(at: decoyMediaDir)
        try? fileManager.removeItem(at: trashMediaDir)
        vaultItems = []
        decoyItems = []
        trashedItems = []
        decoyTrashedItems = []
        saveMetadata()
    }

    // MARK: - Storage

    /// Returns the REAL encrypted storage size (used by backup logic only).
    func actualStorageBytes() -> Int64 {
        let dirs = [vaultMediaDir, decoyMediaDir, trashMediaDir]
        var total: Int64 = 0

        for dir in dirs {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            total += files.reduce(Int64(0)) { partial, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return partial + Int64(size)
            }
        }
        return total
    }
}