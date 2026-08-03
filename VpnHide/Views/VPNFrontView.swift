import Combine
import SwiftUI

/// The public-facing "VPN Status & Network Utility" disguise screen.
/// Looks and behaves like a realistic VPN app. Long-pressing the shield
/// icon for 3 seconds (or tapping the shield 5 times) triggers the
/// hidden passcode screen.
struct VPNFrontView: View {
    @EnvironmentObject var session: VaultSessionManager
    @State private var isVPNActive = false
    @State private var isConnecting = false
    @State private var pingValue: Int = 0
    @State private var serverLocation = "Auto (Recommended)"
    @State private var dataUsed: Double = 0.0
    @State private var showServerList = false
    @State private var shieldPressCount = 0
    @State private var isLongPressTriggered = false
    @State private var showToast = false
    @State private var timerCancellable: AnyCancellable?

    private let shieldLongPressDuration: CGFloat = 3.0
    private let serverOptions = ["Auto (Recommended)", "United States", "United Kingdom", "Germany", "Japan", "Singapore", "Australia"]

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.15), Color(red: 0.10, green: 0.13, blue: 0.25)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    headerView
                    shieldToggleView
                    statusCard
                    serverSelectorCard
                    statsCard
                    footerNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .sheet(isPresented: $showServerList) {
            ServerListView(
                servers: serverOptions,
                selectedServer: $serverLocation
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .bottom) {
            if showToast {
                Text("Entering secure area...")
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 40)
            }
        }
        .fullScreenCover(isPresented: $session.isShowingPasscode) {
            PasscodeView()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("VPN Shield")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("Secure Network Utility")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundColor(.gray)
        }
        .padding(.top, 8)
    }

    // MARK: - Shield Toggle (Secret Entry)

    private var shieldToggleView: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: isVPNActive
                                ? [Color.green.opacity(0.4), Color.green.opacity(0.05)]
                                : [Color.blue.opacity(0.3), Color.blue.opacity(0.05)],
                            center: .center,
                            startRadius: 20,
                            endRadius: 100
                        )
                    )
                    .frame(width: 180, height: 180)

                // Shield icon - long-press or multi-tap to trigger hidden entry
                Image(systemName: "shield.fill")
                    .font(.system(size: 70))
                    .foregroundColor(isVPNActive ? .green : .blue)
                    .shadow(color: isVPNActive ? .green.opacity(0.6) : .blue.opacity(0.6), radius: 15)
                    .scaleEffect(isLongPressTriggered ? 0.85 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isLongPressTriggered)

                    // Also trigger with 5 quick taps as fallback
                    .onTapGesture {
                        shieldPressCount += 1
                        if shieldPressCount >= 5 {
                            shieldPressCount = 0
                            triggerHiddenEntry()
                        }
                        // Reset counter after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            shieldPressCount = 0
                        }
                    }
                    .onLongPressGesture(minimumDuration: shieldLongPressDuration) {
                        triggerHiddenEntry()
                    } onPressingChanged: { isPressing in
                        isLongPressTriggered = isPressing
                    }
            }
            .padding(.top, 10)

            Text(isVPNActive ? "Protected" : (isConnecting ? "Connecting..." : "Unprotected"))
                .font(.headline)
                .foregroundColor(isVPNActive ? .green : (isConnecting ? .orange : .red))
        }
        .padding(.vertical, 10)
    }

    // MARK: - Connect Toggle Card

    private var connectButton: some View {
        Button {
            toggleVPN()
        } label: {
            HStack {
                Image(systemName: "power")
                Text(isVPNActive ? "Disconnect" : "Connect")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(isVPNActive ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
            )
            .foregroundColor(.white)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Network Status", systemImage: "network")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Spacer()
                Circle()
                    .fill(isVPNActive ? Color.green : (isConnecting ? Color.orange : Color.red))
                    .frame(width: 10, height: 10)
            }

            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow(icon: "globe", title: "Server", value: serverLocation)
                    statusRow(icon: "location.fill", title: "IP Address", value: "103.xx.xx.xx")
                    statusRow(icon: "timer", title: "Ping", value: "\(pingValue) ms")
                }
                Spacer()
            }

            connectButton
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func statusRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.blue)
                .frame(width: 20)
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
        }
    }

    // MARK: - Server Selector

    private var serverSelectorCard: some View {
        Button {
            showServerList = true
        } label: {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Server")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(serverLocation)
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Stats

    private var statsCard: some View {
        HStack(spacing: 20) {
            statItem(value: String(format: "%.1f GB", dataUsed), label: "Data Used")
            Divider().frame(height: 40).overlay(Color.white.opacity(0.1))
            statItem(value: "00:45:12", label: "Session Time")
            Divider().frame(height: 40).overlay(Color.white.opacity(0.1))
            statItem(value: "AES-256", label: "Encryption")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(.white)
            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private var footerNote: some View {
        Text("VPN Shield • Network security utility")
            .font(.caption2)
            .foregroundColor(.gray.opacity(0.6))
            .padding(.bottom, 10)
    }

    // MARK: - Actions

    private func toggleVPN() {
        withAnimation(.easeInOut(duration: 0.3)) {
            if isVPNActive {
                isVPNActive = false
                isConnecting = false
                pingValue = 0
                timerCancellable?.cancel()
            } else {
                isConnecting = true
                // Simulate connection delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        isConnecting = false
                        isVPNActive = true
                        pingValue = Int.random(in: 18...85)
                    }
                    // Simulate data usage increment
                    timerCancellable = Timer.publish(every: 5, on: .main, in: .common)
                        .autoconnect()
                        .sink { [self] _ in
                            dataUsed += 0.02
                        }
                }
            }
        }
    }

    /// Triggers the hidden vault entry point.
    private func triggerHiddenEntry() {
        triggerHaptic()
        withAnimation {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation {
                showToast = false
            }

            if session.hasPIN {
                session.requestPasscode(mode: .unlock)
            } else {
                // First-time setup - create a vault PIN
                session.requestPasscode(mode: .setup)
            }
        }
    }

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
}

// MARK: - Server List Sheet

struct ServerListView: View {
    let servers: [String]
    @Binding var selectedServer: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(servers, id: \.self) { server in
                Button {
                    selectedServer = server
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.blue)
                        Text(server)
                            .foregroundColor(.white)
                        Spacer()
                        if server == selectedServer {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            .navigationTitle("Select Server")
            .preferredColorScheme(.dark)
        }
    }
}