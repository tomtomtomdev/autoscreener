import Foundation
import Observation

@MainActor
@Observable
final class AuthState {
    /// Tri-state so ContentView can show a tiny "Checking…" splash instead of
    /// flashing the sign-in prompt before the async Keychain read returns.
    enum Phase: Equatable { case unknown, signedOut, signedIn }
    var phase: Phase = .unknown

    var isSignedIn: Bool { phase == .signedIn }

    func setSignedIn() { phase = .signedIn }
    func setSignedOut() { phase = .signedOut }
}
