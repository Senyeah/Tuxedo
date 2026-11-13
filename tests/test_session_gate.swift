import Foundation

@main
struct SessionGateTests {
    static func ticket(_ a: SessionGate.Ask) -> Int {
        guard case .check(let t) = a else { preconditionFailure("expected a check, got \(a)") }
        return t
    }

    static func main() {
        // The owner's choice: the passcode is the fallback.
        precondition(!SessionGate.faceIDOnly)

        // Nothing runs before the first check.
        var g = SessionGate()
        precondition(g.phase == .closed && g.covered && !g.secretsUnlocked)
        let first = ticket(g.ask())
        precondition(g.phase == .checking && g.covered && !g.secretsUnlocked)
        precondition(g.ask() == .nothing) // one check at a time
        g.checked(first, passed: true)
        precondition(g.phase == .open && !g.covered && g.secretsUnlocked)
        precondition(g.ask() == .nothing) // open: nothing to ask

        // The background locks the wallet; the return asks again.
        g.leave()
        precondition(g.phase == .away && g.covered && !g.secretsUnlocked)
        g.leave()
        precondition(g.phase == .away)
        let back = ticket(g.ask())
        precondition(back == first + 1)
        g.checked(back, passed: true)
        precondition(g.secretsUnlocked)

        // A failed or cancelled check: covered and locked, until a retry passes.
        g.leave()
        let failing = ticket(g.ask())
        g.checked(failing, passed: false)
        precondition(g.phase == .refused && g.covered && !g.secretsUnlocked)
        g.leave() // to the background with the card up: still refused
        precondition(g.phase == .refused)
        let retry = ticket(g.ask())
        g.checked(retry, passed: true)
        precondition(g.secretsUnlocked)

        // The app leaves during a check: its result (the system cancels it) is ignored, and the return asks again.
        g = SessionGate()
        let cancelled = ticket(g.ask())
        g.leave()
        precondition(g.phase == .away)
        g.checked(cancelled, passed: false)
        precondition(g.phase == .away)
        let again = ticket(g.ask())
        g.checked(cancelled, passed: true) // a stale ticket cannot open the session
        precondition(g.phase == .checking && !g.secretsUnlocked)
        g.checked(again, passed: true)
        precondition(g.secretsUnlocked)

        // A restart inside an open session (the machine stopped, or the guest rebooted) asks again.
        g.end()
        precondition(g.phase == .closed && !g.secretsUnlocked && g.covered)
        let restart = ticket(g.ask())
        g.checked(restart, passed: true)
        precondition(g.secretsUnlocked)

        // Which check a session gets: Linux asks; a Mac has no wallet and does not ask; HENGE_AUTOPILOT in the
        // launch environment skips the check, and nothing else does.
        precondition(SessionGate.Check.for(linux: true, environment: [:]) == .faceID)
        precondition(SessionGate.Check.for(linux: false, environment: [:]) == .none)
        precondition(SessionGate.Check.for(linux: false, environment: ["HENGE_AUTOPILOT": "1"]) == .none)
        precondition(SessionGate.Check.for(linux: true, environment: ["HENGE_AUTOPILOT": "1"]) == .skippedForTest)
        precondition(SessionGate.Check.for(linux: true, environment: ["HENGE_AUTOPILOT_ONCE": "1"]) == .faceID)

        // A Mac: never covered, never asks, and no wallet to unlock.
        var mac = SessionGate(check: .none)
        precondition(mac.ask() == .opened && mac.phase == .open && !mac.covered && !mac.secretsUnlocked)
        mac.leave()
        precondition(mac.ask() == .opened && !mac.covered)
        mac.end()
        precondition(mac.ask() == .opened)

        // Autopilot: the session opens with no check, but the wallet stays locked unless the test unlocks it.
        var auto = SessionGate(check: .skippedForTest)
        precondition(auto.ask() == .opened && !auto.covered && !auto.secretsUnlocked)
        auto.unlockForTest()
        precondition(auto.secretsUnlocked)
        auto.leave()
        precondition(!auto.secretsUnlocked) // the background locks it as usual
        precondition(auto.ask() == .opened && auto.secretsUnlocked)
        var faceID = SessionGate()
        faceID.unlockForTest() // only a skipped check can be unlocked this way
        precondition(ticket(faceID.ask()) == 1 && !faceID.secretsUnlocked)
        precondition(SessionGate.testUnlock(environment: ["HENGE_AUTOPILOT_WALLET": "unlocked"]))
        precondition(!SessionGate.testUnlock(environment: ["HENGE_AUTOPILOT_WALLET": "1"]))
        precondition(!SessionGate.testUnlock(environment: [:]))

        // One Keychain service per machine, and back.
        let a = UUID(uuidString: "0D3A5F6E-1C2B-4E8F-9A7B-6C5D4E3F2A1B")!, b = UUID()
        precondition(WalletScope.id(a) == "0d3a5f6e-1c2b-4e8f-9a7b-6c5d4e3f2a1b")
        precondition(WalletScope.service(a) == "com.henge.linux-wallet.0d3a5f6e-1c2b-4e8f-9a7b-6c5d4e3f2a1b")
        precondition(WalletScope.service(a) != WalletScope.service(b))
        precondition(WalletScope.machine(service: WalletScope.service(a)) == a)
        precondition(WalletScope.machine(service: "com.henge.other") == nil)
        precondition(WalletScope.machine(service: WalletScope.servicePrefix + "not-a-uuid") == nil)
        // The scope is a valid host/secrets.c id: [A-Za-z0-9._-], 1 to 64, not starting with '.'.
        let id = WalletScope.id(b)
        precondition(id.count <= 64 && !id.hasPrefix(".") && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })

        print("test_session_gate: ok")
    }
}
