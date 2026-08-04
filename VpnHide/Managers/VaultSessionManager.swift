import Foundation
import LocalAuthentication
import SwiftUI

/// Manages the vault session state, PIN setup/verification, and biometric authentication.
/// Also handles the "Panic Mode" decoy vault.
final class VaultSessionManager: ObservableObject {

    static let shared = VaultSessionManager()

    // MARK: - Published State

    @Published var isVaultUnlocked = false
    @Published var isDecoyMode = false
    @Published var isShowingPasscode = false
    @Published var passcodeMode: PasscodeMode = .unlock
    @Published var isBiometricEnabled = true

    // MARK: - Private

    private let keychain = KeychainManager.shared
    private let pinSaltKey = "com.vpnhide.vault.pinsalt"
    private let panicSaltKey = "com.vpnhide.vault.panicsalt"
    private let biometricEnabledKey = "com.vpnhide.vault.biometric"

    private init() {
        loadBiometricPreference()
    }

    // MARK: - PIN Setup

    var hasPIN: Bool {
        keychain.readPINHash(named: CryptoManager.Constants.pinKeyName) != nil
    }

    var hasPanicPIN: Bool {
        keychain.readPINHash(named: CryptoManager.Constants.panicPinKeyName) != nil
    }

    /// Sets a new vault PIN (salted hash stored in Keychain).
    func setPIN(_ pin: String) throws {
        let salt = keychain.generateSalt()
        let hash = keychain.hashPIN(pin, salt: salt)
        try keychain.saveKey(salt, named: pinSaltKey)
        try keychain.savePINHash(hash, named: CryptoManager.Constants.pinKeyName)
    }

    /// Sets a new Panic/Decoy PIN.
    func setPanicPIN(_ pin: String) throws {
        let salt = keychain.generateSalt()
        let hash = keychain.hashPIN(pin, salt: salt)
        try keychain.saveKey(salt, named: panicSaltKey)
        try keychain.savePINHash(hash, named: CryptoManager.Constants.panicPinKeyName)
    }

    /// Verifies a PIN against the stored hash.
    func verifyPIN(_ pin: String) -> Bool {
        guard let storedHash = keychain.readPINHash(named: CryptoManager.Constants.pinKeyName),
              let salt = keychain.readKey(named: pinSaltKey) else {
            return false
        }
        let candidate = keychain.hashPIN(pin, salt: salt)
        return candidate == storedHash
    }

    /// Verifies the Panic PIN.
    func verifyPanicPIN(_ pin: String) -> Bool {
        guard let storedHash = keychain.readPINHash(named: CryptoManager.Constants.panicPinKeyName),
              let salt = keychain.readKey(named: panicSaltKey) else {
            return false
        }
        let candidate = keychain.hashPIN(pin, salt: salt)
        return candidate == storedHash
    }

    // MARK: - Biometric

    private func loadBiometricPreference() {
        isBiometricEnabled = UserDefaults.standard.object(forKey: biometricEnabledKey) as? Bool ?? true
    }

    func setBiometricEnabled(_ enabled: Bool) {
        isBiometricEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: biometricEnabledKey)
    }

    var biometricType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        return context.biometryType
    }

    /// Authenticates with Face ID / Touch ID.
    func authenticateWithBiometrics(completion: @escaping (Bool, Error?) -> Void) {
        guard isBiometricEnabled else {
            completion(false, nil)
            return
        }

        let context = LAContext()
        context.localizedFallbackTitle = "Enter PIN"

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Authenticate to unlock your private vault."
        ) { success, error in
            DispatchQueue.main.async {
                completion(success, error)
            }
        }
    }

    // MARK: - Unlock / Lock

    /// Attempts to unlock the vault with a PIN.
    func unlockWithPIN(_ pin: String) -> Bool {
        if verifyPanicPIN(pin) {
            // Panic PIN entered → open decoy vault
            isDecoyMode = true
            isVaultUnlocked = false
            isShowingPasscode = false
            return true
        }

        guard verifyPIN(pin) else {
            // Register the failed attempt → triggers intruder selfie at 3 failures
            SecurityManager.shared.registerFailedAttempt()
            return false
        }

        // Success — reset failure counter
        SecurityManager.shared.resetFailedAttempts()
        isVaultUnlocked = true
        isDecoyMode = false
        isShowingPasscode = false
        return true
    }

    /// Unlocks the vault after successful biometric auth.
    func unlockWithBiometrics() {
        SecurityManager.shared.resetFailedAttempts()
        isVaultUnlocked = true
        isDecoyMode = false
        isShowingPasscode = false
    }

    /// Locks the vault and returns to the VPN mask screen.
    func lockVault() {
        isVaultUnlocked = false
        isDecoyMode = false
        isShowingPasscode = false
    }

    /// Shows the passcode screen (for setup or unlock).
    func requestPasscode(mode: PasscodeMode) {
        passcodeMode = mode
        isShowingPasscode = true
    }
}

// MARK: - Passcode Mode

enum PasscodeMode {
    case setup
    case confirm
    case unlock
    case panicSetup
}