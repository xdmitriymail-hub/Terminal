import Foundation
import LocalAuthentication

/// Single point for Face ID / Touch ID evaluation. Falls back to the
/// device passcode so the lock still works on Macs and older devices.
enum BiometricGate {
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Prompts the user for biometrics (or passcode). `reason` is the
    /// short system prompt string shown inside the Face ID sheet.
    static func evaluate(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )) ?? false
    }
}
