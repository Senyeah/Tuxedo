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
