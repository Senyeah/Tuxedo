import Foundation

@main
struct KeyboardFollowTests {
    /// KeyboardPanel.fraction: the keyboard's part of the guest picture.
    static func panel() {
        func f(_ keyboard: CGRect, _ picture: CGRect) -> Double { KeyboardPanel.fraction(keyboard: keyboard, picture: picture) }
        // A phone upright, 402 x 874 pt: the picture is the whole screen, the keyboard the bottom 336 pt.
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        precondition(f(CGRect(x: 0, y: 538, width: 402, height: 336), screen) == 0.384)
        // The picture ends above the home bar (34 pt) and starts under the top inset (62 pt).
        let safe = CGRect(x: 0, y: 62, width: 402, height: 778)
        precondition(f(CGRect(x: 0, y: 538, width: 402, height: 336), safe) == 0.388) // 302 of 778
        // On its side, 874 x 402 pt: the keyboard takes more than half.
        precondition(f(CGRect(x: 0, y: 182, width: 874, height: 220), CGRect(x: 62, y: 0, width: 750, height: 381)) == 0.522)
        // The keyboard is down: no frame, an empty frame, or a frame below the screen.
        precondition(f(.null, screen) == 0)
        precondition(f(CGRect(x: 0, y: 874, width: 402, height: 0), screen) == 0)
        precondition(f(CGRect(x: 0, y: 874, width: 402, height: 336), screen) == 0)
        // Only the row of keys for a hardware keyboard.
        precondition(f(CGRect(x: 0, y: 819, width: 402, height: 55), screen) == 0.063)
        // The keyboard covers the picture and more: 1, never above.
        precondition(f(CGRect(x: 0, y: 0, width: 402, height: 874), CGRect(x: 0, y: 100, width: 402, height: 300)) == 1)
        // A picture above the keyboard (a small window in the top half) is not covered.
        precondition(f(CGRect(x: 0, y: 538, width: 402, height: 336), CGRect(x: 0, y: 100, width: 402, height: 300)) == 0)
        // A floating keyboard does not reach the bottom edge: a window cannot get out of its way.
        precondition(f(CGRect(x: 50, y: 300, width: 300, height: 200), screen) == 0)
        // A keyboard beside the picture.
        precondition(f(CGRect(x: 500, y: 538, width: 402, height: 336), screen) == 0)
        // No picture.
        precondition(f(CGRect(x: 0, y: 538, width: 402, height: 336), .zero) == 0)
        // The picture is zoomed and goes below the screen: the keyboard does not reach its bottom edge.
        precondition(f(CGRect(x: 0, y: 538, width: 402, height: 336), CGRect(x: -200, y: -300, width: 804, height: 1748)) == 0)
    }

    /// KeyboardFrameMemory: a probe made later reports from the frame that was kept.
    static func memory() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        func part(_ m: KeyboardFrameMemory) -> Double { KeyboardPanel.fraction(keyboard: m.frame, picture: screen) }
        var m = KeyboardFrameMemory()
        precondition(m.frame.isNull && part(m) == 0) // nothing heard yet
        // The keyboard comes up while no probe is there (the console shows). A new probe reads the memory.
        m.willChange(to: CGRect(x: 0, y: 538, width: 402, height: 336))
        precondition(part(m) == 0.384)
        // It changes its height (another keyboard, the emoji keys).
        m.willChange(to: CGRect(x: 0, y: 500, width: 402, height: 374))
        precondition(part(m) == 0.428)
        // It goes down: first to below the screen, then it is hidden.
        m.willChange(to: CGRect(x: 0, y: 874, width: 402, height: 374))
        precondition(part(m) == 0)
        m.didHide()
        precondition(m.frame.isNull && part(m) == 0)
        // A notification with no frame is "down".
        m.willChange(to: CGRect(x: 0, y: 538, width: 402, height: 336))
        m.willChange(to: nil)
        precondition(m.frame.isNull)
    }

    static func main() {
        // The guest asks: the keyboard comes up, then goes down.
        var f = KeyboardFollow(seq: 7)
        precondition(f.poll(wanted: true, seq: 7, typing: false, allowed: true) == nil) // an older machine's request
        precondition(f.poll(wanted: true, seq: 8, typing: false, allowed: true) == true)
        precondition(f.raised)
        precondition(f.poll(wanted: true, seq: 8, typing: true, allowed: true) == nil) // nothing new
        precondition(f.poll(wanted: false, seq: 9, typing: true, allowed: true) == false)
        precondition(!f.raised)
        precondition(f.poll(wanted: false, seq: 9, typing: false, allowed: true) == nil)

        // The helper starts with "hide": nothing moves.
        f = KeyboardFollow(seq: 0)
        precondition(f.poll(wanted: false, seq: 1, typing: false, allowed: true) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: true, allowed: true) == nil)

        // A keyboard the person opened is not closed by the guest.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: true, allowed: true) == nil)
        precondition(!f.raised)
        precondition(f.poll(wanted: false, seq: 2, typing: true, allowed: true) == nil)

        // The person closes a keyboard the guest raised: it stays down until the guest asks again.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)
        f.closed()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: false, allowed: true) == nil)
        precondition(f.poll(wanted: true, seq: 3, typing: false, allowed: true) == true)
        // Closed, opened by hand, then the guest's hide: the keyboard stays.
        f.closed()
        precondition(f.poll(wanted: false, seq: 4, typing: true, allowed: true) == nil)

        // The same request sent again (the helper started again) with the keyboard closed by hand: it comes back.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)
        f.closed()
        precondition(f.poll(wanted: true, seq: 2, typing: false, allowed: true) == true)

        // Not allowed (the console has the keys): nothing moves, and the newest request waits.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: false) == nil)
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: false) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: false, allowed: false) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: false, allowed: true) == nil)
        // Raised, then not allowed: a later hide does not close a keyboard that is not this one's.
        precondition(f.poll(wanted: true, seq: 3, typing: false, allowed: true) == true)
        precondition(f.poll(wanted: true, seq: 3, typing: true, allowed: false) == nil)
        precondition(!f.raised)
        precondition(f.poll(wanted: false, seq: 4, typing: true, allowed: true) == nil)

        // A button is down (a drag): the guest's hide waits, then closes the keyboard it raised.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)
        precondition(f.poll(wanted: true, seq: 1, typing: true, allowed: true, held: true) == nil)
        precondition(f.raised)
        precondition(f.poll(wanted: false, seq: 2, typing: true, allowed: true, held: true) == nil)
        precondition(f.raised)
        precondition(f.poll(wanted: false, seq: 2, typing: true, allowed: true) == false)
        // A raise during the drag comes when it ends.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true, held: true) == nil)
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)

        // The count wraps or starts again: any change is news.
        f = KeyboardFollow(seq: 100)
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)

        panel()
        memory()
        print("test_keyboard_follow: ok")
    }
}
