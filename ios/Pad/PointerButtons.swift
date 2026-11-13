import Foundation

/// Who holds each mouse button. The guest hears a press only when the first owner presses
/// and a release only when the last owner lets go, so a tap during a held key cannot drop the
/// drag. Button 0 is left, 1 is right. Pure Swift: `send` goes to the guest.
final class PointerButtons {
    enum Owner: Hashable {
        case key            // an on-screen key
        case tap            // a tap's down-then-up
        case hold           // a touch-and-hold drag on the pad
        case latch          // a held left key that the keyboard covered: it lets go at the last lift
        case accessibility  // VoiceOver's "Hold"
        case volume         // Henge's volume buttons: a physical key, so the keyboard leaves it held
    }

    private let send: (Int, Bool) -> Void
    /// After each change the guest hears, for the look.
    var onChange: ((Int, Bool) -> Void)?
    /// A key went down while fingers were on the pad: the pad's gesture is used up.
    var onGestureUsed: (() -> Void)?

    private var owners: [Set<Owner>] = [[], []]
    private(set) var padFingers = 0
    /// A key went down during this pad gesture: no tap click and no hold until all fingers lift.
    private(set) var gestureUsed = false

    init(send: @escaping (Int, Bool) -> Void) { self.send = send }

    func isDown(_ b: Int) -> Bool { owners.indices.contains(b) && !owners[b].isEmpty }
    func holds(_ b: Int, _ o: Owner) -> Bool { owners.indices.contains(b) && owners[b].contains(o) }
    var keyHeld: Bool { owners[0].contains(.key) || owners[1].contains(.key) }
    var anyDown: Bool { isDown(0) || isDown(1) }

    /// Returns true when the guest heard a press.
    @discardableResult
    func press(_ b: Int, by o: Owner) -> Bool {
        guard owners.indices.contains(b), !owners[b].contains(o) else { return false }
        let first = owners[b].isEmpty
        owners[b].insert(o)
        if first { tell(b, true) }
        return first
    }

    /// Returns true when the guest heard a release.
    @discardableResult
    func release(_ b: Int, by o: Owner) -> Bool {
        guard owners.indices.contains(b), owners[b].remove(o) != nil else { return false }
        guard owners[b].isEmpty else { return false }
        tell(b, false)
        return true
    }

    private func tell(_ b: Int, _ down: Bool) {
        send(b, down)
        onChange?(b, down)
    }

    // MARK: The pad

    func padFingers(_ n: Int) { padFingers = max(n, 0) }

    /// All fingers are off the pad. Returns true when a latch let go.
    @discardableResult
    func padLifted() -> Bool {
        padFingers = 0
        gestureUsed = false
        return release(0, by: .latch)
    }

    /// A tap on the pad: down then up. Nothing while a key is down or after a key used the gesture.
    @discardableResult
    func tap(_ b: Int) -> Bool {
        guard !gestureUsed, !keyHeld else { return false }
        let sent = press(b, by: .tap)
        release(b, by: .tap)
        return sent
    }

    /// The hold timer fired. A late timer, a used gesture or a held key presses nothing.
    @discardableResult
    func holdStart() -> Bool {
        guard !gestureUsed, !keyHeld, !owners[0].contains(.hold) else { return false }
        press(0, by: .hold)
        return true
    }

    /// Returns true when there was a hold to end.
    @discardableResult
    func holdEnd() -> Bool {
        let had = owners[0].contains(.hold)
        release(0, by: .hold)
        return had
    }

    // MARK: The keys

    func keyDown(_ b: Int) {
        if padFingers > 0, !gestureUsed {
            gestureUsed = true
            onGestureUsed?()
        }
        press(b, by: .key)
    }

    func keyUp(_ b: Int) { release(b, by: .key) }

    /// The keyboard came up over the keys. A held left key becomes a latch, so the key can fade
    /// with no effect on the guest; a held right key lets go. Returns true when the left let go now.
    @discardableResult
    func keyboardRaised() -> Bool {
        release(1, by: .key)
        guard owners[0].contains(.key) else { return false }
        owners[0].remove(.key)
        owners[0].insert(.latch)
        return padFingers == 0 && release(0, by: .latch)
    }

    /// Each held button lets go once.
    func releaseAll() {
        for b in owners.indices where !owners[b].isEmpty {
            owners[b] = []
            tell(b, false)
        }
        gestureUsed = false
    }
}

/// Which pad gestures click, by the input mode and the keyboard.
enum PadInputMode: String, Codable, CaseIterable {
    case touchscreen, volumeButtons
}

enum PadClickRule {
    /// A one-finger tap and a touch-and-hold. In the Volume buttons mode the volume keys click,
    /// unless the keyboard is up and hides the on-screen keys (the owner's decision 4).
    static func tapsClick(_ mode: PadInputMode, keyboardUp: Bool) -> Bool {
        mode == .touchscreen || keyboardUp
    }

    /// A two-finger tap is a right click in each mode, with or without the keys.
    static func twoFingerTapClicks(_ mode: PadInputMode, keyboardUp: Bool) -> Bool { true }
}
