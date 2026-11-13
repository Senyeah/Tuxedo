/// When a session asks for Face ID, and when a Linux machine's wallet is open. A Linux machine asks at each start
/// (a restart too) and each time the app comes back from the background; the machine stays paused and hidden until
/// the check passes. A Mac does not ask: it has no wallet.
/// Pure policy: SessionAuth does the check, SessionView and KeychainStore follow the phase.
struct SessionGate: Equatable {
    /// Face ID only (no passcode fallback, items lost when Face ID enrolment changes). The owner chose the passcode
    /// fallback: SessionAuth and KeychainStore read this one value.
    static let faceIDOnly = false

    enum Check: Equatable {
        case faceID
        case none           // a Mac
        case skippedForTest // HENGE_AUTOPILOT: the session opens, the wallet stays locked

        /// Only the launch environment skips the check (devicectl launch -e), not a file in Documents.
        static func `for`(linux: Bool, environment: [String: String]) -> Check {
            guard linux else { return .none }
            return environment["HENGE_AUTOPILOT"] != nil ? .skippedForTest : .faceID
        }
    }

    /// A test that skipped the check unlocks the wallet only when it says so.
    static func testUnlock(environment: [String: String]) -> Bool { environment["HENGE_AUTOPILOT_WALLET"] == "unlocked" }

    enum Phase: Equatable {
        case closed   // no session, or its machine stopped
        case checking // a check is on screen
        case open     // checked (or no check needed)
        case away     // the app is in the background
        case refused  // the check failed or was cancelled
    }

    enum Ask: Equatable {
        case check(Int) // show the check; its ticket
        case opened     // open with no check
        case nothing    // a check is on screen, or the session is open
    }

    let check: Check
    private(set) var phase = Phase.closed
    private(set) var ticket = 0
    private var testUnlocked = false

    init(check: Check = .faceID) { self.check = check }

    var secretsUnlocked: Bool { phase == .open && (check == .faceID || testUnlocked) }
    /// The guest's screen is hidden and the machine does not run.
    var covered: Bool { phase != .open }

    /// The guest is hidden on the phone and on every external screen. inactive: the scene is not active, as when
    /// the app switcher takes its picture. A stopped machine (closed) shows its card instead.
    func hidesGuest(inactive: Bool) -> Bool {
        guard check == .faceID, phase != .closed else { return false }
        return covered || inactive
    }

    /// An external screen has no stopped card: it stays black whenever the session is not open, closed too.
    func blanksExternal(inactive: Bool) -> Bool {
        guard check == .faceID else { return false }
        return covered || inactive
    }

    /// At the start, back from the background, or again after a refusal.
    mutating func ask() -> Ask {
        switch phase {
        case .closed, .away, .refused:
            guard check == .faceID else {
                phase = .open
                return .opened
            }
            phase = .checking
            ticket += 1
            return .check(ticket)
        case .checking, .open:
            return .nothing
        }
    }

    /// A check's result. A result for an older check, or after the app left, is ignored.
    mutating func checked(_ ticket: Int, passed: Bool) {
        guard phase == .checking, ticket == self.ticket else { return }
        phase = passed ? .open : .refused
    }

    mutating func unlockForTest() {
        if check == .skippedForTest { testUnlocked = true }
    }

    /// The app went to the background: the wallet locks, and the next return asks again.
    mutating func leave() {
        if phase == .open || phase == .checking { phase = .away }
    }

    /// The session closed, or its machine stopped or restarts: the next start asks again.
    mutating func end() {
        phase = .closed
    }
}
