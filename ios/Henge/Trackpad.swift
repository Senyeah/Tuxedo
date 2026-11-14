import SwiftUI
import UIKit

/// A surface that works like a laptop trackpad — it is one: the engine presents it on
/// the guest's USB bus as a Magic Trackpad 2, so the guest's multitouch driver (hid-magicmouse)
/// sees the fingers: two scroll, four show the session's hidden controls.
///
/// Clicking depends on the input mode (Settings > Trackpad) and the keyboard (PadClickRule):
///  - Touchscreen: the surface itself clicks. A quick tap is a left click, and touching
///    then holding presses the button down so moving drags.
///  - Volume buttons: the clicks live on the volume keys (VolumeClicks), so a tap does
///    nothing, unless the on-screen keyboard is up.
///  - In each mode a quick two-finger tap is a right click.
/// Clicks go through PointerButtons, so a tap during a held key or volume button cannot drop it.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse, which shares the owners.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")

    /// The on-screen keyboard is up.
    var keyboardUp = false

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        let up = keyboardUp
        view.keyboardUp = { up }
    }

    final class Surface: UIView, UIPointerInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8

        private struct Finger { var touch: UITouch; var id: Int32 }

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var mostFingers = 0
        private var firstPoints: [CGPoint] = []
        private var touchesLogged = 0

        private var holding = false
        private var holdTimer: Timer?

        /// The pad's look and haptics, told after the guest. nil: the surface plays its own clicks.
        weak var feedback: PadFeedback?
        let buttons: PointerButtons
        var keyboardUp: () -> Bool = { false }
        private lazy var haptics = PadHaptics(tuning: PadTuning().haptics)
        private var tapsClick: Bool { VolumeClicks.tapsClick(keyboardUp: keyboardUp()) }
        private var twoFingerTapClicks: Bool { PadClickRule.twoFingerTapClicks(VolumeClicks.padMode, keyboardUp: keyboardUp()) }

        init(buttons: PointerButtons = .guest) {
            self.buttons = buttons
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        }

        /// The pad's surface: its keys use up this surface's gesture.
        func attach(_ pad: PadFeedback) {
            feedback = pad
            buttons.onGestureUsed = { [weak self] in self?.cancelHold() }
        }

        private var hoversLogged = 0, typesLogged = 0
        static var lastHover = CGPoint(x: -1, y: -1)
        @objc private func hovered(_ g: UIHoverGestureRecognizer) {
            Self.lastHover = g.location(in: self)
            guard hoversLogged < 40 else { return }
            hoversLogged += 1
            let p = g.location(in: self)
            HengeLog.log("input", "hover \(g.state.rawValue) at \(Int(p.x)),\(Int(p.y))")
        }

        /// Over the guest there is only the guest's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Where the finger is on the pad's sensor, in its units.
        private func sensor(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches where typesLogged < 200 {
                typesLogged += 1
                HengeLog.log("input", "touch began: type \(t.type.rawValue), buttons \(event?.buttonMask.rawValue ?? 0)")
            }
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            let first = fingers.isEmpty
            if first {
                started = Date()
                travelled = 0
                mostFingers = 0
                firstPoints = []
                if feedback == nil {
                    haptics.level = TrackpadFeel.level
                    haptics.prepare()
                }
            }
            var downs: [(Int32, CGPoint, TimeInterval, Bool)] = []
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y, Self.ms(t.timestamp))
                let p = t.location(in: self)
                if firstPoints.count < 2 { firstPoints.append(p) }
                downs.append((id, p, t.timestamp, first && t == touches.first))
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            buttons.padFingers(fingers.count)
            for d in downs { feedback?.padFingerDown(Int(d.0), at: d.1, time: d.2, first: d.3) }
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a drag becomes a multi-finger gesture */
                    holding = false
                    if buttons.holdEnd() { holdEnded() }
                }
            } else if tapsClick {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            var moved: [(Int32, UITouch)] = []
            let ts = Self.ms(event?.timestamp ?? touches.first?.timestamp ?? 0)
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                let (x, y) = sensor(t)
                henge_vm_touch(fingers[i].id, 1, x, y, ts)
                moved.append((fingers[i].id, t))
            }
            /* Moving means pointing or a gesture, not a tap or a press-to-drag. */
            if travelled >= Self.tapDistance && !holding { cancelHold() }
            /* One frame with every finger that moved, so the guest sees a gesture's
               fingers move together rather than one at a time. */
            guard !moved.isEmpty else { return }
            henge_vm_touch_frame(ts)
            guard let feedback else { return }
            for (id, t) in moved { // the coalesced samples draw a smoother trail; the guest keeps one each
                let all = event?.coalescedTouches(for: t) ?? [t]
                feedback.padFingerMoved(Int(id), samples: all.map { ($0.location(in: self), $0.timestamp) })
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: true) }

        /// A cancelled touch (a system gesture, a call) ends a hold, and is never a tap or a gesture.
        private func lift(_ touches: Set<UITouch>, cancelled: Bool = false) {
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger.id)
                return true
            }
            guard !lifted.isEmpty else { return }
            let time = touches.map(\.timestamp).max() ?? 0
            let ts = Self.ms(time)
            for id in lifted { henge_vm_touch(id, 2, 0, 0, ts) }
            for id in lifted { feedback?.padFingerUp(Int(id), time: time) }
            buttons.padFingers(fingers.count)
            guard fingers.isEmpty else { return } /* fingers still down: the gesture goes on */
            /* The whole gesture is over. */
            cancelHold()
            let quick = Date().timeIntervalSince(started) < Self.tapTime
            let still = travelled < Self.tapDistance
            if holding {
                holding = false
                if buttons.holdEnd() { holdEnded() } /* let go of the drag */
            } else if quick && still && !cancelled {
                if mostFingers == 1, tapsClick, buttons.tap(0) {
                    clicked(0, at: firstPoints[0])
                } else if mostFingers == 2, twoFingerTapClicks, buttons.tap(1) {
                    let a = firstPoints[0], b = firstPoints.count > 1 ? firstPoints[1] : a
                    clicked(1, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                }
            }
            if mostFingers >= 4, !cancelled, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
                feedback?.padReveal()
            }
            if buttons.padLifted() { feedback?.padLatchReleased() }
            StickyKeys.shared.releaseAll()
        }

        private func clicked(_ button: Int, at p: CGPoint) {
            if let feedback { feedback.padClick(button, at: p) } else { haptics.fire(button == 0 ? .tap : .rightTap) }
        }

        private func holdEnded() {
            if let feedback { feedback.padHoldEnd() } else { haptics.fire(.holdEnd) }
        }

        /// A finger that stays put presses the left button down, so moving it drags.
        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                guard self.buttons.holdStart() else { return } // a key is down, or a late timer
                self.holding = true
                if let feedback = self.feedback {
                    feedback.padHoldStart(at: self.fingers[0].touch.location(in: self))
                } else {
                    self.haptics.fire(.holdStart)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }

        /// Forgets every finger, after the session lifted them in the guest. The pad's look lets go of them too.
        func reset() {
            cancelHold()
            let time = ProcessInfo.processInfo.systemUptime // the touches' clock
            for f in fingers { feedback?.padFingerUp(Int(f.id), time: time) }
            if !fingers.isEmpty { buttons.padLifted() }
            fingers = []
            freeIds = Set(1...5)
            holding = false
            travelled = 0
            mostFingers = 0
            firstPoints = []
        }
    }
}

extension PointerButtons {
    /// The guest's mouse buttons: the pad, its keys, the volume buttons and a mouse share the owners.
    static let guest = PointerButtons { b, down in
        henge_vm_mouse_button(Int32(b), down ? 1 : 0)
        if !down { StickyKeys.shared.releaseAll() } // a tapped ⌘, ⌥ or ⌃ is for one click
    }
}

/// The trackpad's haptic settings (Settings > Trackpad), for every pad.
enum TrackpadFeel {
    static let hapticsKey = "henge.trackpad.haptics"
    static let motionKey = "henge.trackpad.motionFeel"

    static var level: PadHaptics.Level {
        PadHaptics.Level(rawValue: UserDefaults.standard.string(forKey: hapticsKey) ?? "") ?? .all
    }
    /// PadTuning.Motion.style: "texture", "ticks" or "none".
    static var motion: String { UserDefaults.standard.string(forKey: motionKey) ?? PadTuning.Motion().style }

    /// Tuxedo's tuning: the Lab's approved defaults with the motion feel from Settings.
    static func tuning(motion: String, page: String? = nil) -> PadTuning {
        var t = PadTuning()
        t.motion.style = motion
        if let page { t.light.page = page }
        return t
    }
}

/// The session's pad: one surface for each PadView, and where the pad puts the tool pill.
final class PadSession: ObservableObject {
    private(set) lazy var surface = Trackpad.Surface()
    @Published private(set) var pill = CGPoint(x: -100, y: -100)
    @Published private(set) var pillOpacity = 1.0
    private(set) weak var host: PadHostView?
    /// Counts the first sessions, which show the first-use stroke.
    private let ghostKey: String?
    private var ghostPlayed = false
    /// Nothing covers the pad (the Face ID cover, the app switcher): the stroke can be seen.
    var visible = false { didSet { if visible != oldValue { ghostIfDue() } } }

    init(ghostKey: String? = nil) { self.ghostKey = ghostKey }

    func attach(_ host: PadHostView) {
        self.host = host
        ghostIfDue()
        surface.attach(host)
        surface.keyboardUp = { [weak host] in host?.keyboardUp ?? false }
        host.onLayout = { [weak self] l in
            let p = CGPoint(x: l.pillX, y: l.pillY)
            if let self, p != self.pill { self.pill = p }
        }
        host.onPillOpacity = { [weak self] o in self?.pillOpacity = o }
        host.haptics.prepare()
    }

    /// Once a session, and counted only when it plays: the view is made again at each console switch.
    private func ghostIfDue() {
        guard visible, !ghostPlayed, let ghostKey, let host,
              UserDefaults.standard.integer(forKey: ghostKey) < Int(host.tuning.ghost.sessions) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak host] in // after the first layout
            guard let self, let host, host === self.host, self.visible, !self.ghostPlayed else { return }
            self.ghostPlayed = true
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: ghostKey) + 1, forKey: ghostKey)
            host.playGhost()
        }
    }
}

/// The session's tools on the pad, where the pad's layout puts them.
struct PadToolPill<Content: View>: View {
    @ObservedObject var pad: PadSession
    let tuning: PadTuning
    @ViewBuilder var content: Content

    var body: some View {
        PadPill(tuning: tuning) { content }
            .fixedSize()
            .position(pad.pill)
            .opacity(pad.pillOpacity)
            .allowsHitTesting(pad.pillOpacity > 0.05)
    }
}
