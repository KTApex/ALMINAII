import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Share Sheet Bridge

/// Bridges SwiftUI to the native iOS `UIActivityViewController`.
///
/// **Security behavior:**
///  - Media is temporarily decrypted into a secure temp cache.
///  - The native share sheet is presented.
///  - When the share sheet closes, the temp cache is **immediately purged**
///    so no decrypted media ever persists on disk.
struct ShareSheet: UIViewControllerRepresentable {

    /// The decrypted temp file URLs to share.
    let items: [URL]

    /// Called when the share sheet is dismissed (after temp cache cleanup).
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        // iPad requires a popover source.
        controller.popoverPresentationController?.sourceView = context.coordinator.hostView
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: UIScreen.main.bounds.midX,
            y: UIScreen.main.bounds.midY,
            width: 0,
            height: 0
        )

        controller.completionWithItemsHandler = { _, _, _, _ in
            // Immediately purge the temporary decrypted files.
            ShareCacheManager.shared.purgeAll()
            onDismiss?()
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        /// A hidden host view used for iPad popover anchoring.
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

// MARK: - Share Cache Manager

/// Manages the temporary decrypted media cache used for sharing.
/// Files are written here only for the duration of the share sheet,
/// then purged immediately on dismissal.
final class ShareCacheManager {

    static let shared = ShareCacheManager()

    private let fileManager = FileManager.default

    private init() {}

    /// The secure temp directory for share cache.
    private var cacheDir: URL {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("VpnHideShareCache", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Writes decrypted media data to the cache and returns its URL.
    @discardableResult
    func writeToCache(data: Data, fileName: String) -> URL? {
        let url = cacheDir.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Purges ALL files in the share cache. Called when the share sheet closes.
    func purgeAll() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
}

// MARK: - Share Helper

/// Convenience wrapper that decrypts vault items and presents the share sheet.
struct ShareHelper {

    /// Decrypts the given vault items into the temp cache and returns URLs.
    /// Returns `nil` if any item fails to decrypt.
    static func prepareShareURLs(
        for items: [VaultItem],
        storage: VaultStorageManager
    ) -> [URL]? {
        var urls: [URL] = []

        for item in items {
            guard let data = storage.decryptItem(item) else {
                // If any item fails, purge everything and abort.
                ShareCacheManager.shared.purgeAll()
                return nil
            }

            // Use a unique name to avoid collisions.
            let uniqueName = "\(item.id.uuidString).\(item.fileExtension)"
            guard let url = ShareCacheManager.shared.writeToCache(
                data: data,
                fileName: uniqueName
            ) else {
                ShareCacheManager.shared.purgeAll()
                return nil
            }
            urls.append(url)
        }

        return urls
    }
}