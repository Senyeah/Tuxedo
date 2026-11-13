import SwiftUI
import UIKit

/// What a trackpad surface tells the look, after it has told the guest. Points are in the
/// surface's own coordinates. With no delegate a surface behaves as before.
protocol PadFeedback: AnyObject {
    func padFingerDown(_ id: Int, at p: CGPoint, time: TimeInterval, first: Bool)
    func padFingerMoved(_ id: Int, samples: [(CGPoint, TimeInterval)])
    func padFingerUp(_ id: Int, time: TimeInterval)
    func padClick(_ button: Int, at p: CGPoint)
    func padHoldStart(at p: CGPoint)
    func padHoldEnd()
    /// A latch let go at the last lift (the keyboard covered a held left key).
    func padLatchReleased()
    func padReveal()
}

/// Accessibility settings that the Lab can force, for the recorded frames. nil follows the system.
struct PadAccessibility: Equatable {
    var reduceMotion: Bool?
    var increaseContrast: Bool?
    var buttonShapes: Bool?
}

/// The surface, the touch view and the keys together, laid out by PadLayout.
final class PadHostView: UIView, PadSurfaceHost, PadFeedback {
    let surface: PadSurfaceView
    let touchView: UIView
    let keys: PadButtons
    let haptics: PadHaptics
    let motion: PadMotionHaptics
    let buttons: PointerButtons
    private(set) var keyboard: PadKeyboard!
    private(set) var layout = PadLayout()
    /// After each layout, for what sits on the pad (the pill).
    var onLayout: ((PadLayout) -> Void)?
    /// The pill's opacity: the keyboard's rule, dimmed while a finger is on the pad.
    var onPillOpacity: ((Double) -> Void)?
    private(set) var pillOpacity = 1.0
    /// Before each frame, for a script that drives the pad. Return true to keep frames coming.
    var beforeStep: ((CFTimeInterval) -> Bool)?
    /// The haptics' clock, which a script replaces with its own.
    var clock: () -> CFTimeInterval = CACurrentMediaTime

    var tuning: PadTuning {
        didSet {
            surface.tuning = tuning
            keys.tuning = tuning
            haptics.tuning = tuning.haptics
            motion.tuning = tuning.motion
            setNeedsLayout()
        }
    }
    var forced = PadAccessibility() { didSet { if forced != oldValue { accessibilityChanged() } } }
    /// The pad's VoiceOver value: where the guest is.
    var padValue = "Linux is on the external display" { didSet { updateAccessibility() } }

    private var keyTarget = [false, false]
    private var keyLevel = [0.0, 0.0]
    private var flashUntil = [0.0, 0.0]
    private var bloomAt: [SIMD2<Double>] = [.zero, .zero]
    private var padFingers = Set<Int>()
    private var pillDim = 0.0
    private var lastStep: CFTimeInterval = 0

    init(touchView: UIView, buttons: PointerButtons, tuning: PadTuning = PadTuning()) {
        self.tuning = tuning
        self.touchView = touchView
        self.buttons = buttons
        surface = PadSurfaceView(tuning: tuning)
        keys = PadButtons(tuning: tuning)
        haptics = PadHaptics(tuning: tuning.haptics)
        motion = PadMotionHaptics(tuning: tuning.motion)
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(surface)
        addSubview(touchView)
        addSubview(keys)
        surface.host = self
        keyboard = PadKeyboard(host: self)
        keyboard.onChange = { [weak self] up in self?.keyboardChanged(up) }
        keys.onKey = { [weak self] b, down in self?.pressKey(b, down) }
        keys.onHold = { [weak self] held in
            guard let self else { return }
            if held { self.buttons.press(0, by: .accessibility) } else { self.buttons.release(0, by: .accessibility) }
            self.surface.setNeedsFrame()
        }
        buttons.onChange = { [weak self] _, _ in self?.surface.setNeedsFrame() }
        let nc = NotificationCenter.default
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                     UIAccessibility.buttonShapesEnabledStatusDidChangeNotification] {
            nc.addObserver(self, selector: #selector(accessibilityChanged), name: name, object: nil)
        }
        nc.addObserver(self, selector: #selector(sceneActive), name: UIScene.didActivateNotification, object: nil)
        nc.addObserver(self, selector: #selector(sceneInactive), name: UIScene.willDeactivateNotification, object: nil)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    // MARK: Settings

    var reduceMotion: Bool { forced.reduceMotion ?? UIAccessibility.isReduceMotionEnabled }
    var increaseContrast: Bool { forced.increaseContrast ?? (traitCollection.accessibilityContrast == .high) }
    var labels: Bool {
        forced.buttonShapes ?? (UIAccessibility.buttonShapesEnabled || traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
    }
    /// The keyboard hides the keys; a tap then clicks in each input mode.
    var keyboardUp: Bool { layout.progress > 0 }

    @objc private func accessibilityChanged() {
        keys.labels = labels
        keys.increaseContrast = increaseContrast
        surface.increaseContrast = increaseContrast
        surface.field.reduceMotion = reduceMotion
        setNeedsLayout()
        surface.setNeedsFrame()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { haptics.prepare(); if haptics.level == .all { motion.prepare() } }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        accessibilityChanged()
    }

    @objc private func sceneActive() { surface.setNeedsFrame() }
    @objc private func sceneInactive() { surface.stop(); motion.cancel(); padFingers.removeAll() }

    private func updateAccessibility() {
        touchView.isAccessibilityElement = true
        touchView.accessibilityLabel = "Trackpad"
        touchView.accessibilityValue = padValue
        touchView.accessibilityTraits = .allowsDirectInteraction
        touchView.accessibilityHint = keyboardUp ? "Tap with two fingers for a right click" : nil
    }

    // MARK: Layout

    /// The screen's corner radius. iOS gives it no public name; without it, the usual values.
    private var deviceCorner: Double {
        let s = window?.screen ?? UIScreen.main
        let key = "_displayCornerRadius"
        if s.responds(to: NSSelectorFromString(key)), let r = s.value(forKey: key) as? CGFloat, r > 0 { return Double(r) }
        return safeAreaInsets.bottom > 0 ? (traitCollection.userInterfaceIdiom == .pad ? 18 : 55) : 0
    }

    private func makeLayout() -> PadLayout {
        let i = PadLayout.Input(width: Double(bounds.width), height: Double(bounds.height),
                                safeTop: Double(safeAreaInsets.top), safeLeft: Double(safeAreaInsets.left),
                                safeBottom: Double(safeAreaInsets.bottom), safeRight: Double(safeAreaInsets.right),
                                deviceCorner: deviceCorner, labels: labels)
        return PadLayout.make(i, keyboard: keyboard.state, tuning: tuning, reduceMotion: reduceMotion)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        keys.frame = bounds
        apply(makeLayout())
        keys.labels = labels
        keys.increaseContrast = increaseContrast
        surface.increaseContrast = increaseContrast
        surface.field.reduceMotion = reduceMotion
    }

    private func apply(_ l: PadLayout) {
        let wasUp = keyboardUp
        layout = l
        let r = CGRect(x: l.pad.x, y: l.pad.y, width: l.pad.w, height: l.pad.h)
        if touchView.frame != r { touchView.frame = r }
        keys.apply(l)
        surface.geometry = l
        if wasUp != keyboardUp { updateAccessibility() }
        onLayout?(l)
        updatePill()
    }

    private func updatePill() {
        let o = layout.pillOpacity * (1 - (1 - tuning.pill.touchDim) * pillDim)
        guard o != pillOpacity else { return }
        pillOpacity = o
        onPillOpacity?(o)
    }

    // MARK: Frames

    func padWillStep(_ s: PadSurfaceView, at now: CFTimeInterval) -> Bool {
        let scripted = beforeStep?(now) ?? false
        let dt = lastStep > 0 ? min(max(now - lastStep, 0), 0.1) : 0
        lastStep = now
        let moving = keyboard.moving
        if moving { apply(makeLayout()) }
        s.syncWithCoreAnimation = moving
        var animating = false
        let k = tuning.keys
        let touchNow = clock() // the clock that the touches arrive by, not the frame's target time
        motion.step(now: touchNow)
        for b in 0..<2 {
            let target = keyTarget[b] || touchNow < flashUntil[b] ? 1.0 : 0.0
            let time = target > 0 ? k.attack : k.release
            let step = dt / max(time, 1e-3)
            keyLevel[b] = keyLevel[b] < target ? min(target, keyLevel[b] + step) : max(target, keyLevel[b] - step)
            if keyLevel[b] != target { animating = true }
        }
        let dimTarget = padFingers.isEmpty ? 0.0 : 1.0
        if pillDim != dimTarget {
            let p = tuning.pill
            let step = dt / max(dimTarget > pillDim ? p.dimAttack : p.dimRelease, 1e-3)
            pillDim = pillDim < dimTarget ? min(dimTarget, pillDim + step) : max(dimTarget, pillDim - step)
            updatePill()
            animating = true
        }
        // Attack eases out; the release eases out too, so the key settles.
        func ease(_ x: Double, up: Bool) -> Double { up ? 1 - pow(1 - x, 2) : pow(x, 2) }
        let rising = [keyTarget[0] || touchNow < flashUntil[0], keyTarget[1] || touchNow < flashUntil[1]]
        let shown = (ease(keyLevel[0], up: rising[0]), ease(keyLevel[1], up: rising[1]))
        s.keyPress = shown
        s.keyBloom = (bloomAt[0], bloomAt[1])
        keys.setPress(0, shown.0)
        keys.setPress(1, shown.1)
        s.field.dragging = buttons.isDown(0) && !buttons.holds(0, .tap)
        s.field.reduceMotion = reduceMotion
        return scripted || moving || animating || rising[0] || rising[1] || motion.active
    }

    /// A key's press or release, from its view or from a script.
    func pressKey(_ b: Int, _ down: Bool) {
        haptics.prepare()
        if down { buttons.keyDown(b) } else { buttons.keyUp(b) }
        if down { bloomAt[b] = keys.touchPoint(b) * tuning.keys.bloomFollow }
        haptics.fire(b == 0 ? (down ? .leftKeyDown : .leftKeyUp) : (down ? .rightKeyDown : .rightKeyUp), now: clock())
        keyTarget[b] = down
        surface.setNeedsFrame()
    }

    private func keyboardChanged(_ up: Bool) {
        if up, keyboard.fullCover > tuning.keyboard.hideAbove {
            if buttons.keyboardRaised() { haptics.fire(.holdEnd, now: clock()) }
            keyTarget = [false, false]
        }
        surface.setNeedsFrame()
    }

    /// The first-use stroke, once, after `delay`.
    func playGhost(after delay: Double? = nil) {
        let l = layout
        surface.field.startGhost(cx: l.pad.midX, cy: l.pad.y + (l.grooveY - l.pad.y) * 0.45,
                                 at: clock() + (delay ?? tuning.ghost.delay))
        surface.setNeedsFrame()
    }

    // MARK: PadFeedback

    private func host(_ p: CGPoint) -> (Double, Double) {
        (Double(p.x + touchView.frame.minX), Double(p.y + touchView.frame.minY))
    }

    func padFingerDown(_ id: Int, at p: CGPoint, time: TimeInterval, first: Bool) {
        let (x, y) = host(p)
        padFingers.insert(id)
        surface.add(.down(id: id, x: x, y: y, t: time))
        if first {
            haptics.prepare()
            haptics.fire(.touchDown, now: clock())
        }
        if haptics.level == .all { motion.down(id, x: x, y: y, t: time, now: clock()) }
    }

    func padFingerMoved(_ id: Int, samples: [(CGPoint, TimeInterval)]) {
        for (p, t) in samples {
            let (x, y) = host(p)
            surface.add(.move(id: id, x: x, y: y, t: t))
            motion.moved(id, x: x, y: y, t: t, now: clock())
        }
    }

    func padFingerUp(_ id: Int, time: TimeInterval) {
        padFingers.remove(id)
        surface.add(.up(id: id, t: time))
        motion.up(id)
    }

    func padClick(_ button: Int, at p: CGPoint) {
        let (x, y) = host(p)
        surface.add(.click(x: x, y: y))
        haptics.fire(button == 0 ? .tap : .rightTap, now: clock())
        if tuning.keys.tapFlash > 0, button < 2 { // looks as its key's press, from the centre
            if !keyTarget[button] { bloomAt[button] = .zero }
            flashUntil[button] = clock() + tuning.keys.tapFlash
        }
        surface.setNeedsFrame()
    }

    func padHoldStart(at p: CGPoint) {
        haptics.fire(.holdStart, now: clock())
        surface.setNeedsFrame()
    }

    func padHoldEnd() {
        haptics.fire(.holdEnd, now: clock())
        surface.setNeedsFrame()
    }

    func padLatchReleased() { haptics.fire(.holdEnd, now: clock()) }
    func padReveal() { haptics.fire(.reveal, now: clock()) }
}

/// The pad for SwiftUI. It takes the touch view (the Lab's copy of the surface, or Henge's
/// Trackpad.Surface) and the buttons the surface clicks through.
struct PadView: UIViewRepresentable {
    let touchView: UIView
    let buttons: PointerButtons
    var tuning = PadTuning()
    var forced = PadAccessibility()
    var value = "Linux is on the external display"
    var hapticLevel: PadHaptics.Level = .all
    var made: ((PadHostView) -> Void)?

    func makeUIView(context: Context) -> PadHostView {
        let v = PadHostView(touchView: touchView, buttons: buttons, tuning: tuning)
        made?(v)
        return v
    }

    func updateUIView(_ v: PadHostView, context: Context) {
        if v.tuning != tuning { v.tuning = tuning }
        v.forced = forced
        v.padValue = value
        if v.haptics.level != hapticLevel {
            v.haptics.level = hapticLevel
            v.motion.cancel()
        }
    }
}
