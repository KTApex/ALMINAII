import SwiftUI

@main
struct VpnHideApp: App {
    @StateObject private var vaultSession = VaultSessionManager.shared
    @StateObject private var vaultStorage = VaultStorageManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vaultSession)
                .environmentObject(vaultStorage)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: VaultSessionManager
    @StateObject private var security = SecurityManager.shared

    var body: some View {
        Group {
            if session.isVaultUnlocked {
                MediaVaultView()
                    .transition(.opacity)
            } else if session.isDecoyMode {
                DecoyVaultView()
                    .transition(.opacity)
            } else {
                VPNFrontView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.isVaultUnlocked)
        .animation(.easeInOut(duration: 0.3), value: session.isDecoyMode)
        .onAppear {
            // Wire emergency motion lock (face-down / shake) to the session.
            security.onEmergencyLock = {
                session.lockVault()
            }
            // First launch: show PIN setup if no PIN is configured.
            if !session.hasPIN {
                session.requestPasscode(mode: .setup)
            }
        }
        .onChange(of: session.isVaultUnlocked) { unlocked in
            if unlocked {
                // Full security monitoring while the vault is open.
                security.startEmergencyMonitoring()
            } else {
                security.stopEmergencyMonitoring()
            }
        }
        .sheet(isPresented: $session.isShowingPasscode) {
            PasscodeView()
                .environmentObject(session)
        }
    }
}
