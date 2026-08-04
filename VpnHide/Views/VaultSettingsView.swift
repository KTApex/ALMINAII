import LocalAuthentication
import SwiftUI

// MARK: - Vault Settings View

/// Settings screen inside the vault: biometric toggle, Panic PIN setup,
/// encrypted cloud backup (manual + auto), and Security Log viewer.
struct VaultSettingsView: View {
    @EnvironmentObject var session: VaultSessionManager
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var security = SecurityManager.shared
    @ObservedObject var backup = CloudBackupManager.shared
    @ObservedObject var googleAuth = GoogleDriveAuthManager.shared

    @State private var isShowingPanicSetup = false
    @State private var isShowingSecurityLog = false
    @State private var isShowingMasterPINPrompt = false
    @State private var masterPIN = ""
    @State private var isBackingUp = false
    @State private var lastOperationMessage: String?
    @State private var showConfirmation = false
    @State private var showGoogleSignInError = false
    @State private var googleSignInErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Security Section
                Section {
                    // Biometric toggle
                    Toggle(isOn: Binding(
                        get: { session.isBiometricEnabled },
                        set: { session.setBiometricEnabled($0) }
                    )) {
                        HStack {
                            Image(systemName: biometricIcon)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text("Face ID / Touch ID")
                                    .foregroundColor(.primary)
                                Text("Unlock vault with \(biometricName)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }

                    // Panic PIN
                    Button {
                        session.requestPasscode(mode: .panicSetup)
                    } label: {
                        HStack {
                            Image(systemName: "shield.slash.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text("Panic PIN (Decoy Vault)")
                                    .foregroundColor(.primary)
                                Text("Set or change the PIN that opens a clean decoy vault")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }

                    // Intruder log
                    Button {
                        isShowingSecurityLog = true
                    } label: {
                        HStack {
                            Image(systemName: "camera.fill")
                                .foregroundColor(.red)
                            VStack(alignment: .leading) {
                                Text("Security Log")
                                    .foregroundColor(.primary)
                                Text("\(security.intruderLog.count) intruder capture\(security.intruderLog.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Intruder photos are captured silently after 3 failed PIN attempts.")
                }

                // MARK: - Backup Section
                Section {
                    // Provider picker
                    Picker("Cloud Provider", selection: Binding(
                        get: { backup.selectedProvider },
                        set: { backup.setProvider($0) }
                    )) {
                        ForEach(CloudBackupProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }

                    // Google Drive sign-in status
                    if backup.selectedProvider == .googleDrive {
                        if googleAuth.isSignedIn {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Signed in to Google Drive")
                                    .foregroundColor(.primary)
                                Spacer()
                                Button("Sign Out") {
                                    googleAuth.signOut()
                                }
                                .font(.subheadline)
                                .foregroundColor(.red)
                            }
                        } else {
                            Button {
                                performGoogleSignIn()
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                        .foregroundColor(.blue)
                                    Text(googleAuth.isAuthenticating ? "Signing In..." : "Sign in to Google Drive")
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if googleAuth.isAuthenticating {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(googleAuth.isAuthenticating)
                        }
                    }

                    // Auto backup toggle
                    Toggle(isOn: Binding(
                        get: { backup.isAutoBackupEnabled },
                        set: { backup.setAutoBackupEnabled($0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Auto Backup")
                            Text("When on Wi-Fi & charging")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }

                    // Manual backup
                    Button {
                        isShowingMasterPINPrompt = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise.icloud.fill")
                                .foregroundColor(.blue)
                            Text(isBackingUp ? "Backing Up..." : "Back Up Now")
                                .foregroundColor(.primary)
                            Spacer()
                            if isBackingUp {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isBackingUp)

                    // Last backup
                    if let lastBackupDate = backup.lastBackupDate {
                        HStack {
                            Text("Last Backup")
                            Spacer()
                            Text(lastBackupDate, style: .date)
                                .foregroundColor(.gray)
                        }
                    }
                } header: {
                    Text("Encrypted Cloud Backup")
                } footer: {
                    Text("Files are encrypted with AES-256 before upload. Cloud providers cannot read your data.")
                }

                // MARK: - Storage Section
                Section {
                    HStack {
                        Text(security.obfuscatedStorageStatus().label)
                        Spacer()
                        Text(security.obfuscatedStorageStatus().detail)
                            .foregroundColor(.gray)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("System cache statistics are reported for privacy.")
                }
            }
            .navigationTitle("Settings")
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
            .sheet(isPresented: $isShowingSecurityLog) {
                IntruderLogView(security: security)
            }
            .alert("Enter Master PIN", isPresented: $isShowingMasterPINPrompt) {
                SecureField("Master PIN", text: $masterPIN)
                    .keyboardType(.numberPad)
                Button("Back Up", role: .destructive) {
                    performBackup()
                }
                Button("Cancel", role: .cancel) {
                    masterPIN = ""
                }
            } message: {
                Text("Your PIN encrypts the backup container.")
            }
            .alert(
                lastOperationMessage ?? "",
                isPresented: $showConfirmation
            ) {
                Button("OK") {
                    showConfirmation = false
                }
            }
            .alert(
                googleSignInErrorMessage ?? "Google Sign-In Failed",
                isPresented: $showGoogleSignInError
            ) {
                Button("OK") {
                    showGoogleSignInError = false
                }
            }
        }
    }

    // MARK: - Computed

    private var biometricIcon: String {
        switch session.biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    private var biometricName: String {
        switch session.biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
        }
    }

    // MARK: - Google Sign-In

    private func performGoogleSignIn() {
        googleAuth.signIn { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    lastOperationMessage = "Signed in to Google Drive successfully."
                    showConfirmation = true
                case .failure(let error):
                    googleSignInErrorMessage = error.localizedDescription
                    showGoogleSignInError = true
                }
            }
        }
    }

    // MARK: - Backup

    private func performBackup() {
        guard !masterPIN.isEmpty else { return }
        let pin = masterPIN
        isBackingUp = true
        masterPIN = ""

        backup.backupNow(masterPIN: pin) { result in
            DispatchQueue.main.async {
                isBackingUp = false
                switch result {
                case .success:
                    lastOperationMessage = "Backup completed successfully."
                case .failure(let error):
                    lastOperationMessage = "Backup failed: \(error.localizedDescription)"
                }
                showConfirmation = true
            }
        }
    }
}