import LocalAuthentication
import SwiftUI

/// The secret PIN entry screen. Supports 4/6-digit PIN setup, unlock,
/// and Face ID / Touch ID authentication.
struct PasscodeView: View {
    @EnvironmentObject var session: VaultSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var pinDigits: [Int] = []
    @State private var confirmDigits: [Int] = []
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @State private var shakeTrigger = false

    private let pinLength = 4

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.15), Color(red: 0.10, green: 0.13, blue: 0.25)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                // Lock icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                    .padding(.bottom, 10)

                // Title
                Text(titleText)
                    .font(.title2.bold())
                    .foregroundColor(.white)

                // PIN dots
                pinDotsView
                    .modifier(ShakeEffect(animatable: shakeTrigger ? 1 : 0))
                    .padding(.vertical, 20)

                // Error message
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }

                // Biometric button
                if session.passcodeMode == .unlock && session.isBiometricEnabled {
                    Button {
                        showWithBiometrics()
                    } label: {
                        HStack {
                            Image(systemName: biometricIcon)
                            Text("Use \(biometricName)")
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }
                    .padding(.top, 10)
                }

                Spacer()

                // Number pad
                numberPad
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 30)
        }
        .onAppear {
            if session.passcodeMode == .unlock && session.isBiometricEnabled {
                // Auto-prompt biometrics on appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showWithBiometrics()
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var titleText: String {
        switch session.passcodeMode {
        case .setup:
            return isConfirming ? "Confirm PIN" : "Set Vault PIN"
        case .confirm:
            return "Confirm PIN"
        case .unlock:
            return "Enter PIN"
        case .panicSetup:
            return "Set Panic PIN"
        }
    }

    private var biometricIcon: String {
        switch session.biometricType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        default:
            return "lock.fill"
        }
    }

    private var biometricName: String {
        switch session.biometricType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        default:
            return "Biometrics"
        }
    }

    // MARK: - PIN Dots

    private var pinDotsView: some View {
        HStack(spacing: 20) {
            ForEach(0..<pinLength, id: \.self) { index in
                Circle()
                    .fill(index < pinDigits.count ? Color.blue : Color.white.opacity(0.2))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Number Pad

    private var numberPad: some View {
        VStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(1...3, id: \.self) { col in
                        let number = row * 3 + col
                        numberButton(number)
                    }
                }
            }
            HStack(spacing: 16) {
                // Empty placeholder
                Color.clear.frame(width: 70, height: 70)

                numberButton(0)

                // Backspace
                Button {
                    if !pinDigits.isEmpty {
                        pinDigits.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 70, height: 70)
                }
            }
        }
    }

    private func numberButton(_ number: Int) -> some View {
        Button {
            appendDigit(number)
        } label: {
            Text("\(number)")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 70, height: 70)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.1))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Actions

    private func appendDigit(_ digit: Int) {
        guard pinDigits.count < pinLength else { return }
        pinDigits.append(digit)

        if pinDigits.count == pinLength {
            let pin = pinDigits.map(String.init).joined()
            handlePINEntry(pin)
        }
    }

    private func handlePINEntry(_ pin: String) {
        switch session.passcodeMode {
        case .setup:
            if !isConfirming {
                // First entry - store and ask to confirm
                confirmDigits = pinDigits
                pinDigits = []
                isConfirming = true
            } else {
                // Confirm entry
                let first = confirmDigits.map(String.init).joined()
                if first == pin {
                    do {
                        try session.setPIN(pin)
                        // Also prompt to set a Panic PIN
                        session.requestPasscode(mode: .panicSetup)
                    } catch {
                        errorMessage = "Failed to save PIN. Please try again."
                        resetPIN()
                    }
                } else {
                    errorMessage = "PINs do not match. Try again."
                    resetPIN()
                }
            }

        case .confirm:
            // Confirming panic PIN
            do {
                try session.setPanicPIN(pin)
                session.lockVault()
                dismiss()
            } catch {
                errorMessage = "Failed to save Panic PIN."
                resetPIN()
            }

        case .unlock:
            if session.unlockWithPIN(pin) {
                dismiss()
            } else {
                errorMessage = "Incorrect PIN. Try again."
                resetPIN()
            }

        case .panicSetup:
            // Set panic PIN
            do {
                try session.setPanicPIN(pin)
                session.lockVault()
                dismiss()
            } catch {
                errorMessage = "Failed to save Panic PIN."
                resetPIN()
            }
        }
    }

    private func resetPIN() {
        pinDigits = []
        isConfirming = false
        withAnimation(.default) {
            shakeTrigger = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            shakeTrigger = false
        }
    }

    private func showWithBiometrics() {
        session.authenticateWithBiometrics { success, _ in
            if success {
                session.unlockWithBiometrics()
                dismiss()
            }
        }
    }
}

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var animatable: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = 10 * sin(animatable * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}