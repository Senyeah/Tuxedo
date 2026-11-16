import Foundation
import CoreGraphics

@main
struct DisplayModePolicyTests {
    static func mode(_ px: CGSize, _ insets: DisplayInsets = .zero, scale: CGFloat = 3, cap: CGSize = CGSize(width: 3840, height: 2160)) -> String {
        let m = DisplayModePolicy.guestMode(pixels: px, insets: insets, scale: scale, cap: cap)
        return "\(m.w)x\(m.h)"
    }

    static func main() {
        // iPhone 18 Pro panel, safe area inferred: sides 62 pt, home bar 20 pt; portrait top 62 pt, bottom 34 pt.
        let panel = CGSize(width: 2622, height: 1206)
        let land = DisplayInsets(top: 0, left: 62, bottom: 20, right: 62)
        let port = DisplayInsets(top: 62, left: 0, bottom: 34, right: 0)
        precondition(mode(panel, land, cap: panel) == "2248x1144")
        precondition(mode(CGSize(width: 1206, height: 2622), port, cap: CGSize(width: 2622, height: 2622)) == "1200x2328")
        // What Settings says about the guest on an external screen.
        func facts(_ w: Double, _ h: Double) -> ExternalScreenFacts {
            ExternalScreenFacts(mode: CGSize(width: w, height: h), native: CGSize(width: w, height: h), hz: 60, modes: [], overscan: .zero)
        }
        precondition(DisplayReportPolicy.size(CGSize(width: 2560, height: 1440)) == "2560 × 1440")
        precondition(DisplayReportPolicy.coverage(guest: GuestMode(w: 2560, h: 1440), facts: facts(2560, 1440)).hasPrefix("Linux fills the whole screen"))
        precondition(DisplayReportPolicy.coverage(guest: GuestMode(w: 1360, h: 768), facts: facts(1366, 768)).contains("multiple of 8"))
        precondition(DisplayReportPolicy.coverage(guest: GuestMode(w: 3840, h: 2160), facts: facts(5120, 2880)).contains("4K"))
        precondition(DisplayReportPolicy.coverage(guest: GuestMode(w: 1920, h: 1080), facts: facts(2560, 1440)).contains("56 %"))
        precondition(DisplayReportPolicy.modeRange([CGSize(width: 1280, height: 720), CGSize(width: 2560, height: 1440)]) == "2 modes, up to 2560 × 1440")
        precondition(DisplayReportPolicy.modeRange([]) == nil)
        // External sizes inside the cap stay as they are.
        precondition(mode(CGSize(width: 3840, height: 2160)) == "3840x2160")
        precondition(mode(CGSize(width: 2560, height: 1440)) == "2560x1440")
        precondition(mode(CGSize(width: 3440, height: 1440)) == "3440x1440")
        // A TV that is not a multiple of 8 rounds down.
        precondition(mode(CGSize(width: 1366, height: 768)) == "1360x768")
        // Insets that leave an odd size round down after they are taken.
        precondition(mode(CGSize(width: 1000, height: 1000), DisplayInsets(top: 1, left: 3, bottom: 2, right: 4), scale: 1) == "992x992")
        precondition(mode(CGSize(width: 1000, height: 1000), DisplayInsets(top: 0, left: 0, bottom: 0, right: 0), scale: 1) == "1000x1000")
        // A cap smaller than the screen wins, per side, and is rounded too.
        precondition(mode(CGSize(width: 5120, height: 2880), cap: CGSize(width: 3840, height: 2160)) == "3840x2160")
        precondition(mode(CGSize(width: 3840, height: 2160), cap: CGSize(width: 1930, height: 1085)) == "1928x1080")
        // Never zero.
        precondition(mode(CGSize(width: 10, height: 10), DisplayInsets(top: 50, left: 50, bottom: 50, right: 50), scale: 1) == "8x8")

        precondition(DisplayModePolicy.guestScale(shortSide: 1206, isPhone: true) == 2)
        precondition(DisplayModePolicy.guestScale(shortSide: 2160, isPhone: true) == 2)
        precondition(DisplayModePolicy.guestScale(shortSide: 1080, isPhone: false) == 1)
        precondition(DisplayModePolicy.guestScale(shortSide: 1440, isPhone: false) == 1)
        precondition(DisplayModePolicy.guestScale(shortSide: 1441, isPhone: false) == 2)
        precondition(DisplayModePolicy.guestScale(shortSide: 2160, isPhone: false) == 2)

        // The phone's mode from the window in points.
        let up = DisplayModePolicy.phoneMode(window: CGSize(width: 402, height: 874), insets: DisplayInsets(top: 62, left: 0, bottom: 34, right: 0), nativeScale: 3)
        precondition(up == GuestMode(w: 1200, h: 2328))
        let side = DisplayModePolicy.phoneMode(window: CGSize(width: 874, height: 402), insets: DisplayInsets(top: 0, left: 62, bottom: 20, right: 62), nativeScale: 3)
        precondition(side == GuestMode(w: 2248, h: 1144))
        // Drawn 1:1: at most 3 px (1 pt) short of the safe area.
        let frame = DisplayModePolicy.framePoints(side, contentsScale: 3)
        precondition(abs(frame.width - 749.33) < 0.01 && abs(frame.height - 381.33) < 0.01)

        let landscape = GuestMode(w: 2248, h: 1144), portrait = GuestMode(w: 1200, h: 2328)
        let tv = GuestMode(w: 3840, h: 2160)

        // Rotation: sent after 300 ms, not before.
        var f = ModeFollower(initial: landscape)
        precondition(f.orientation(portrait, now: 10) == .init(mode: portrait, at: 10.3))
        precondition(f.take(now: 10.29) == nil)
        precondition(f.take(now: 10.3) == portrait)
        precondition(f.take(now: 11) == nil)

        // Rotate and back within 300 ms: nothing is sent.
        f = ModeFollower(initial: landscape)
        f.orientation(portrait, now: 0)
        precondition(f.orientation(landscape, now: 0.1) == nil)
        precondition(f.take(now: 5) == nil)

        // A second rotation restarts the debounce.
        f = ModeFollower(initial: landscape)
        f.orientation(portrait, now: 0)
        precondition(f.orientation(GuestMode(w: 1208, h: 2328), now: 0.2)?.at == 0.5)
        precondition(f.take(now: 0.4) == nil)
        precondition(f.take(now: 0.5) == GuestMode(w: 1208, h: 2328))

        // External connects: 1 s debounce, then rotation is ignored.
        f = ModeFollower(initial: landscape)
        precondition(f.externalDisplay(tv, now: 0) == .init(mode: tv, at: 1))
        precondition(f.take(now: 1) == tv)
        precondition(f.orientation(portrait, now: 2) == nil)
        precondition(f.take(now: 5) == nil)
        // External goes away: the current orientation's mode (portrait now) returns.
        precondition(f.externalDisplay(nil, now: 6) == .init(mode: portrait, at: 7))
        precondition(f.take(now: 7) == portrait)

        // External connects during a rotation: the pending rotation is replaced.
        f = ModeFollower(initial: landscape)
        f.orientation(portrait, now: 0)
        precondition(f.externalDisplay(tv, now: 0.1) == .init(mode: tv, at: 1.1))
        precondition(f.take(now: 0.5) == nil)
        precondition(f.take(now: 1.1) == tv)
        // Unplugged: back to the rotated phone mode.
        precondition(f.externalDisplay(nil, now: 3) == .init(mode: portrait, at: 4))
        precondition(f.take(now: 4) == portrait)

        // External goes away before its mode was sent: nothing to undo.
        f = ModeFollower(initial: landscape)
        f.externalDisplay(tv, now: 0)
        precondition(f.externalDisplay(nil, now: 0.5) == nil)
        precondition(f.take(now: 5) == nil)

        // External with the same mode the guest already has: nothing is sent.
        f = ModeFollower(initial: tv)
        precondition(f.externalDisplay(tv, now: 0) == nil)

        // Booted on an external screen: it holds the boot mode, rotation waits, unplugging returns the phone mode.
        f = ModeFollower(initial: tv, phone: landscape, external: tv)
        precondition(f.orientation(portrait, now: 0) == nil)
        precondition(f.externalDisplay(tv, now: 1) == nil)
        precondition(f.externalDisplay(nil, now: 2) == .init(mode: portrait, at: 3))

        // External sizes: capped at 4K, rounded down to 8, insets taken off.
        func ext(_ w: CGFloat, _ h: CGFloat) -> GuestMode { DisplayModePolicy.externalMode(pixels: CGSize(width: w, height: h)) }
        precondition(ext(3840, 2160) == tv && ext(2560, 1440) == GuestMode(w: 2560, h: 1440))
        precondition(ext(5120, 2880) == tv && ext(1366, 768) == GuestMode(w: 1360, h: 768))
        precondition(DisplayModePolicy.externalMode(pixels: CGSize(width: 1920, height: 1080),
                                                    insets: DisplayInsets(top: 20, left: 24, bottom: 20, right: 24)) == GuestMode(w: 1872, h: 1040))
        precondition(DisplayModePolicy.guestScale(shortSide: 2160, isPhone: false) == 2 && DisplayModePolicy.guestScale(shortSide: 1440, isPhone: false) == 1)

        // R9: a fixed choice wins, then a live screen, then the remembered one only if asked for.
        let qhd = GuestMode(w: 2560, h: 1440), fhd = GuestMode(w: 1920, h: 1080)
        let live = CGSize(width: 3840, height: 2160), mem = CGSize(width: 1920, height: 1080)
        func target(_ fixed: GuestMode?, _ l: CGSize?, _ r: CGSize?, _ want: Bool) -> GuestMode? {
            DisplayModePolicy.linuxTarget(fixed: fixed, live: l, remembered: r, wantsExternal: want)
        }
        precondition(target(qhd, live, mem, true) == qhd)
        precondition(target(nil, live, mem, false) == tv && target(nil, live, mem, true) == tv)
        precondition(target(nil, nil, mem, true) == fhd && target(nil, nil, mem, false) == nil)
        precondition(target(nil, nil, nil, true) == nil)

        // phoneRoom: the keyboard never changes the guest's size; upright the picture starts at the island's bottom.
        let phone = CGSize(width: 402, height: 874)
        func phoneSize(_ safe: DisplayInsets, windowBottom: CGFloat, landscape: Bool = false, whole: Bool = false) -> String {
            let window = landscape ? CGSize(width: 874, height: 402) : phone
            let m = DisplayModePolicy.phoneMode(window: window, insets: DisplayModePolicy.phoneRoom(safe: safe, windowBottom: windowBottom,
                                                                                                    landscape: landscape, whole: whole),
                                                nativeScale: 3)
            return "\(m.w)x\(m.h)"
        }
        let upright = DisplayInsets(top: 62, left: 0, bottom: 34, right: 0)
        let keyboardHiding = DisplayInsets(top: 62, left: 0, bottom: 56, right: 0)
        let keyboardUp = DisplayInsets(top: 62, left: 0, bottom: 336, right: 0)
        precondition(phoneSize(upright, windowBottom: 34) == "1200x2392") // 874 - 42 - 34 pt
        precondition(phoneSize(keyboardHiding, windowBottom: 34) == "1200x2392")
        precondition(phoneSize(keyboardUp, windowBottom: 34) == "1200x2392")
        precondition(DisplayModePolicy.phoneRoom(safe: upright, windowBottom: 34, landscape: false, whole: false).top == 42)
        let notch = DisplayInsets(top: 47, left: 0, bottom: 34, right: 0)
        precondition(DisplayModePolicy.phoneRoom(safe: notch, windowBottom: 34, landscape: false, whole: false).top == 47)
        precondition(phoneSize(upright, windowBottom: 34, whole: true) == "1200x2616")
        let onSide = DisplayInsets(top: 0, left: 62, bottom: 20, right: 62)
        // On its side: 38 pt at each side and none at the bottom, between the safe area (2248x1144) and the whole screen
        precondition(phoneSize(onSide, windowBottom: 20, landscape: true) == "2392x1200")
        precondition(phoneSize(onSide, windowBottom: 20, landscape: true, whole: true) == "2392x1200")
        let notchSide = DisplayInsets(top: 0, left: 47, bottom: 21, right: 47)
        precondition(DisplayModePolicy.phoneRoom(safe: notchSide, windowBottom: 21, landscape: true, whole: false).left == 47)

        print("test_display_mode_policy: ok")
    }
}
