import CoreGraphics
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

/// Where the keyboard is, kept for the whole session. A probe that is made while the keyboard is up
/// (back from the console, an external screen gone) then reports its part at once.
struct KeyboardFrameMemory {
    /// The screen's coordinates; null while the keyboard is down.
    private(set) var frame = CGRect.null

    /// The keyboard goes to `end`; nil is a notification with no frame.
    mutating func willChange(to end: CGRect?) { frame = end ?? .null }
    mutating func didHide() { frame = .null }
}

/// How much of a Linux guest's picture the keyboard covers. In Plasma, henge-keyboard is KWin's input method and
/// makes its panel that high, so KWin keeps the active window above the keyboard (host/share.c, GET /.henge/keyboard).
enum KeyboardPanel {
    /// The part of the picture's height under the keyboard, 0...1. Both rectangles are in the same coordinates.
    /// A keyboard that does not reach the picture's bottom edge (a floating one) covers nothing a window can leave.
    static func fraction(keyboard: CGRect, picture: CGRect) -> Double {
        guard !keyboard.isNull, keyboard.height > 0, picture.width > 0, picture.height > 0 else { return 0 }
        guard keyboard.minX < picture.maxX, keyboard.maxX > picture.minX else { return 0 }
        guard keyboard.maxY >= picture.maxY - 1, keyboard.minY < picture.maxY else { return 0 }
        let covered = picture.maxY - max(keyboard.minY, picture.minY)
        return Double((covered / picture.height * 1000).rounded() / 1000)
    }
}
