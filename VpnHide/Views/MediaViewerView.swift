import AVKit
import SwiftUI
import UIKit

/// Full-screen single media viewer.
/// - Photos: pinch-to-zoom, double-tap zoom, swipe to dismiss
/// - Videos: modern AVPlayer with controls
struct MediaViewerView: View {
    let item: VaultItem
    @ObservedObject var storage: VaultStorageManager

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var isDoubleTapped = false
    @State private var isLoading = true
    @State private var player: AVPlayer?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.mediaType == .photo {
                photoViewer
            } else {
                videoViewer
            }

            // Loading overlay
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text(item.mediaType == .photo ? "Decrypting..." : "Loading video...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            // Error state
            if didFail {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("Unable to load media")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    Button("Close") {
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                }
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            loadMedia()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        // Close button overlay
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .padding(.top, 8)
            .padding(.leading, 16)
        }
        // Bottom info bar
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                Text(item.displayName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 16) {
                    Text(formatDate(item.createdAt))
                    Text("•")
                    Text(formatFileSize(item.fileSize))
                    if item.mediaType == .video {
                        Text("•")
                        Text(formatDuration(item.duration))
                    }
                }
                .font(.caption)
                .foregroundColor(.gray)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: - Photo Viewer (with zoom)

    private var photoViewer: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(lastScale * value, 1.0), 5.0)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                if isDoubleTapped {
                                    scale = 1.0
                                    lastScale = 1.0
                                    isDoubleTapped = false
                                } else {
                                    scale = 2.5
                                    lastScale = 2.5
                                    isDoubleTapped = true
                                }
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onEnded { value in
                                    // Swipe down to dismiss when not zoomed
                                    if scale <= 1.0 && value.translation.height > 100 {
                                        dismiss()
                                    }
                                }
                        )
                        .animation(.easeInOut(duration: 0.2), value: scale)
                }
            }
        }
    }

    // MARK: - Video Viewer

    private var videoViewer: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        player.play()
                    }
            }
        }
    }

    // MARK: - Loading

    @State private var loadedImage: UIImage?

    private func loadMedia() {
        isLoading = true
        didFail = false

        DispatchQueue.global(qos: .userInitiated).async {
            if item.mediaType == .photo {
                let image = storage.thumbnail(for: item)
                DispatchQueue.main.async {
                    loadedImage = image
                    isLoading = false
                    didFail = (image == nil)
                }
            } else {
                guard let fileURL = storage.decryptedFileURL(for: item) else {
                    DispatchQueue.main.async {
                        isLoading = false
                        didFail = true
                    }
                    return
                }
                DispatchQueue.main.async {
                    let player = AVPlayer(url: fileURL)
                    self.player = player
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Formatting

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

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