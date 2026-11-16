// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct MouseScrollTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func main() {
        // The wheel of the phone's mouse arrived on the second value: that is up and down.
        var wheel = MouseScroll()
        var s = wheel.hiRes(0, 5, scale: 0.3, reverse: false)
        check(s.horizontal == 0, "a vertical wheel must not move sideways")
        check(s.vertical > 0, "a positive second value scrolls up")
        check(s.vertical % MouseScroll.hiResPerStep == 0, "hi-res units come in steps")
        s = wheel.hiRes(0, -5, scale: 0.3, reverse: false)
        check(s.vertical < 0 && s.horizontal == 0, "a negative second value scrolls down")

        // The first value is sideways.
        var side = MouseScroll()
        s = side.hiRes(4, 0, scale: 0.3, reverse: false)
        check(s.horizontal > 0 && s.vertical == 0, "a positive first value scrolls right")

        // One move reported twice, each time with the other axis still at its old value.
        var twice = MouseScroll()
        _ = twice.hiRes(0, 6, scale: 0.3, reverse: false)
        s = twice.hiRes(0, 6, scale: 0.3, reverse: false)
        check(s.vertical == 0 && s.horizontal == 0, "an unchanged value must not scroll again")

        // A mostly vertical move leaves out a small sideways drift.
        var drift = MouseScroll()
        s = drift.hiRes(1, 9, scale: 0.3, reverse: false)
        check(s.horizontal == 0 && s.vertical > 0, "drift must not scroll sideways")

        // Reverse flips both; swapped axes read the values the other way round.
        var plain = MouseScroll(), reversed = MouseScroll(), swapped = MouseScroll(swapsAxes: true)
        let p = plain.hiRes(0, 5, scale: 0.3, reverse: false)
        let r = reversed.hiRes(0, 5, scale: 0.3, reverse: true)
        let w = swapped.hiRes(5, 0, scale: 0.3, reverse: false)
        check(r.vertical == -p.vertical, "reverse must flip the direction")
        check(w.vertical == p.vertical && w.horizontal == 0, "swapped axes must put the first value on vertical")

        // Size: capped, and a bad value is nothing.
        var big = MouseScroll()
        s = big.hiRes(0, 100000, scale: 1.5, reverse: false)
        check(s.vertical == 32 * MouseScroll.hiResPerStep, "a hard flick must stop at the cap")
        var bad = MouseScroll()
        s = bad.hiRes(.nan, .infinity, scale: 0.3, reverse: false)
        check(s.horizontal == 0 && s.vertical == 0, "a value that is not a number must do nothing")
        check(MouseScroll.units(1, scale: 0.3) > 0, "the smallest notch must still move")

        print("PASS: axes, direction, stale values, drift, reverse, swap and the cap")
    }
}
