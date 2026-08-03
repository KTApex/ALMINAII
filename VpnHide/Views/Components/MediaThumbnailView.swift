import AVKit
import SwiftUI

/// Displays a single media thumbnail in the vault grid.
/// Photos show a decrypted thumbnail; videos show a thumbnail with a play indicator.
struct MediaThumbnailView: View {
    let item: VaultItem
    @ObservedObject var storage: VaultStorageManager

    @State private var thumbnailImage: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else {
                // Placeholder while loading
                ZStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))

                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: item.mediaType == .video ? "film" : "photo")
                            .font(.system(size: 30))
                            .foregroundColor(.gray)
                    }
                }
            }

            // Video indicator
            if item.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .shadow(radius: 3)
                        Spacer()
                        Text(formatDuration(item.duration))
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                    }
                    .padding(8)
                }
            }

            // File size indicator
            VStack {
                HStack {
                    Spacer()
                    Text(formatFileSize(item.fileSize))
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(8)
                }
                Spacer()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            loadThumbnail()
        }
    }

    // MARK: - Loading

    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            if item.mediaType == .photo {
                // Photos: decrypt and show UIImage directly
                let image = storage.thumbnail(for: item)
                DispatchQueue.main.async {
                    thumbnailImage = image
                    isLoading = false
                }
            } else {
                // Videos: decrypt to temp file and generate thumbnail
                if let url = storage.decryptedFileURL(for: item) {
                    let asset = AVURLAsset(url: url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 300, height: 300)

                    Task {
                        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
                        do {
                            let cgImage = try await generator.image(at: time).image
                            let image = UIImage(cgImage: cgImage)
                            DispatchQueue.main.async {
                                thumbnailImage = image
                                isLoading = false
                            }
                        } catch {
                            DispatchQueue.main.async {
                                isLoading = false
                            }
                        }
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: url)
                    }
                } else {
                    DispatchQueue.main.async {
                        isLoading = false
                    }
                }
            }
        }
    }

    // MARK: - Formatting

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration > 0 else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}