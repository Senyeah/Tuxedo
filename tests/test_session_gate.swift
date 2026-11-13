import Foundation

@main
struct SessionGateTests {
    static func main() {
        // The owner's choice: the passcode is the fallback.
        precondition(!SessionGate.faceIDOnly)

        // Nothing runs before the first check.
        var g = SessionGate()
        precondition(g.phase == .closed && g.covered && !g.secretsUnlocked)
        let first = g.ask()!
        precondition(g.phase == .checking && g.covered && !g.secretsUnlocked)
        precondition(g.ask() == nil) // one check at a time
        g.checked(first, passed: true)
        precondition(g.phase == .open && !g.covered && g.secretsUnlocked)
        precondition(g.ask() == nil) // open: nothing to ask

        // The background locks the wallet; the return asks again.
        g.leave()
        precondition(g.phase == .away && g.covered && !g.secretsUnlocked)
        g.leave()
        precondition(g.phase == .away)
        let back = g.ask()!
        precondition(back == first + 1)
        g.checked(back, passed: true)
        precondition(g.secretsUnlocked)

        // A failed or cancelled check: covered and locked, until a retry passes.
        g.leave()
        let failing = g.ask()!
        g.checked(failing, passed: false)
        precondition(g.phase == .refused && g.covered && !g.secretsUnlocked)
        g.leave() // to the background with the card up: still refused
        precondition(g.phase == .refused)
        let retry = g.ask()!
        g.checked(retry, passed: true)
        precondition(g.secretsUnlocked)

        // The app leaves during a check: its result (the system cancels it) is ignored, and the return asks again.
        g = SessionGate()
        let cancelled = g.ask()!
        g.leave()
        precondition(g.phase == .away)
        g.checked(cancelled, passed: false)
        precondition(g.phase == .away)
        let again = g.ask()!
        g.checked(cancelled, passed: true) // a stale ticket cannot open the session
        precondition(g.phase == .checking && !g.secretsUnlocked)
        g.checked(again, passed: true)
        precondition(g.secretsUnlocked)

        // The session ends: locked, and a new session asks again.
        g.end()
        precondition(g.phase == .closed && !g.secretsUnlocked)
        precondition(g.ask() != nil)

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
