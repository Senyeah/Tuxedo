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

        // Which check a session gets: Face ID; TUX_AUTOPILOT in the launch environment skips the check, and
        // nothing else does.
        precondition(SessionGate.Check.for(environment: [:]) == .faceID)
        precondition(SessionGate.Check.for(environment: ["TUX_AUTOPILOT": "1"]) == .skippedForTest)
        precondition(SessionGate.Check.for(environment: ["TUX_AUTOPILOT_ONCE": "1"]) == .faceID)

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
        precondition(SessionGate.testUnlock(environment: ["TUX_AUTOPILOT_WALLET": "unlocked"]))
        precondition(!SessionGate.testUnlock(environment: ["TUX_AUTOPILOT_WALLET": "1"]))
        precondition(!SessionGate.testUnlock(environment: [:]))

        // What hides the guest, on the phone and on every external screen: anything but an open session, and an
        // open one while the scene is inactive (the app switcher takes its picture then).
        var hide = SessionGate()
        precondition(!hide.hidesGuest(inactive: false) && !hide.hidesGuest(inactive: true)) // closed: the stopped card
        let h1 = ticket(hide.ask())
        precondition(hide.hidesGuest(inactive: false)) // checking
        hide.checked(h1, passed: true)
        precondition(!hide.hidesGuest(inactive: false) && hide.hidesGuest(inactive: true))
        hide.leave()
        precondition(hide.hidesGuest(inactive: false)) // away
        let h2 = ticket(hide.ask())
        hide.checked(h2, passed: false)
        precondition(hide.hidesGuest(inactive: false)) // refused
        var autoHide = SessionGate(check: .skippedForTest)
        _ = autoHide.ask()
        precondition(!autoHide.hidesGuest(inactive: true) && !autoHide.blanksExternal(inactive: true))

        // An external screen has no stopped card: it stays black whenever the session is not open, closed too
        // (the machine stopped while away or refused would leave its last frame there).
        var ext = SessionGate()
        precondition(ext.blanksExternal(inactive: false)) // closed, before the first check
        let e1 = ticket(ext.ask())
        precondition(ext.blanksExternal(inactive: false))
        ext.checked(e1, passed: true)
        precondition(!ext.blanksExternal(inactive: false) && ext.blanksExternal(inactive: true))
        ext.leave()
        ext.end() // the machine stopped while away
        precondition(ext.blanksExternal(inactive: false) && !ext.hidesGuest(inactive: false))

        // Leaving: the phone's scene in the background, or the device locking, locks the wallet and asks again on
        // return, even while an external screen's scene keeps the app active (the machine then keeps running).
        typealias S = SessionGate.Scene
        precondition(SessionGate.away(scene: .background, appInBackground: true, deviceLocking: false) == .init(lock: true, pause: true))
        precondition(SessionGate.away(scene: .background, appInBackground: false, deviceLocking: false) == .init(lock: true, pause: false))
        precondition(SessionGate.away(scene: S.active, appInBackground: false, deviceLocking: true) == .init(lock: true, pause: false))
        precondition(SessionGate.away(scene: .inactive, appInBackground: false, deviceLocking: false) == .init(lock: false, pause: false))
        precondition(SessionGate.away(scene: .active, appInBackground: false, deviceLocking: false) == .init(lock: false, pause: false))

        // Once per launch of the app: the first pass is the only check. The background, a restart and another machine
        // ask no more; the device locking still does.
        precondition(SessionGate.oncePerLaunch)
        SessionGate.passedThisLaunch = false
        var once = SessionGate(once: true)
        let o1 = ticket(once.ask())
        once.checked(o1, passed: false)
        precondition(!SessionGate.passedThisLaunch && once.phase == .refused) // a refusal is not a pass
        let o2 = ticket(once.ask())
        once.checked(o2, passed: true)
        precondition(SessionGate.passedThisLaunch && once.secretsUnlocked)
        once.leave() // the app goes to the background
        precondition(once.phase == .open && once.secretsUnlocked && !once.covered)
        precondition(once.hidesGuest(inactive: true) && !once.hidesGuest(inactive: false)) // the app switcher still sees black
        once.leave(deviceLocking: true)
        precondition(once.phase == .away && !once.secretsUnlocked)
        precondition(once.ask() == .opened && once.secretsUnlocked) // back: no check
        once.end() // the guest restarted
        precondition(once.ask() == .opened && once.secretsUnlocked)
        var other = SessionGate(once: true) // another machine in the same launch
        precondition(other.ask() == .opened && other.secretsUnlocked)
        var each = SessionGate() // the old behaviour is still there with once: false
        precondition(ticket(each.ask()) == 1)
        SessionGate.passedThisLaunch = false
        var fresh = SessionGate(once: true) // a new launch of the app
        _ = ticket(fresh.ask())
        var checking = SessionGate(once: true)
        _ = ticket(checking.ask())
        checking.leave() // the app leaves during the first check: that is not a pass
        precondition(checking.phase == .away)
        _ = ticket(checking.ask())
        SessionGate.passedThisLaunch = false

        // One Keychain service per machine, and back.
        let a = UUID(uuidString: "0D3A5F6E-1C2B-4E8F-9A7B-6C5D4E3F2A1B")!, b = UUID()
        precondition(WalletScope.id(a) == "0d3a5f6e-1c2b-4e8f-9a7b-6c5d4e3f2a1b")
        precondition(WalletScope.service(a) == "nz.jackgreenhill.tuxedo.linux-wallet.v2.0d3a5f6e-1c2b-4e8f-9a7b-6c5d4e3f2a1b")
        precondition(WalletScope.service(a) != WalletScope.service(b))
        // The scope is a valid host/secrets.c id: [A-Za-z0-9._-], 1 to 64, not starting with '.'.
        let id = WalletScope.id(b)
        precondition(id.count <= 64 && !id.hasPrefix(".") && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })

        print("test_session_gate: ok")
    }
}
