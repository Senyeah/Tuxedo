import Foundation
import LocalAuthentication

/// The Face ID check before a machine's session opens or comes back (SessionGate). With the passcode as the
/// fallback (SessionGate.faceIDOnly). The wallet's Keychain items open with the session (KeychainStore), so the person is
/// asked once for each return.
enum SessionAuth {
    static var policy: LAPolicy { SessionGate.faceIDOnly ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication }

    enum Outcome {
        case passed
        case failed(String)
    }

    static func check(_ name: String) async -> Outcome {
        #if targetEnvironment(simulator)
        TuxLog.log("session", "face id: skipped in the simulator")
        return .passed
        #else
        let context = LAContext()
        context.localizedCancelTitle = "Not Now"
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            TuxLog.log("session", "face id: not available (\(error?.code ?? 0))")
            return .failed(message(error))
        }
        do {
            try await context.evaluatePolicy(policy, localizedReason: "Unlock \(name) and its saved passwords.")
            TuxLog.log("session", "face id: passed")
            return .passed
        } catch {
            TuxLog.log("session", "face id: refused (\((error as NSError).code))")
            return .failed(message(error as NSError))
        }
        #endif
    }

    private static func message(_ error: NSError?) -> String {
        switch LAError.Code(rawValue: error?.code ?? 0) {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return "Face ID was cancelled."
        case .passcodeNotSet:
            return "Set a passcode for this device in Settings, Face ID & Passcode. Henge needs Face ID or the passcode to open a machine."
        case .biometryNotEnrolled:
            return "Set up Face ID in Settings, Face ID & Passcode."
        case .biometryLockout:
            return "Face ID is locked. Unlock the device with its passcode, then try again."
        case .authenticationFailed:
            return "Face ID did not recognise you."
        default:
            return error?.localizedDescription ?? "Face ID did not pass."
        }
    }
}
