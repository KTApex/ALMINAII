import AVKit
import SwiftUI

/// Full-screen manual slideshow view for selected vault media.
/// Users swipe left/right to navigate between items. Videos play inline.
struct SlideshowView: View {
    let items: [VaultItem]
    @ObservedObject var storage: VaultStorageManager

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0
    @State private var isControlsVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Main paged content
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    mediaView(for: item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .gesture(
                // Hide/show controls on tap
                TapGesture()
                    .onEnded {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isControlsVisible.toggle()
                        }
                    }
            )

            // Top and bottom bars
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(isControlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isControlsVisible)
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }

            Spacer()

            Text("\(currentIndex + 1) / \(items.count)")
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.5)))

            Spacer()

            // Action button (share or more)
            Menu {
                Button(role: .destructive) {
                    deleteCurrentItem()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.8), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 30) {
            // Previous
            Button {
                withAnimation {
                    currentIndex = max(0, currentIndex - 1)
                }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.9))
            }
            .disabled(currentIndex == 0)
            .opacity(currentIndex == 0 ? 0.3 : 1)

            Spacer()

            // Item info
            VStack(spacing: 4) {
                Text(items[currentIndex].displayName)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(formatDate(items[currentIndex].createdAt))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()

            // Next
            Button {
                withAnimation {
                    currentIndex = min(items.count - 1, currentIndex + 1)
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.9))
            }
            .disabled(currentIndex == items.count - 1)
            .opacity(currentIndex == items.count - 1 ? 0.3 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.8), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }

    // MARK: - Media Views

    @ViewBuilder
    private func mediaView(for item: VaultItem) -> some View {
        if item.mediaType == .photo {
            PhotoSlideshowView(item: item, storage: storage)
        } else {
            VideoSlideshowView(item: item, storage: storage)
        }
    }

    // MARK: - Actions

    private func deleteCurrentItem() {
        storage.deleteItems([items[currentIndex]])
        dismiss()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Photo Slide View

struct PhotoSlideshowView: View {
    let item: VaultItem
    @ObservedObject var storage: VaultStorageManager

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                        Text("Decrypting...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = storage.thumbnail(for: item)
            DispatchQueue.main.async {
                self.image = image
                self.isLoading = false
            }
        }
    }
}

// MARK: - Video Slide View

struct VideoSlideshowView: View {
    let item: VaultItem
    @ObservedObject var storage: VaultStorageManager

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
            } else if didFail {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("Unable to load video")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Decrypting video...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .onAppear {
            loadVideo()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadVideo() {
        isLoading = true
        didFail = false

        DispatchQueue.global(qos: .userInitiated).async {
            // Decrypt to a temporary file for playback
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