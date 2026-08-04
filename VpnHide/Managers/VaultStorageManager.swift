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
    private var vaultMediaDir: URL {
        let dir = vaultAppSupportDir.appendingPathComponent("Media", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Directory for decoy (fake) vault media.
    private var decoyMediaDir: URL {
        let dir = vaultAppSupportDir.appendingPathComponent("Decoy", isDirectory: true)
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

    private func saveMetadata() {
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
    func importMedia(from url: URL, isDecoy: Bool = false) throws {
        let data = try Data(contentsOf: url)
        let encryptedData = try crypto.encrypt(data)

        let originalName = url.lastPathComponent
        let ext = (originalName as NSString).pathExtension.lowercased()
        let mediaType: VaultMediaType = (ext == "mp4" || ext == "mov" || ext == "m4v") ? .video : .photo

        // Get video duration if it's a video
        var duration: Double = 0
        if mediaType == .video {
            let asset = AVURLAsset(url: url)
            duration = CMTimeGetSeconds(asset.duration)
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

    /// Decrypts a vault item and returns the raw media data.
    func decryptItem(_ item: VaultItem) -> Data? {
        let dir = item.isDecoy ? decoyMediaDir : vaultMediaDir
        let url = dir.appendingPathComponent(item.encryptedFileName)
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

    // MARK: - Delete

    func deleteItems(_ items: [VaultItem]) {
        for item in items {
            let dir = item.isDecoy ? decoyMediaDir : vaultMediaDir
            let url = dir.appendingPathComponent(item.encryptedFileName)
            try? fileManager.removeItem(at: url)

            if item.isDecoy {
                decoyItems.removeAll { $0.id == item.id }
            } else {
                vaultItems.removeAll { $0.id == item.id }
            }
        }
        saveMetadata()
    }

    // MARK: - Clear All

    func clearVault() {
        try? fileManager.removeItem(at: vaultMediaDir)
        try? fileManager.removeItem(at: decoyMediaDir)
        vaultItems = []
        decoyItems = []
        saveMetadata()
    }
}