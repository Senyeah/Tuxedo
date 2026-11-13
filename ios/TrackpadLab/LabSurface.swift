import UIKit

/// A copy of the gesture code of Henge's Trackpad.Surface (ios/Henge/Trackpad.swift:90-202),
/// with the same timing, that sends each event to closures and not to the engine. Clicks go
/// through PointerButtons; the look hears each event after the "guest" (the Lab's pointer).
final class LabSurface: UIView {
    enum Event {
        case down(id: Int, CGPoint)
        case move(id: Int, CGPoint, CGPoint)  // now, before
        case up(id: Int)
        case frame(fingers: Int)
    }

    private static let holdTime: TimeInterval = 0.4
    private static let tapTime: TimeInterval = 0.3
    private static let tapDistance: CGFloat = 8

    weak var feedback: PadFeedback?
    let buttons: PointerButtons
    /// The "guest": the Lab's pointer.
    var onEvent: ((Event) -> Void)?
    /// Whether a tap and a hold click now (PadClickRule).
    var tapsClick: () -> Bool = { true }
    var twoFingerTapClicks: () -> Bool = { true }
    /// A three-finger double tap: the tuning sheet.
    var onTuning: (() -> Void)?
    var onReveal: (() -> Void)?

    private struct Finger { var touch: UITouch; var id: Int }
    private var fingers: [Finger] = []
    private var freeIds = Set(1...5)
    private var started = Date()
    private var travelled: CGFloat = 0
    private var mostFingers = 0
    private var firstPoints: [CGPoint] = []
    private var holding = false
    private var holdTimer: Timer?
    private var lastThreeTap: Date?

    init(buttons: PointerButtons) {
        self.buttons = buttons
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        buttons.onGestureUsed = { [weak self] in self?.cancelHold() }
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touches = touches.filter { $0.type != .indirectPointer }
        guard !touches.isEmpty else { return }
        let first = fingers.isEmpty
        if first {
            started = Date()
            travelled = 0
            mostFingers = 0
            firstPoints = []
        }
        for t in touches {
            guard let id = freeIds.min() else { break }
            freeIds.remove(id)
            fingers.append(Finger(touch: t, id: id))
            let p = t.location(in: self)
            if firstPoints.count < 2 { firstPoints.append(p) }
            onEvent?(.down(id: id, p))
            feedback?.padFingerDown(id, at: p, time: t.timestamp, first: first && t == touches.first)
        }
        mostFingers = max(mostFingers, fingers.count)
        buttons.padFingers(fingers.count)
        if fingers.count >= 2 {
            cancelHold()
            if holding { /* a drag becomes a multi-finger gesture */
                holding = false
                if buttons.holdEnd() { feedback?.padHoldEnd() }
            }
        } else if tapsClick() {
            armHold()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var moved = false
        for t in touches where t.type != .indirectPointer {
            guard let f = fingers.first(where: { $0.touch == t }) else { continue }
            let now = t.location(in: self), before = t.previousLocation(in: self)
            travelled += abs(now.x - before.x) + abs(now.y - before.y)
            onEvent?(.move(id: f.id, now, before))
            let all = event?.coalescedTouches(for: t) ?? [t]
            feedback?.padFingerMoved(f.id, samples: all.map { ($0.location(in: self), $0.timestamp) })
            moved = true
        }
        if travelled >= Self.tapDistance && !holding { cancelHold() }
        if moved { onEvent?(.frame(fingers: fingers.count)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: true) }

    /// A cancelled touch (a system gesture, a call) ends a hold, and is never a tap or a gesture.
    private func lift(_ touches: Set<UITouch>, cancelled: Bool = false) {
        var lifted: [Int] = []
        fingers.removeAll { f in
            guard touches.contains(f.touch) else { return false }
            freeIds.insert(f.id)
            lifted.append(f.id)
            return true
        }
        guard !lifted.isEmpty else { return }
        let ts = touches.map(\.timestamp).max() ?? 0
        for id in lifted {
            onEvent?(.up(id: id))
            feedback?.padFingerUp(id, time: ts)
        }
        buttons.padFingers(fingers.count)
        guard fingers.isEmpty else { return }
        cancelHold()
        let quick = Date().timeIntervalSince(started) < Self.tapTime
        let still = travelled < Self.tapDistance
        if holding {
            holding = false
            if buttons.holdEnd() { feedback?.padHoldEnd() }
        } else if quick && still && !cancelled {
            if mostFingers == 1, tapsClick(), buttons.tap(0) {
                feedback?.padClick(0, at: firstPoints[0])
            } else if mostFingers == 2, twoFingerTapClicks(), buttons.tap(1) {
                let a = firstPoints[0], b = firstPoints.count > 1 ? firstPoints[1] : a
                feedback?.padClick(1, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            }
        }
        if mostFingers == 3, still, quick, !cancelled {
            if let last = lastThreeTap, Date().timeIntervalSince(last) < 0.5 {
                lastThreeTap = nil
                onTuning?()
            } else {
                lastThreeTap = Date()
            }
        }
        if mostFingers >= 4, !cancelled, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
            feedback?.padReveal()
            onReveal?()
        }
        if buttons.padLifted() { feedback?.padLatchReleased() }
    }

    /// A finger that stays put presses the left button down, so moving it drags.
    private func armHold() {
        cancelHold()
        let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
            guard self.buttons.holdStart() else { return }
            self.holding = true
            self.feedback?.padHoldStart(at: self.fingers[0].touch.location(in: self))
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}
