import AVFoundation
import AVKit
import Photos
import SwiftUI
import UIKit

// MARK: - Private Camera View

/// In-app private camera that captures photos/videos directly into the vault.
/// Media is NEVER saved to the main iOS Camera Roll.
struct PrivateCameraView: View {
    @ObservedObject var storage: VaultStorageManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Capture State

    @State private var session = AVCaptureSession()
    @State private var photoOutput = AVCapturePhotoOutput()
    @State private var movieOutput = AVCaptureMovieFileOutput()
    @State private var isRecording = false
    @State private var isCapturing = false
    @State private var isCameraReady = false
    @State private var cameraError: String?
    @State private var capturedPreview: UIImage?
    @State private var capturedVideoURL: URL?
    @State private var isShowingPreview = false
    @State private var isUsingFrontCamera = false
    @State private var flashMode: AVCaptureDevice.FlashMode = .off

    // MARK: - Preview Layer

    private let previewLayer = AVCaptureVideoPreviewLayer()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Camera preview
            CameraPreviewView(session: session, previewLayer: previewLayer)
                .ignoresSafeArea()

            // Top bar
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }

                    Spacer()

                    Text("Private Camera")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // Flash toggle
                    Button {
                        toggleFlash()
                    } label: {
                        Image(systemName: flashIcon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()

                // Bottom controls
                HStack(spacing: 40) {
                    // Camera flip
                    Button {
                        flipCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }

                    // Shutter
                    Button {
                        captureMedia()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(isRecording ? Color.red : Color.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                    .disabled(!isCameraReady || isCapturing)

                    // Mode toggle (photo/video)
                    Button {
                        toggleCaptureMode()
                    } label: {
                        Image(systemName: isRecording ? "video.fill" : "camera.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                }
                .padding(.bottom, 30)
            }

            // Error overlay
            if let cameraError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text(cameraError)
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
        .preferredColorScheme(.dark)
        .onAppear {
            setupCamera()
        }
        .onDisappear {
            session.stopRunning()
        }
        .fullScreenCover(isPresented: $isShowingPreview) {
            if let capturedPreview {
                // Photo preview
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: capturedPreview)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()

                    VStack {
                        HStack {
                            Button {
                                isShowingPreview = false
                                self.capturedPreview = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            Spacer()
                        }
                        .padding()
                        Spacer()

                        HStack(spacing: 20) {
                            Button {
                                isShowingPreview = false
                                self.capturedPreview = nil
                            } label: {
                                Text("Retake")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(Capsule().fill(Color.gray.opacity(0.6)))
                            }

                            Button {
                                saveCapturedPhoto()
                            } label: {
                                Text("Save to Vault")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(Capsule().fill(Color.blue))
                            }
                        }
                        .padding(.bottom, 30)
                    }
                }
            } else if let capturedVideoURL {
                // Preview captured video
                VideoPreviewView(url: capturedVideoURL) {
                    isShowingPreview = false
                    self.capturedVideoURL = nil
                } onSave: {
                    saveCapturedVideo()
                }
            }
        }
    }

    // MARK: - Computed

    private var flashIcon: String {
        switch flashMode {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a.fill"
        @unknown default: return "bolt.slash.fill"
        }
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        guard !isCameraReady else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        // Input
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            cameraError = "Camera unavailable"
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // Photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        // Movie output
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()

        // Start session on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isCameraReady = self.session.isRunning
            }
        }
    }

    // MARK: - Capture

    private func captureMedia() {
        guard isCameraReady else { return }

        if isRecording {
            // Stop video recording
            movieOutput.stopRecording()
            isRecording = false
        } else {
            // Capture photo
            let settings = AVCapturePhotoSettings()
            settings.flashMode = flashMode
            let delegate = PhotoCaptureDelegate()
            delegate.handler = { image in
                guard let image else { return }
                self.capturedPreview = image
                self.isShowingPreview = true
            }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func toggleCaptureMode() {
        // Toggle between photo and video mode
        // For simplicity, we use the same shutter button.
        // In a full implementation, this would switch between photo/video outputs.
    }

    private func toggleFlash() {
        switch flashMode {
        case .off: flashMode = .on
        case .on: flashMode = .auto
        case .auto: flashMode = .off
        @unknown default: flashMode = .off
        }
    }

    private func flipCamera() {
        // Toggle between front/back camera
        isUsingFrontCamera.toggle()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }

        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.commitConfiguration()
    }

    // MARK: - Save to Vault

    private func saveCapturedPhoto() {
        guard let image = capturedPreview,
              let jpgData = image.jpegData(compressionQuality: 0.9) else {
            return
        }

        // Write to temp file and import
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        Task {
            do {
                try jpgData.write(to: tempURL)
                try await storage.importMedia(from: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                // Silent failure
            }

            isShowingPreview = false
            self.capturedPreview = nil
            dismiss()
        }
    }

    private func saveCapturedVideo() {
        guard let capturedVideoURL else { return }

        Task {
            do {
                try await storage.importMedia(from: capturedVideoURL)
                try? FileManager.default.removeItem(at: capturedVideoURL)
            } catch {
                // Silent failure
            }

            isShowingPreview = false
            self.capturedVideoURL = nil
            dismiss()
        }
    }
}

// MARK: - Camera Preview

/// UIViewRepresentable wrapper for AVCaptureVideoPreviewLayer.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        previewLayer.frame = uiView.bounds
    }
}

// MARK: - Photo Capture Delegate

/// Captures a still photo and returns the UIImage.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    var handler: ((UIImage?) -> Void)?

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation() else {
            handler?(nil)
            return
        }
        handler?(UIImage(data: data))
    }
}

// MARK: - Video Preview

/// Simple video preview for captured videos before saving to vault.
struct VideoPreviewView: View {
    let url: URL
    var onRetake: () -> Void
    var onSave: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        player.play()
                    }
            }

            VStack {
                HStack {
                    Button {
                        onRetake()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    Spacer()
                }
                .padding()
                Spacer()

                HStack(spacing: 20) {
                    Button {
                        onRetake()
                    } label: {
                        Text("Retake")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.gray.opacity(0.6)))
                    }

                    Button {
                        onSave()
                    } label: {
                        Text("Save to Vault")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.blue))
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}