// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct PhysicalMouseButtonTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func main() {
        // The upstream default is unchanged; compatibility is opt-in.
        var standard = PhysicalMouseButtons(swapsRightAndMiddle: false)
        for button in [Int32(0), 1, 2] {
            check(standard.event(button, pressed: true) == button, "standard press must not change")
            check(standard.event(button, pressed: false) == button, "standard release must not change")
        }
        check(standard.held.isEmpty, "standard mode must release every button")

        var swapped = PhysicalMouseButtons(swapsRightAndMiddle: true)
        check(swapped.event(0, pressed: true) == 0, "left press must remain left")
        check(swapped.held == [0], "left drag must stay held")
        check(swapped.event(0, pressed: false) == 0, "left release must match left press")
        check(swapped.event(1, pressed: true) == 2, "physical right must map to guest middle")
        check(swapped.event(1, pressed: false) == 2, "right release must match swapped press")
        check(swapped.event(2, pressed: true) == 1, "physical middle must map to guest right")
        check(swapped.event(2, pressed: false) == 1, "middle release must match swapped press")
        check(swapped.held.isEmpty, "mapped releases must not stick")

        // Concurrent presses and disconnect cleanup must release their mapped IDs.
        check(swapped.event(1, pressed: true) == 2, "right hold must use middle")
        check(swapped.event(2, pressed: true) == 1, "middle hold must use right")
        check(swapped.event(1, pressed: true) == 2, "duplicate press must remain idempotent")
        check(swapped.releaseAll() == [1, 2], "cleanup must release mapped buttons")
        check(swapped.releaseAll().isEmpty, "cleanup must be idempotent")
        check(swapped.event(-1, pressed: true) == nil, "negative code must be ignored")
        check(swapped.event(5, pressed: true) == nil, "unsupported code must be ignored")
        check(swapped.held.isEmpty, "invalid input must not stick")

        // Back and forward pass through, with or without the swap.
        for var buttons in [standard, swapped] {
            check(buttons.event(3, pressed: true) == 3, "back must stay back")
            check(buttons.event(4, pressed: true) == 4, "forward must stay forward")
            check(buttons.held == [3, 4], "both extra buttons are held")
            check(buttons.event(3, pressed: false) == 3, "back release must match")
            check(buttons.event(4, pressed: false) == 4, "forward release must match")
            check(buttons.held.isEmpty, "extra buttons must not stick")
        }

        // Two devices: AssistiveTouch's pointer and the USB mouse can both report a button.
        var two = PhysicalMouseButtons(swapsRightAndMiddle: false)
        check(two.event(0, pressed: true, device: 1) == 0, "first device press must reach the guest")
        check(two.event(0, pressed: true, device: 2) == nil, "second press of a held button must not repeat")
        check(two.event(0, pressed: false, device: 1) == nil, "guest stays down while another device holds it")
        check(two.held == [0], "the other device still holds left")
        check(two.event(0, pressed: false, device: 2) == 0, "last release must reach the guest")
        check(two.held.isEmpty, "both releases must clear left")

        // A disconnect releases only that device's buttons.
        check(two.event(0, pressed: true, device: 1) == 0, "drag start on device 1")
        check(two.releaseAll(for: 2).isEmpty, "an idle device's disconnect must release nothing")
        check(two.held == [0], "the drag must survive another device's disconnect")
        check(two.event(1, pressed: true, device: 2) == 1, "right on device 2")
        check(two.event(0, pressed: true, device: 2) == nil, "left already down")
        check(two.releaseAll(for: 2) == [1], "disconnect releases right, not the left device 1 holds")
        check(two.held == [0], "left stays down")
        check(two.releaseAll(for: 1) == [0], "device 1 disconnect releases left")
        check(two.releaseAll().isEmpty, "nothing left to release")

        print("PASS: standard mapping, right/middle swap, back and forward, left drag, releases, disconnect cleanup and per-device state")
    }
}
