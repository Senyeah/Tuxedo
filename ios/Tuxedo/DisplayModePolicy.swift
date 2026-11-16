// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics

/// Safe-area insets in points; plain numbers so the policy has no UIKit state and tests run on macOS.
struct DisplayInsets: Equatable {
    var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    static let zero = DisplayInsets()
}

struct GuestMode: Equatable {
    var w: Int
    var h: Int
}

/// Every guest size decision, from inputs only: pixels in, a size out.
enum DisplayModePolicy {
    /// Pixels inside the insets, no larger than cap, rounded down to multiples of 8 (CVT rounds width the same way).
    static func guestMode(pixels: CGSize, insets: DisplayInsets, scale: CGFloat, cap: CGSize) -> (w: Int, h: Int) {
        let w = min(pixels.width - (insets.left + insets.right) * scale, cap.width)
        let h = min(pixels.height - (insets.top + insets.bottom) * scale, cap.height)
        return (max(Int(w) / 8 * 8, 8), max(Int(h) / 8 * 8, 8))
    }

    /// The phone's own mode for a window of `window` points (insets in points, nativeScale pixels per point).
    static func phoneMode(window: CGSize, insets: DisplayInsets, nativeScale: CGFloat) -> GuestMode {
        let pixels = CGSize(width: window.width * nativeScale, height: window.height * nativeScale)
        let m = guestMode(pixels: pixels, insets: insets, scale: nativeScale, cap: pixels)
        return GuestMode(w: m.w, h: m.h)
    }

    /// Upright under a Dynamic Island the picture starts at the island's bottom, this far above the safe area.
    static let islandTrim: CGFloat = 20
    /// On its side, between the safe area and the whole screen: the island and the corners take a little of the picture.
    static let sideTrim: CGFloat = 24

    /// The room the phone's own mode leaves around the picture. The bottom is the window's own inset (the home bar):
    /// SwiftUI's also holds the keyboard and changes while it moves, which changed the guest's size at each show and hide.
    static func phoneRoom(safe: DisplayInsets, windowBottom: CGFloat, landscape: Bool, whole: Bool) -> DisplayInsets {
        if whole && !landscape { return .zero }
        var room = safe
        room.bottom = windowBottom
        if !landscape && safe.top >= 54 { room.top = safe.top - islandTrim } // an island: 59 pt or more; a notch: 44-50
        if landscape && max(safe.left, safe.right) >= 54 {
            room.left = max(safe.left - sideTrim, 0)
            room.right = max(safe.right - sideTrim, 0)
            room.bottom = 0 // the home bar goes over the picture
        }
        return room
    }

    /// The guest's size in points: one guest pixel per `contentsScale` layer pixel, so it is drawn 1:1.
    static func framePoints(_ mode: GuestMode, contentsScale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(mode.w) / contentsScale, height: CGFloat(mode.h) / contentsScale)
    }

    /// The largest mode the guest is given: 4K, also the presenter's SHOW_MAX_PIXELS.
    static let externalCap = CGSize(width: 3840, height: 2160)

    /// An external screen's mode: its pixels inside the overscan insets (normally none), capped at 4K.
    static func externalMode(pixels: CGSize, insets: DisplayInsets = .zero) -> GuestMode {
        let m = guestMode(pixels: pixels, insets: insets, scale: 1, cap: externalCap)
        return GuestMode(w: m.w, h: m.h)
    }

    /// 2 on the phone; elsewhere 1 up to 1440 px high, else 2.
    static func guestScale(shortSide: Int, isPhone: Bool) -> Double {
        isPhone || shortSide > 1440 ? 2 : 1
    }
}

extension DisplayModePolicy {
    /// What pins or sets a Linux guest's size, in order: a fixed choice, a screen that is connected, then the
    /// remembered screen if the machine asked for the external display. Nil: the phone's own mode.
    static func linuxTarget(fixed: GuestMode?, live: CGSize?, remembered: CGSize?, wantsExternal: Bool) -> GuestMode? {
        if let fixed { return fixed }
        if let live { return externalMode(pixels: live) }
        if wantsExternal, let remembered { return externalMode(pixels: remembered) }
        return nil
    }
}

/// Decides which mode to send the guest and when, from timestamped inputs. The caller sets a timer
/// for `pending.at` and calls `take`. A newer input replaces the pending send.
struct ModeFollower {
    static let rotationDelay = 0.3
    static let externalDelay = 1.0

    struct Pending: Equatable {
        var mode: GuestMode
        var at: TimeInterval
    }

    private(set) var pending: Pending?
    private(set) var sent: GuestMode
    private var phone: GuestMode
    private var external: GuestMode?

    /// `initial` is the mode the guest boots with. A boot on an external screen passes the phone's mode too.
    init(initial: GuestMode, phone: GuestMode? = nil, external: GuestMode? = nil) {
        sent = initial
        self.phone = phone ?? initial
        self.external = external
    }

    /// The phone's mode for its current orientation. Recorded while an external screen is up, but sends nothing.
    @discardableResult
    mutating func orientation(_ mode: GuestMode, now: TimeInterval) -> Pending? {
        phone = mode
        guard external == nil else { return pending }
        return schedule(mode, now + Self.rotationDelay)
    }

    /// The external screen's mode, or nil when it goes away (the phone's mode comes back).
    @discardableResult
    mutating func externalDisplay(_ mode: GuestMode?, now: TimeInterval) -> Pending? {
        external = mode
        return schedule(mode ?? phone, now + Self.externalDelay)
    }

    /// The mode to send now, if one is due.
    mutating func take(now: TimeInterval) -> GuestMode? {
        guard let p = pending, now >= p.at else { return nil }
        pending = nil
        sent = p.mode
        return p.mode
    }

    private mutating func schedule(_ mode: GuestMode, _ at: TimeInterval) -> Pending? {
        pending = mode == sent ? nil : Pending(mode: mode, at: at)
        return pending
    }
}

/// What Settings says about an external screen and the guest on it.
struct ExternalScreenFacts: Equatable {
    var mode: CGSize          // the screen's current mode, in pixels
    var native: CGSize        // the panel
    var hz: Int
    var modes: [CGSize]
    var overscan: DisplayInsets
}

enum DisplayReportPolicy {
    static func size(_ s: CGSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }

    static func size(_ m: GuestMode) -> String { "\(m.w) × \(m.h)" }

    /// Whether the guest fills the screen, and what keeps it from doing so.
    static func coverage(guest: GuestMode, facts: ExternalScreenFacts) -> String {
        let all = guest.w == Int(facts.mode.width) && guest.h == Int(facts.mode.height)
        if all { return "Linux fills the whole screen, one guest pixel for each screen pixel." }
        let limit = DisplayModePolicy.externalMode(pixels: facts.mode, insets: facts.overscan)
        if guest == limit {
            let capped = facts.mode.width > DisplayModePolicy.externalCap.width || facts.mode.height > DisplayModePolicy.externalCap.height
            return capped ? "Linux is at its largest size (4K). The screen shows it scaled up."
                          : "Linux is a few pixels smaller than the screen: its size is a multiple of 8."
        }
        let shown = Int((Double(guest.w * guest.h) / max(facts.mode.width * facts.mode.height, 1) * 100).rounded())
        return "Linux uses \(shown) % of the screen's pixels. This machine has a fixed screen size (Details), so the screen scales it."
    }

    static func modeRange(_ modes: [CGSize]) -> String? {
        guard let top = modes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return "\(modes.count) modes, up to \(size(top))"
    }
}
