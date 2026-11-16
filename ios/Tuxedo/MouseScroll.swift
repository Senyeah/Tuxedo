// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A mouse wheel or pad scroll from GameController, as the guest's hi-res wheel units (120 to a notch,
/// up and right positive). GameController's scroll is a dpad: its first value is x, its second is y.
struct MouseScroll {
    static let swapKey = "tux.mouse.swapScrollAxes"
    /// One step of the curve below is this many hi-res units. 4 is the speed the owner picked on a phone.
    static let hiResPerStep: Int32 = 4

    /// For a device that reports the axes the other way round.
    let swapsAxes: Bool
    private var lastX: Float = 0, lastY: Float = 0

    init(swapsAxes: Bool = false) { self.swapsAxes = swapsAxes }

    /// What the handler gets: both values at each call, one of them often the old one.
    mutating func hiRes(_ first: Float, _ second: Float, scale: Float, reverse: Bool) -> (horizontal: Int32, vertical: Int32) {
        let (x, y) = swapsAxes ? (second, first) : (first, second)
        let xChanged = x != lastX, yChanged = y != lastY
        lastX = x
        lastY = y
        // A Magic Keyboard calls twice for one move, each time with a stale axis: only a changed one counts.
        let mostlyX = abs(x) > 2 * abs(y), mostlyY = abs(y) > 2 * abs(x)
        let horizontalRaw = xChanged && !mostlyY ? x : 0
        let verticalRaw = yChanged && !mostlyX ? y : 0
        let way: Int32 = reverse ? -1 : 1
        return (way * Self.units(horizontalRaw, scale: scale) * Self.hiResPerStep,
                way * Self.units(verticalRaw, scale: scale) * Self.hiResPerStep)
    }

    /// A square root, so a hard flick does not jump a page, capped at 32 steps.
    static func units(_ value: Float, scale: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        let steps = Int32(min(32, (22 * scale * abs(value).squareRoot()).rounded()))
        return value < 0 ? -steps : steps
    }
}
