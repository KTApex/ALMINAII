import AVFoundation
import AVKit
import SwiftUI

// MARK: - Slideshow Speed (Timer Control)

enum SlideshowSpeed: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case normal = "Normal"
    case slow = "Slow"
    case verySlow = "Very Slow"

    var id: String { rawValue }

    /// Photo display duration in seconds.
    var duration: Double {
        switch self {
        case .fast: return 2
        case .normal: return 3
        case .slow: return 5
        case .verySlow: return 10
        }
    }

    var shortLabel: String {
        "\(Int(duration))s"
    }

    var icon: String {
        switch self {
        case .fast: return "hare.fill"
        case .normal: return "gauge"
        case .slow: return "tortoise.fill"
        case .verySlow: return "hourglass"
        }
    }
}

// MARK: - Slideshow Transition (Animation Styles)

enum SlideshowTransition: String, CaseIterable, Identifiable {
    case slide = "Slide"
    case crossfade = "Crossfade"
    case kenBurns = "Ken Burns"
    case flip = "Flip"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .slide: return "arrow.left.arrow.right"
        case .crossfade: return "circle.lefthalf.filled"
        case .kenBurns: return "viewfinder"
        case .flip: return "rotate.3d"
        }
    }

    /// The SwiftUI transition applied when advancing to the next item.
    var transition: AnyTransition {
        switch self {
        case .slide:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .crossfade:
            return .opacity
        case .kenBurns:
            return .opacity.combined(with: .scale(scale: 0.94))
        case .flip:
            return .asymmetric(
                insertion: .modifier(
                    active: FlipCardTransition(angle: 90),
                    identity: FlipCardTransition(angle: 0)
                ),
                removal: .modifier(
                    active: FlipCardTransition(angle: -90),
                    identity: FlipCardTransition(angle: 0)
                )
            )
        }
    }
}

/// 3D flip effect used for the "Flip" transition.
struct FlipCardTransition: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0))
            .opacity(angle == 0 ? 1 : 0.15)
    }
}

// MARK: - Main Slideshow View

/// Fully customizable auto-slideshow engine.
///
/// - **Speed / Timer Control:** Photos advance on a user-selectable timer
///   (Fast: 2s, Normal: 3s, Slow: 5s, Very Slow: 10s).
/// - **Transition Models:** Slide, Smooth Crossfade, Ken Burns Zoom, or Flip/Cube.
/// - **Smart Media Playback:** Videos auto-play on arrival, pause the photo timer,
///   and auto-advance only when playback completes (AVPlayerItemDidPlayToEndTime).
/// - **Control Overlay:** Translucent overlay with Play/Pause, speed picker,
///   transition switcher, and a live progress bar.
struct SlideshowView: View {
    let items: [VaultItem]
    @ObservedObject var storage: VaultStorageManager

    @Environment(\.dismiss) private var dismiss

    // MARK: Navigation state

    @State private var currentIndex = 0
    @State private var isPlaying = true
    @State private var progress: Double = 0

    // MARK: Persisted settings (survive app restarts)

    @AppStorage("slideshow.speed") private var speedRaw = SlideshowSpeed.normal.rawValue
    @AppStorage("slideshow.transition") private var transitionRaw = SlideshowTransition.crossfade.rawValue

    // MARK: UI state

    @State private var isControlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    /// Drives the photo auto-advance timer and progress bar (60 fps).
    private let tickTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var speed: SlideshowSpeed {
        SlideshowSpeed(rawValue: speedRaw) ?? .normal
    }

    private var transition: SlideshowTransition {
        SlideshowTransition(rawValue: transitionRaw) ?? .crossfade
    }

    // MARK: Body

    var body: some View {
        ZStack {
            if items.isEmpty {
                emptyState
            } else {
                slideshowBody
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    private var slideshowBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Current media with animated transition
            currentMediaView
                .id(items[currentIndex].id)
                .transition(transition.transition)

            // Tap-to-toggle layer (below controls, above media)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            // Translucent control overlay
            controlOverlay
                .opacity(isControlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: isControlsVisible)
        }
        .animation(.easeInOut(duration: 0.45), value: currentIndex)
        .onReceive(tickTimer) { _ in
            handleTick()
        }
        .onChange(of: currentIndex) { _ in
            progress = 0
        }
        .onAppear {
            isControlsVisible = true
            scheduleControlsHide()
        }
    }

    // MARK: - Media Switching Engine

    @ViewBuilder
    private var currentMediaView: some View {
        if currentIndex < items.count {
            let item = items[currentIndex]
            if item.mediaType == .photo {
                PhotoSlideshowView(
                    item: item,
                    storage: storage,
                    kenBurnsEnabled: transition == .kenBurns,
                    kenBurnsDuration: speed.duration
                )
            } else {
                VideoSlideshowView(
                    item: item,
                    storage: storage,
                    isPlaying: isPlaying,
                    onProgress: { videoProgress in
                        progress = videoProgress
                    },
                    onEnded: { onVideoEnded() }
                )
            }
        }
    }

    /// Tick handler — advances photos based on the selected speed.
    /// Videos manage their own progress and auto-advance via the completion observer.
    private func handleTick() {
        guard isPlaying, currentIndex < items.count else { return }
        let item = items[currentIndex]

        // Videos report their own progress / completion — skip photo timer logic.
        guard item.mediaType == .photo else { return }

        progress += 0.05 / speed.duration
        if progress >= 1.0 {
            progress = 0
            advance()
        }
    }

    /// Called when a video reaches the end (AVPlayerItemDidPlayToEndTime).
    /// Only auto-advances if the slideshow is still playing at that moment.
    private func onVideoEnded() {
        guard isPlaying else { return }
        advance()
    }

    private func advance() {
        guard isPlaying, !items.isEmpty else { return }
        progress = 0
        if currentIndex < items.count - 1 {
            currentIndex += 1
        } else {
            currentIndex = 0
        }
        scheduleControlsHide()
    }

    // MARK: - Control Overlay

    private var controlOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomControls
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }

            Spacer()

            VStack(spacing: 2) {
                Text("\(currentIndex + 1) / \(items.count)")
                    .font(.subheadline.bold())
                if currentIndex < items.count {
                    Text(items[currentIndex].displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.45)))

            Spacer()

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
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.75), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            // Live progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(6, geo.size.width * progress))
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.05), value: progress)

            HStack(spacing: 12) {
                // Previous (wraps around)
                stepButton(systemImage: "chevron.left", step: -1)

                Spacer()

                // Speed / Timer picker
                speedPicker

                Spacer()

                // Play / Pause
                Button {
                    togglePlayPause()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                }

                Spacer()

                // Transition model picker
                transitionPicker

                Spacer()

                // Next (wraps around)
                stepButton(systemImage: "chevron.right", step: 1)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.75), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }

    private func stepButton(systemImage: String, step: Int) -> some View {
        Button {
            progress = 0
            let count = items.count
            guard count > 0 else { return }
            let target = currentIndex + step
            currentIndex = ((target % count) + count) % count
            scheduleControlsHide()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.16)))
        }
    }

    private var speedPicker: some View {
        Menu {
            ForEach(SlideshowSpeed.allCases) { option in
                Button {
                    speedRaw = option.rawValue
                    progress = 0
                    scheduleControlsHide()
                } label: {
                    if speed == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: speed.icon)
                    .font(.system(size: 18, weight: .medium))
                Text(speed.shortLabel)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundColor(.white)
            .frame(width: 50, height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.16)))
        }
    }

    private var transitionPicker: some View {
        Menu {
            ForEach(SlideshowTransition.allCases) { option in
                Button {
                    transitionRaw = option.rawValue
                    scheduleControlsHide()
                } label: {
                    if transition == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: transition.icon)
                    .font(.system(size: 18, weight: .medium))
                Text(transition.rawValue)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundColor(.white)
            .frame(width: 58, height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.16)))
        }
    }

    // MARK: - Actions

    private func togglePlayPause() {
        isPlaying.toggle()
        hideTask?.cancel()
        scheduleControlsHide()
    }

    private func toggleControls() {
        if isControlsVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.25)) {
                isControlsVisible = false
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                isControlsVisible = true
            }
            scheduleControlsHide()
        }
    }

    /// Auto-hides the control overlay after 4 seconds of inactivity.
    private func scheduleControlsHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isControlsVisible = false
                }
            }
        }
    }

    private func deleteCurrentItem() {
        guard currentIndex < items.count else { return }
        storage.deleteItems([items[currentIndex]])
        dismiss()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("No media to display")
                .font(.headline)
                .foregroundColor(.white)
            Button("Close") {
                dismiss()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
        }
    }
}

// MARK: - Photo Slide

/// Single photo slide. Supports Ken Burns (slow zoom) when enabled.
struct PhotoSlideshowView: View {
    let item: VaultItem
    @ObservedObject var storage: VaultStorageManager
    var kenBurnsEnabled: Bool = false
    var kenBurnsDuration: Double = 8

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var kenBurnsActive = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = image {
                    if kenBurnsEnabled {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .scaleEffect(kenBurnsActive ? 1.18 : 1.0)
                            .offset(
                                x: kenBurnsActive ? -geo.size.width * 0.02 : geo.size.width * 0.02,
                                y: kenBurnsActive ? -geo.size.height * 0.02 : geo.size.height * 0.02
                            )
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: kenBurnsEnabled) { isEnabled in
            guard image != nil else { return }
            if isEnabled {
                startKenBurns()
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    kenBurnsActive = false
                }
            }
        }
    }

    private func startKenBurns() {
        withAnimation(.easeInOut(duration: kenBurnsDuration)) {
            kenBurnsActive = true
        }
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let decryptedImage = storage.thumbnail(for: item)
            DispatchQueue.main.async {
                image = decryptedImage
                isLoading = false
                if kenBurnsEnabled {
                    startKenBurns()
                }
            }
        }
    }
}

// MARK: - Video Slide

/// Single video slide. Auto-plays on arrival, reports playback progress to the
/// parent progress bar, and fires `onEnded` when AVPlayerItemDidPlayToEndTime fires.
struct VideoSlideshowView: View {
    let item: VaultItem
    @ObservedObject var storage: VaultStorageManager
    var isPlaying: Bool
    var onProgress: (Double) -> Void
    var onEnded: () -> Void

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var didFail = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
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
            cleanup()
        }
        .onChange(of: isPlaying) { playing in
            guard let player = player else { return }
            if playing {
                player.play()
            } else {
                player.pause()
            }
        }
    }

    private func loadVideo() {
        isLoading = true
        didFail = false
        cleanup()

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

                // Playback progress → parent progress bar
                self.timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                    queue: .main
                ) { time in
                    guard let duration = player.currentItem?.duration.seconds,
                          duration.isFinite, duration > 0 else { return }
                    onProgress(min(max(time.seconds / duration, 0), 1))
                }

                // Video completion → parent auto-advance
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: player.currentItem,
                    queue: .main
                ) { _ in
                    onProgress(1)
                    onEnded()
                }

                self.isLoading = false
                if isPlaying {
                    player.play()
                }
            }
        }
    }

    private func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
    }
}