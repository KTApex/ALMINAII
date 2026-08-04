import AVFoundation
import CoreMotion
import Foundation
import SwiftUI
import UIKit

// MARK: - Intruder Log Entry

/// A single security-log entry created when the front camera captures
/// an intruder after repeated failed passcode attempts.
struct IntruderLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let imageFileName: String
    let failureCount: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        imageFileName: String,
        failureCount: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.imageFileName = imageFileName
        self.failureCount = failureCount
    }
}

// MARK: - Security Manager

/// Handles:
///  - Intruder front-camera selfie capture after 3 failed PIN attempts.
///  - Emergency face-down / shake lock using CoreMotion + UIDevice orientation.
///  - Secure storage of intruder photos and the security log in the app's
///    Application Support directory (encrypted with AES-GCM).
///  - Obfuscated storage reporting ("Network Cache") so vault size is hidden
///    from casual device inspection.
final class SecurityManager: ObservableObject {

    static let shared = SecurityManager()

    // MARK: - Published

    @Published var intruderLog: [IntruderLogEntry] = []
    @Published var isMonitoringMotion = false

    // MARK: - Private

    private let motionManager = CMMotionManager()
    private let fileManager = FileManager.default
    private let crypto = CryptoManager.shared
    private let logFileName = "security_log.json"

    /// Lockout threshold for intruder capture.
    private let maxFailedAttempts = 3

    // MARK: - Lockout

    /// Number of seconds for the lockout after 3 failed attempts.
    let lockoutDurationSeconds = 30

    /// Current consecutive failed PIN attempts.
    var failedAttempts: Int {
        failedAttemptCount()
    }

    /// True when the vault is in the post-intruder lockout period.
    var isLockedOut: Bool {
        let lockoutEndsAt = UserDefaults.standard.object(forKey: "security.lockoutEndsAt") as? Date ?? Date()
        return Date() < lockoutEndsAt
    }

    /// Seconds remaining in the lockout period (0 if not locked out).
    func lockoutSecondsRemaining() -> Int {
        guard let lockoutEndsAt = UserDefaults.standard.object(forKey: "security.lockoutEndsAt") as? Date else {
            return 0
        }
        return max(0, Int(lockoutEndsAt.timeIntervalSinceNow))
    }

    /// Clears the lockout period (called when the countdown finishes).
    func endLockout() {
        UserDefaults.standard.removeObject(forKey: "security.lockoutEndsAt")
    }

    // MARK: - Motion Tracking

    /// Device flipped face-down (screen facing the ground).
    private var isFaceDown = false

    /// Last recorded acceleration for shake detection.
    private var lastAcceleration: CMAcceleration?

    /// Total accumulated "shakeness" before triggering a lock.
    private var shakeAccumulator: Double = 0
    private var lastShakeUpdate = Date()

    // MARK: - Callbacks

    /// Invoked on the main thread when the emergency lock should fire.
    var onEmergencyLock: (() -> Void)?

    private init() {
        loadLog()
    }

    // MARK: - Directory

    /// Private security directory inside Application Support.
    var securityDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("VpnHide/Security", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var logFileURL: URL {
        securityDir.appendingPathComponent(logFileName)
    }

    // MARK: - Failure Tracking

    /// Called from PasscodeView when a PIN attempt fails.
    /// On the 3rd consecutive failure, silently captures the intruder's face
    /// using the front camera and appends a Security Log entry.
    @discardableResult
    func registerFailedAttempt() -> Bool {
        let currentCount = failedAttemptCount() + 1
        UserDefaults.standard.set(currentCount, forKey: "security.failedAttempts")

        guard currentCount >= maxFailedAttempts else {
            return false
        }

        // Start the lockout period immediately (even if camera capture fails).
        beginLockout()

        // Capture intruder silently (no UI revealed).
        captureIntruderPhoto { [weak self] _ in
            // Keep the failed counter for UI display.
            _ = self
        }
        return true
    }

    /// Starts a 30-second lockout period after the intruder capture.
    private func beginLockout() {
        let lockoutEndsAt = Date().addingTimeInterval(TimeInterval(lockoutDurationSeconds))
        UserDefaults.standard.set(lockoutEndsAt, forKey: "security.lockoutEndsAt")
    }

    /// Called from PasscodeView when the correct PIN is entered.
    func resetFailedAttempts() {
        UserDefaults.standard.set(0, forKey: "security.failedAttempts")
    }

    private func failedAttemptCount() -> Int {
        UserDefaults.standard.integer(forKey: "security.failedAttempts")
    }

    // MARK: - Intruder Capture

    /// Captures a front-camera still silently, encrypts it, and appends a log entry.
    func captureIntruderPhoto(completion: @escaping (Bool) -> Void) {
        guard checkCameraPermission() else {
            completion(false)
            return
        }

        // Use AVCapturePhotoOutput on a private session so no UI is shown.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )

        guard let device = discovery.devices.first else {
            completion(false)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            session.sessionPreset = .photo
            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCapturePhotoOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            session.startRunning()

            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off

            let delegate = IntruderPhotoCaptureDelegate(
                session: session,
                settings: settings,
                handler: { [weak self] imageData in
                    guard let self, let imageData else {
                        completion(false)
                        return
                    }
                    self.storeIntruderImage(imageData)
                    completion(true)
                }
            )

            // Keep the delegate alive until capture completes.
            activeCaptureDelegate = delegate
            output.capturePhoto(with: settings, delegate: delegate)
        } catch {
            completion(false)
        }
    }

    /// The currently-active capture delegate (retained for the async callback).
    private var activeCaptureDelegate: IntruderPhotoCaptureDelegate?

    private func checkCameraPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            // Request synchronously for a silent capture.
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { success in
                granted = success
                semaphore.signal()
            }
            semaphore.wait()
            return granted
        default:
            return false
        }
    }

    // MARK: - Store Intruder Image

    private func storeIntruderImage(_ imageData: Data) {
        // Downsample to reduce storage footprint.
        guard let original = UIImage(data: imageData),
              let resized = downsample(image: original, to: CGSize(width: 640, height: 640)),
              let jpgData = resized.jpegData(compressionQuality: 0.6) else {
            return
        }

        do {
            let encrypted = try crypto.encrypt(jpgData)
            let fileName = "intruder_\(UUID().uuidString).enc"
            let fileURL = securityDir.appendingPathComponent(fileName)
            try encrypted.write(to: fileURL, options: .atomic)

            let entry = IntruderLogEntry(
                imageFileName: fileName,
                failureCount: maxFailedAttempts
            )
            intruderLog.append(entry)
            saveLog()
        } catch {
            // Silent failure — never reveal vault activity.
        }
    }

    private func downsample(image: UIImage, to targetSize: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Decrypts and returns an intruder photo for the Security Log viewer.
    func intruderImage(for entry: IntruderLogEntry) -> UIImage? {
        let url = securityDir.appendingPathComponent(entry.imageFileName)
        guard let encrypted = try? Data(contentsOf: url),
              let decrypted = try? crypto.decrypt(encrypted) else {
            return nil
        }
        return UIImage(data: decrypted)
    }

    // MARK: - Security Log Persistence

    private func loadLog() {
        guard let data = try? Data(contentsOf: logFileURL) else { return }
        intruderLog = (try? JSONDecoder().decode([IntruderLogEntry].self, from: data)) ?? []
    }

    func saveLog() {
        guard let data = try? JSONEncoder().encode(intruderLog) else { return }
        try? data.write(to: logFileURL, options: .atomic)
    }

    // MARK: - Emergency Motion Lock (Face-Down / Shake)

    /// Starts CoreMotion accelerometer monitoring + device orientation observer.
    /// Triggers `onEmergencyLock` when the device is flipped face-down or shaken.
    func startEmergencyMonitoring() {
        guard !isMonitoringMotion else { return }

        // CoreMotion acceleration for shake detection
        guard motionManager.isAccelerometerAvailable else { return }

        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.processAcceleration(data.acceleration)
        }

        // Device orientation (UIDevice) for face-down detection
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        isMonitoringMotion = true
    }

    /// Stops all motion monitoring.
    func stopEmergencyMonitoring() {
        guard isMonitoringMotion else { return }
        motionManager.stopAccelerometerUpdates()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        isMonitoringMotion = false
        shakeAccumulator = 0
        lastAcceleration = nil
        isFaceDown = false
    }

    // MARK: - Acceleration Processing (Shake)

    private func processAcceleration(_ acceleration: CMAcceleration) {
        guard let last = lastAcceleration else {
            lastAcceleration = acceleration
            return
        }

        // Shake detection via high-pass filtered magnitude.
        let dx = acceleration.x - last.x
        let dy = acceleration.y - last.y
        let dz = acceleration.z - last.z
        let magnitude = sqrt(dx * dx + dy * dy + dz * dz)

        let now = Date()
        let deltaTime = now.timeIntervalSince(lastShakeUpdate)

        // Accumulate "shake energy" while a shake is in progress.
        if magnitude > 0.8 {
            shakeAccumulator += magnitude * (deltaTime > 0 ? min(deltaTime, 1) : 1)
        } else {
            // Slightly decay the accumulator when the shake stops.
            shakeAccumulator *= 0.5
        }

        lastShakeUpdate = now
        lastAcceleration = acceleration

        // An aggressive shake (accumulated > 6.0) triggers the emergency lock.
        if shakeAccumulator > 6.0 {
            shakeAccumulator = 0
            triggerEmergencyLock(reason: "shake")
        }
    }

    // MARK: - Orientation Processing (Face-Down)

    @objc private func handleOrientationChange() {
        let device = UIDevice.current
        let isNowFaceDown = device.orientation == .faceDown

        guard isNowFaceDown != isFaceDown else { return }
        isFaceDown = isNowFaceDown

        if isFaceDown {
            triggerEmergencyLock(reason: "faceDown")
        }
    }

    // MARK: - Emergency Lock

    private func triggerEmergencyLock(reason: String) {
        // Post a disguised network alert so no security/vault activity is revealed.
        NotificationCenter.default.post(
            name: .vpnHideShouldPostDisguisedAlert,
            object: nil
        )

        // Move the app back to the VPN mask screen.
        DispatchQueue.main.async { [weak self] in
            self?.onEmergencyLock?()
        }
    }

    // MARK: - Obfuscated Storage Reporting

    /// Returns a disguised "Network Cache" storage size that hides real vault size.
    /// The real encrypted vault media is never reported.
    func obfuscatedStorageStatus() -> (label: String, detail: String) {
        // We intentionally report a small, routine "network cache" figure
        // instead of the real vault footprint.
        let fakeCacheBytes = Int64.random(in: 8_000_000...28_000_000) // 8–28 MB
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeString = formatter.string(fromByteCount: fakeCacheBytes)

        return (
            label: "Network Cache",
            detail: "\(sizeString) — managed automatically"
        )
    }

    /// Helper: computes the REAL encrypted vault size (used internally by backup logic).
    func actualVaultSize() -> Int64 {
        let mediaDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VpnHide/Media", isDirectory: true)

        guard let files = try? fileManager.contentsOfDirectory(
            at: mediaDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        return files.reduce(Int64(0)) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return partial + Int64(size)
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// Fired when a disguised "network" local notification should be posted.
    static let vpnHideShouldPostDisguisedAlert = Notification.Name("vpnHide.shouldPostDisguisedAlert")
}

// MARK: - Intruder Photo Capture Delegate

/// Retained by SecurityManager while a silent front-camera capture is in flight.
private final class IntruderPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let session: AVCaptureSession
    private let settings: AVCapturePhotoSettings
    private let handler: (Data?) -> Void

    init(
        session: AVCaptureSession,
        settings: AVCapturePhotoSettings,
        handler: @escaping (Data?) -> Void
    ) {
        self.session = session
        self.settings = settings
        self.handler = handler
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        session.stopRunning()
        handler(data)
    }
}

// MARK: - Intruder Log View

/// SwiftUI view for browsing the hidden Security Log (intruder selfies).
struct IntruderLogView: View {
    @ObservedObject var security: SecurityManager
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if security.intruderLog.isEmpty {
                    emptyState
                } else {
                    logList
                }
            }
            .navigationTitle("Security Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("No Intruder Detected")
                .font(.headline)
                .foregroundColor(.white)
            Text("Photos are captured silently after 3 failed\nPIN attempts.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }

    private var logList: some View {
        List {
            ForEach(security.intruderLog) { entry in
                HStack(spacing: 12) {
                    if let image = security.intruderImage(for: entry) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 56, height: 56)
                            .overlay(Image(systemName: "person.crop.circle.badge.questionmark"))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Intruder Captured")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                        Text(dateFormatter.string(from: entry.timestamp))
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("\(entry.failureCount) failed attempts")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete(perform: deleteEntries)
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.05, green: 0.07, blue: 0.12))
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            let entry = security.intruderLog[index]
            let url = security.securityDir.appendingPathComponent(entry.imageFileName)
            try? FileManager.default.removeItem(at: url)
        }
        security.intruderLog.remove(atOffsets: offsets)
        security.saveLog()
    }
}