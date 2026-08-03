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
    }
}