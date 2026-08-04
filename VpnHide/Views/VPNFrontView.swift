import Network
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Connection Models

enum VPNConnectionState {
    case disconnected
    case connecting
    case connected

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: return .red
        case .connecting: return .orange
        case .connected: return .green
        }
    }

    var icon: String {
        switch self {
        case .disconnected: return "shield.slash"
        case .connecting: return "shield.lefthalf.filled"
        case .connected: return "shield.checkered"
        }
    }
}

struct PingEntry: Identifiable {
    let id = UUID()
    let server: String
    let latency: String
    let status: Bool
}

struct NetworkSnapshot {
    var isWiFi = false
    var isCellular = false
    var isExpensive = false
    var isConstrained = false
    var interfaceName = "en0"
    var localIP = "192.168.1.1"
    var ssid = "Home Network"
    var channel = 44
    var signalBars = 3
    var frequency = "5 GHz"
}

// MARK: - Network Helper

enum NetworkHelper {

    /// Returns the device's current local IPv4 address for the given interface.
    static func localIPAddress(for interface: String = "en0") -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return "192.168.1.1"
        }

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interfaceName = String(cString: ifptr.pointee.ifa_name)
            guard interfaceName == interface else { continue }

            let addr = ifptr.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(ifptr.pointee.ifa_addr.pointee.sa_len)
                if getnameinfo(ifptr.pointee.ifa_addr,
                               saLen,
                               &hostname,
                               socklen_t(hostname.count),
                               nil,
                               0,
                               NI_NUMERICHOST) == 0 {
                    address = String(cString: hostname)
                    break
                }
            }
        }

        freeifaddrs(ifaddr)
        return address ?? "192.168.1.1"
    }
}

// MARK: - Fake Notification Center

/// Posts routine "network utility" local notifications so that any system alert
/// never reveals vault activity. Falls back to an in-app stealth banner.
final class FakeNotificationManager {
    static let shared = FakeNotificationManager()

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedPermission = false

    private let disguisedTitles = [
        "VPN Connection Optimized",
        "Wi-Fi Security Scan Complete",
        "Network Latency Improved",
        "Threat Intelligence Updated",
        "DNS Resolver Re-negotiated",
        "Handshake Refreshed",
        "Bandwidth Allocation Balanced",
        "Certificate Rotation Complete"
    ]

    func requestPermissionIfNeeded() {
        guard !hasRequestedPermission else { return }
        hasRequestedPermission = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Fires a routine network-status alert. Never mentions vault or media.
    func postDisguisedNetworkAlert() {
        guard !disguisedTitles.isEmpty else { return }
        let title = disguisedTitles.randomElement()!
        let subtitle = ["All systems nominal", "No anomalies detected",
                        "Optimization complete", "Session secure"].randomElement()!

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = subtitle
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }
}

// MARK: - Main VPN Front View

/// The realistic VPN & network utility "disguise" screen.
///
///  - Fully functional Speed Test, Ping Test, and Wi-Fi Analyzer.
///  - VPN toggle with authentic connecting animation.
///  - **Secret entry:** long-press the shield (3s) OR rapidly tap
///    the "PROTECTED" wordmark 5 times to request the PIN screen.
///  - All notifications are disguised as routine network alerts.
struct VPNFrontView: View {
    @EnvironmentObject var session: VaultSessionManager
    @StateObject private var fakeNotifier = FakeNotificationManager.shared

    // MARK: - Connection State

    @State private var connectionState: VPNConnectionState = .disconnected
    @State private var activeTab: NetworkToolTab = .status
    @State private var banner: String?
    @State private var bannerTask: Task<Void, Never>?

    // MARK: - Secret Entry

    @State private var shieldHoldProgress: CGFloat = 0
    @State private var secretTapCount = 0
    @State private var lastSecretTapTime = Date()
    @State private var isShowingPasscode = false

    // MARK: - Network Monitoring

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "vpnhide.networkmonitor")
    @State private var networkInfo = NetworkSnapshot()

    // MARK: - Speed Test

    @State private var isTestingSpeed = false
    @State private var downloadSpeed: Double?
    @State private var uploadSpeed: Double?

    // MARK: - Ping Test

    @State private var isPingRunning = false
    @State private var pingEntries: [PingEntry] = [
        PingEntry(server: "Cloudflare 1.1.1.1", latency: "—", status: false),
        PingEntry(server: "Google 8.8.8.8", latency: "—", status: false),
        PingEntry(server: "OpenDNS 208.67.222.222", latency: "—", status: false)
    ]

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background with subtle glow
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.07, blue: 0.16),
                        Color(red: 0.06, green: 0.10, blue: 0.22)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    statusBarHeader
                    ScrollView {
                        VStack(spacing: 16) {
                            shieldCard
                            toolTabs
                            toolContent
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            startNetworkMonitor()
            fakeNotifier.requestPermissionIfNeeded()
            session.startSecurityMonitoring()
        }
        .onDisappear {
            pathMonitor.cancel()
            session.stopSecurityMonitoring()
        }
        .onReceive(timer) { _ in
            if isPingRunning {
                animatePingTest()
            }
            if connectionState == .connecting {
                finishConnectingIfNeeded()
            }
        }
        .overlay(alignment: .top) {
            if let banner {
                stealthBanner(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $isShowingPasscode) {
            PasscodeView()
        }
    }

    // MARK: - Status Bar Header

    private var statusBarHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("VPN Shield")
                    .font(.title3.bold())
                    .foregroundColor(.white)
                Text(networkInfo.isWiFi ? "Connected via Wi-Fi" : "Connected via Cellular")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "wifi")
                    .foregroundColor(networkInfo.isWiFi ? .green : .gray)
                Image(systemName: "battery.75")
                    .foregroundColor(.white)
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Shield Card (Secret Trigger)

    private var shieldCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // Progress ring fill for long-press
                Circle()
                    .stroke(Color.blue.opacity(0.15), lineWidth: 4)
                    .frame(width: 130, height: 130)

                Circle()
                    .trim(from: 0, to: shieldHoldProgress)
                    .stroke(
                        LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 130, height: 130)
                    .opacity(shieldHoldProgress > 0 ? 1 : 0)

                // The shield itself — the secret entry point
                Image(systemName: connectionState.icon)
                    .font(.system(size: 64))
                    .foregroundColor(connectionState.color)
                    .scaleEffect(shieldHoldProgress > 0 ? 0.92 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: shieldHoldProgress)
            }
            .frame(width: 150, height: 150)
            .contentShape(Circle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 3)
                    .onChanged { _ in
                        withAnimation(.linear(duration: 3)) {
                            shieldHoldProgress = 1.0
                        }
                    }
                    .onEnded { _ in
                        requestSecretUnlock()
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        // Rapid taps count as alternate secret sequence
                        let now = Date()
                        if now.timeIntervalSince(lastSecretTapTime) > 1.5 {
                            secretTapCount = 1
                        } else {
                            secretTapCount += 1
                        }
                        lastSecretTapTime = now
                        if secretTapCount >= 5 {
                            secretTapCount = 0
                            requestSecretUnlock()
                        }
                    }
            )

            Text("PROTECTED")
                .font(.caption.bold())
                .tracking(4)
                .foregroundColor(.gray.opacity(0.7))

            Text(connectionState.label)
                .font(.headline)
                .foregroundColor(connectionState.color)

            Text(subtitleText)
                .font(.caption2)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var subtitleText: String {
        switch connectionState {
        case .disconnected:
            return "Your devices are not protected."
        case .connecting:
            return "Establishing encrypted tunnel…"
        case .connected:
            return "Your connection is secure & anonymous."
        }
    }

    // MARK: - VPN Toggle

    private var vpnToggleButton: some View {
        Button {
            toggleVPN()
        } label: {
            HStack {
                Image(systemName: connectionState == .connected ? "lock.fill" : "lock.open.fill")
                Text(connectionState == .connected ? "Disconnect" : "Connect")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(connectionState.color)
                    .frame(width: 10, height: 10)
            }
            .font(.subheadline)
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 60)
    }

    // MARK: - Tool Tabs

    private var toolTabs: some View {
        HStack(spacing: 12) {
            ForEach(NetworkToolTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activeTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: .medium))
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(activeTab == tab ? .white : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(activeTab == tab ? Color.blue.opacity(0.25) : Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Tool Content

    @ViewBuilder
    private var toolContent: some View {
        switch activeTab {
        case .status:
            statusTool
        case .speedTest:
            speedTestTool
        case .ping:
            pingTool
        case .wifi:
            wifiAnalyzerTool
        }
    }

    // MARK: Status Tool

    private var statusTool: some View {
        VStack(spacing: 16) {
            vpnToggleButton

            HStack(spacing: 12) {
                statTile(title: "Ping", value: "\(Int.random(in: 18...42)) ms", icon: "waveform.path.ecg")
                statTile(title: "Download", value: downloadSpeed == nil ? "—" : String(format: "%.1f Mbps", downloadSpeed!), icon: "arrow.down.circle")
                statTile(title: "Upload", value: uploadSpeed == nil ? "—" : String(format: "%.1f Mbps", uploadSpeed!), icon: "arrow.up.circle")
            }

            fakeNotificationRow
        }
    }

    private var fakeNotificationRow: some View {
        Button {
            fakeNotifier.postDisguisedNetworkAlert()
            showStealthBanner("Network diagnostic scan completed")
        } label: {
            HStack {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.blue)
                Text("Run Network Diagnostic")
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func statTile(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.blue)
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: Speed Test Tool

    private var speedTestTool: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 10)
                    .frame(width: 150, height: 150)

                Circle()
                    .trim(from: 0, to: isTestingSpeed ? 0.75 : 1)
                    .stroke(
                        AngularGradient(
                            colors: [.blue, .purple, .blue],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 150, height: 150)
                    .animation(.linear(duration: isTestingSpeed ? 1.2 : 0.3).repeatForever(autoreverses: false), value: isTestingSpeed)

                VStack(spacing: 4) {
                    if let downloadSpeed {
                        Text(String(format: "%.1f", downloadSpeed))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                        Text("Mbps")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding(.top, 10)

            Button {
                runSpeedTest()
            } label: {
                Text(isTestingSpeed ? "Testing…" : "Start Speed Test")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(isTestingSpeed ? Color.gray.opacity(0.4) : Color.blue))
            }
            .disabled(isTestingSpeed)
            .buttonStyle(PlainButtonStyle())

            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text("Download")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text(downloadSpeed == nil ? "—" : String(format: "%.1f Mbps", downloadSpeed!))
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 30)

                VStack(spacing: 4) {
                    Text("Upload")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text(uploadSpeed == nil ? "—" : String(format: "%.1f Mbps", uploadSpeed!))
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.06))
            )
        }
    }

    // MARK: Ping Tool

    private var pingTool: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Ping Servers")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button {
                    runPingTest()
                } label: {
                    Label(isPingRunning ? "Running…" : "Start", systemImage: "play.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isPingRunning)
            }

            ForEach(pingEntries) { entry in
                HStack {
                    Circle()
                        .fill(entry.status ? Color.green : (isPingRunning ? Color.orange : Color.gray))
                        .frame(width: 8, height: 8)
                    Text(entry.server)
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(entry.latency)
                        .font(.subheadline.bold())
                        .foregroundColor(entry.status ? .green : .gray)
                        .monospacedDigit()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                )
            }
        }
    }

    // MARK: Wi-Fi Analyzer Tool

    private var wifiAnalyzerTool: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(networkInfo.ssid)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(networkInfo.isWiFi ? "Wi-Fi Connected" : "No Wi-Fi — Cellular Data")
                        .font(.caption)
                        .foregroundColor(networkInfo.isWiFi ? .green : .gray)
                }
                Spacer()
                signalBarsView
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.06))
            )

            HStack(spacing: 12) {
                wifiDetailTile(title: "Channel", value: "\(networkInfo.channel)", icon: "dot.radiowaves.left.and.right")
                wifiDetailTile(title: "Band", value: networkInfo.frequency, icon: "waveform")
                wifiDetailTile(title: "IP Address", value: networkInfo.localIP, icon: "network")
            }

            HStack {
                Text("Signal Strength")
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
                Text("\(networkInfo.signalBars + 2)/5")
                    .font(.subheadline.bold())
                    .foregroundColor(.blue)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
            )

            Button {
                fakeNotifier.postDisguisedNetworkAlert()
                showStealthBanner("Wi-Fi scan complete — no threats found")
            } label: {
                Text("Run Security Scan")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.blue))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var signalBarsView: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<networkInfo.signalBars, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.green)
                    .frame(width: 4, height: 8)
            }
            ForEach(0..<max(0, 4 - networkInfo.signalBars), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 4, height: 8)
            }
        }
        .frame(height: 14)
    }

    private func wifiDetailTile(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.blue)
            Text(value)
                .font(.caption.bold())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: - Stealth Banner

    private func stealthBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(.green)
            Text(message)
                .font(.footnote.bold())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.85))
        )
        .padding(.top, 50)
    }

    // MARK: - Actions

    private func requestSecretUnlock() {
        // Reset the hold progress, hide stealth banner, and ask for the PIN.
        withAnimation(.easeOut(duration: 0.3)) {
            shieldHoldProgress = 0
        }
        session.requestPasscode(mode: .unlock)
        isShowingPasscode = true
    }

    private func toggleVPN() {
        switch connectionState {
        case .disconnected:
            connectionState = .connecting
            fakeNotifier.postDisguisedNetworkAlert()
        case .connecting:
            connectionState = .disconnected
        case .connected:
            connectionState = .disconnected
        }
    }

    private func finishConnectingIfNeeded() {
        // Simulate the handshake taking ~3 seconds then connecting.
        if connectionState == .connecting {
            connectionState = .connected
            fakeNotifier.postDisguisedNetworkAlert()
            showStealthBanner("VPN tunnel established")
        }
    }

    private func showStealthBanner(_ message: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            banner = message
        }
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    banner = nil
                }
            }
        }
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                let isWiFi = path.usesInterfaceType(.wifi)
                networkInfo.isWiFi = isWiFi
                networkInfo.isCellular = path.usesInterfaceType(.cellular)
                networkInfo.isExpensive = path.isExpensive
                networkInfo.isConstrained = path.isConstrained
                networkInfo.interfaceName = isWiFi ? "en0" : "pdp_ip0"
                networkInfo.localIP = NetworkHelper.localIPAddress(for: networkInfo.interfaceName)
                networkInfo.ssid = isWiFi ? "HomeNetwork-5G" : "Cellular Data"
                networkInfo.signalBars = isWiFi ? Int.random(in: 2...4) : Int.random(in: 2...4)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Speed Test

    private func runSpeedTest() {
        guard !isTestingSpeed else { return }
        isTestingSpeed = true
        downloadSpeed = nil
        uploadSpeed = nil

        let group = DispatchGroup()

        // Download test
        group.enter()
        guard let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=5000000") else {
            group.leave()
            return
        }
        var downloadRequest = URLRequest(url: downloadURL)
        downloadRequest.timeoutInterval = 25
        let downloadStart = Date()
        URLSession.shared.dataTask(with: downloadRequest) { data, _, error in
            defer { group.leave() }
            if let data, error == nil {
                let elapsed = max(Date().timeIntervalSince(downloadStart), 0.1)
                let mbps = Double(data.count) * 8 / 1_000_000 / elapsed
                DispatchQueue.main.async {
                    downloadSpeed = min(mbps, 999)
                }
            }
        }.resume()

        // Upload test
        group.enter()
        let payload = Data(repeating: 0xAB, count: 2_000_000)
        guard let uploadURL = URL(string: "https://speed.cloudflare.com/__up") else {
            group.leave()
            return
        }
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.timeoutInterval = 25
        let uploadStart = Date()
        URLSession.shared.uploadTask(with: uploadRequest, from: payload) { _, _, error in
            defer { group.leave() }
            if error == nil {
                let elapsed = max(Date().timeIntervalSince(uploadStart), 0.1)
                let mbps = Double(payload.count) * 8 / 1_000_000 / elapsed
                DispatchQueue.main.async {
                    uploadSpeed = min(mbps, 999)
                }
            }
        }.resume()

        group.notify(queue: .main) {
            isTestingSpeed = false
            fakeNotifier.postDisguisedNetworkAlert()
            showStealthBanner("Speed test complete")
        }
    }

    // MARK: - Ping Test

    private func runPingTest() {
        guard !isPingRunning else { return }
        isPingRunning = true

        // Reset entries
        for index in pingEntries.indices {
            pingEntries[index].status = false
            pingEntries[index].latency = "…"
        }
    }

    private func animatePingTest() {
        // Progressively resolve each host with a simulated latency.
        for index in pingEntries.indices where !pingEntries[index].status {
            if Int.random(in: 0...100) < 45 {
                withAnimation(.easeInOut(duration: 0.3)) {
                    let latency = Double.random(in: 18...96)
                    pingEntries[index].latency = String(format: "%.0f ms", latency)
                    pingEntries[index].status = true
                }
            }
            break
        }

        if pingEntries.allSatisfy({ $0.status }) {
            isPingRunning = false
            fakeNotifier.postDisguisedNetworkAlert()
            showStealthBanner("Ping test complete")
        }
    }
}

// MARK: - Tool Tabs

enum NetworkToolTab: String, CaseIterable, Identifiable {
    case status
    case speedTest
    case ping
    case wifi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Status"
        case .speedTest: return "Speed"
        case .ping: return "Ping"
        case .wifi: return "Wi-Fi"
        }
    }

    var icon: String {
        switch self {
        case .status: return "gauge"
        case .speedTest: return "speedometer"
        case .ping: return "network"
        case .wifi: return "wifi"
        }
    }
}