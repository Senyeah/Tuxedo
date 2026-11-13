/// When a session asks for Face ID, and when a Linux machine's wallet is open. Every machine asks, at its start and
/// each time the app comes back from the background; the machine stays paused and hidden until the check passes.
/// Pure policy: SessionAuth does the check, SessionView and KeychainStore follow the phase.
struct SessionGate: Equatable {
    /// Face ID only (no passcode fallback, items lost when Face ID enrolment changes). The owner chose the passcode
    /// fallback: SessionAuth and KeychainStore read this one value.
    static let faceIDOnly = false

    enum Phase: Equatable {
        case closed   // no session
        case checking // a check is on screen
        case open     // checked; the wallet is unlocked
        case away     // the app is in the background
        case refused  // the check failed or was cancelled
    }

    private(set) var phase = Phase.closed
    private(set) var ticket = 0

    var secretsUnlocked: Bool { phase == .open }
    /// The guest's screen is hidden and the machine does not run.
    var covered: Bool { phase != .open }

    /// Starts a check when one is due (at the start, back from the background, or again after a refusal).
    /// Returns its ticket, or nil when a check is on screen or the session is open.
    mutating func ask() -> Int? {
        switch phase {
        case .closed, .away, .refused:
            phase = .checking
            ticket += 1
            return ticket
        case .checking, .open:
            return nil
        }
    }

    /// A check's result. A result for an older check, or after the app left, is ignored.
    mutating func checked(_ ticket: Int, passed: Bool) {
        guard phase == .checking, ticket == self.ticket else { return }
        phase = passed ? .open : .refused
    }

    /// The app went to the background: the wallet locks, and the next return asks again.
    mutating func leave() {
        if phase == .open || phase == .checking { phase = .away }
    }

    /// The session closed or its machine stopped.
    mutating func end() {
        phase = .closed
    }
}
