import Foundation

// Owners for each mouse button (ios/Pad/PointerButtons.swift).
@main
struct PointerButtonsTests {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); failures += 1 }
    }

    struct Sent: Equatable { var b: Int; var down: Bool }
    static func make() -> (PointerButtons, () -> [Sent]) {
        var log: [Sent] = []
        let p = PointerButtons { log.append(Sent(b: $0, down: $1)) }
        return (p, { defer { log = [] }; return log })
    }
    static let d0 = Sent(b: 0, down: true), u0 = Sent(b: 0, down: false)
    static let d1 = Sent(b: 1, down: true), u1 = Sent(b: 1, down: false)

    static func main() {
        // A tap during a held key does not release the key.
        do {
            let (p, sent) = make()
            p.keyDown(0)
            check(sent() == [d0], "the key presses")
            p.padFingers(1)
            check(!p.tap(0), "a tap during a held key does not click")
            p.padLifted()
            check(sent() == [] && p.isDown(0), "the key is still down after the tap")
            p.keyUp(0)
            check(sent() == [u0], "the key lets go")
        }
        // Two owners release in each order; the guest hears one press and one release.
        for order in [[PointerButtons.Owner.key, .accessibility], [.accessibility, .key]] {
            let (p, sent) = make()
            p.press(0, by: .key)
            p.press(0, by: .accessibility)
            check(sent() == [d0], "two owners: one press")
            p.release(0, by: order[0])
            check(sent() == [] && p.isDown(0), "two owners: the first release sends nothing")
            p.release(0, by: order[1])
            check(sent() == [u0], "two owners: the last release sends the release")
            p.release(0, by: order[1])
            check(sent() == [], "a second release sends nothing")
        }
        // releaseAll sends each held button once.
        do {
            let (p, sent) = make()
            p.press(0, by: .key)
            p.press(0, by: .hold)
            p.press(1, by: .key)
            _ = sent()
            p.releaseAll()
            check(sent() == [u0, u1], "releaseAll lets go of each button once")
            p.releaseAll()
            check(sent() == [], "a second releaseAll sends nothing")
            check(!p.isDown(0) && !p.isDown(1), "nothing is down after releaseAll")
        }
        // A key tap during a pointing gesture sends exactly one click.
        do {
            let (p, sent) = make()
            var used = 0
            p.onGestureUsed = { used += 1 }
            p.padFingers(1)
            p.keyDown(0)
            p.keyUp(0)
            check(used == 1, "the key press uses up the gesture once")
            check(!p.tap(0), "the lift after a key tap is not a second click")
            check(!p.holdStart(), "a late hold timer presses nothing")
            p.padLifted()
            check(sent() == [d0, u0], "exactly one click")
            // The next gesture clicks again.
            p.padFingers(1)
            check(p.tap(0), "after all fingers lift, a tap clicks again")
            p.padLifted()
            check(sent() == [d0, u0], "the next tap is one click")
        }
        // A hold-drag: a late or second timer cannot press twice.
        do {
            let (p, sent) = make()
            p.padFingers(1)
            check(p.holdStart(), "the hold presses")
            check(!p.holdStart(), "a second timer does not press again")
            check(sent() == [d0], "one press for the hold")
            p.keyDown(0)
            p.keyUp(0)
            check(sent() == [], "a key tap during a hold-drag does not drop the drag")
            check(p.holdEnd(), "the hold ends at the lift")
            p.padLifted()
            check(sent() == [u0], "one release for the hold")
        }
        // The latch: a held left key under the keyboard.
        do {
            let (p, sent) = make()
            p.padFingers(1)
            p.keyDown(0)
            _ = sent()
            check(!p.keyboardRaised(), "with a finger on the pad the latch holds")
            check(sent() == [], "a key that changes to a latch sends nothing")
            p.keyUp(0)
            check(sent() == [] && p.isDown(0), "the key's own lift does not release the latch")
            check(p.padLifted(), "the latch lets go at the last lift")
            check(sent() == [u0], "the latch releases once")
            p.padLifted()
            check(sent() == [], "the latch does not release twice")
        }
        do {
            let (p, sent) = make()
            p.keyDown(0)
            _ = sent()
            check(p.keyboardRaised(), "a latch with no finger lets go at once")
            check(sent() == [u0], "and sends one release")
        }
        do {
            let (p, sent) = make()
            p.padFingers(1)
            p.keyDown(1)
            _ = sent()
            p.keyboardRaised()
            check(sent() == [u1], "a held right key lets go when the keyboard comes up")
            p.keyUp(1)
            check(sent() == [], "and its own lift sends nothing more")
        }
        // A mouse holds left: a pad tap and a key neither press again nor end the mouse's drag.
        do {
            let (p, sent) = make()
            p.press(0, by: .mouse)
            check(sent() == [d0], "the mouse presses")
            p.padFingers(1)
            check(!p.tap(0), "a tap during a mouse hold sends nothing")
            p.padLifted()
            p.keyDown(0)
            p.keyUp(0)
            check(sent() == [] && p.isDown(0), "the mouse still holds after a tap and a key")
            p.release(0, by: .mouse)
            check(sent() == [u0], "the mouse lets go")
        }
        // A two-finger tap is a right click.
        do {
            let (p, sent) = make()
            p.padFingers(2)
            check(p.tap(1), "a two-finger tap clicks")
            check(sent() == [d1, u1], "a right click is down then up")
        }

        // The keyboard-up click rules.
        check(PadClickRule.tapsClick(.touchscreen, keyboardUp: false), "Touchscreen: a tap clicks")
        check(PadClickRule.tapsClick(.touchscreen, keyboardUp: true), "Touchscreen, keyboard up: a tap clicks")
        check(!PadClickRule.tapsClick(.volumeButtons, keyboardUp: false), "Volume buttons: a tap does not click")
        check(PadClickRule.tapsClick(.volumeButtons, keyboardUp: true), "Volume buttons, keyboard up: a tap clicks")
        for mode in PadInputMode.allCases {
            for up in [false, true] {
                check(PadClickRule.twoFingerTapClicks(mode, keyboardUp: up), "a two-finger tap is a right click: \(mode), keyboard up \(up)")
            }
        }

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("test_pointer_buttons: all passed")
    }
}
