import Foundation

/// The on-screen keyboard follows a Linux desktop: henge-keyboard in the guest says when the focused program
/// wants text (host/share.c, /.henge/keyboard). Pure policy, no UIKit.
struct KeyboardFollow {
    static let storageKey = "henge.linux.keyboardFollows"

    /// The last request this has seen. The count goes on from one machine to the next.
    private(set) var seq: UInt
    /// The keyboard is up because the guest asked. Only then does the guest's "hide" close it.
    private(set) var raised = false

    /// `seq`: the count when the session starts, so an older machine's request is not news.
    init(seq: UInt = 0) { self.seq = seq }

    /// A look at the host. Returns the new value for the keyboard, or nil to leave it.
    /// `allowed` is false when this must not move the keyboard (the setting is off, the console has the keys).
    mutating func poll(wanted: Bool, seq: UInt, typing: Bool, allowed: Bool) -> Bool? {
        guard allowed else {
            raised = false // the request waits: it is news when this is allowed again
            return nil
        }
        guard seq != self.seq else { return nil }
        self.seq = seq
        if wanted {
            guard !typing else { return nil } // the person opened it: it stays theirs
            raised = true
            return true
        }
        guard raised, typing else {
            raised = false
            return nil
        }
        raised = false
        return false
    }

    /// The keyboard went away by other means (its button, the system's hide key, the console).
    /// It stays down until the guest asks again.
    mutating func closed() { raised = false }
}
