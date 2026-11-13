import QuartzCore
import UIKit

/// The fixed input script for the recorded frames and the videos. It drives the pad through
/// the same calls as LabSurface: the feedback, PointerButtons and the keys.
///
/// Launch settings: -padDemo 1 plays it in real time (-padDemoSpeed 0.25 for quarter speed);
/// -padDemoAt T steps the model with a fixed 1/120 s to T and freezes there, for a still;
/// -padHapticCount 1 runs it twice, fast, and writes each haptic to Documents/pad-haptics.json.
final class LabDemo {
    static let step = 1.0 / 120
    static let duration = 16.5

    private weak var model: LabModel?
    private weak var host: PadHostView?
    private var actions: [(Double, () -> Void)] = []
    private var next = 0
    private var paths: [Path] = []
    private var start: CFTimeInterval = 0
    private var speed = 1.0
    private var haptics: [[String: Any]] = []
    private var offset = 0.0

    /// A finger along a path, in the pad surface's unit square, from t0 to t1.
    private struct Path {
        var id: Int
        var t0, t1: Double
        var at: (Double) -> (Double, Double)
        var emitted = -1.0
        var down = false
        var done = false
    }

    init(model: LabModel, host: PadHostView) {
        self.model = model
        self.host = host
        script()
    }

    // MARK: The script

    private func script() {
        // A finger rests, then draws a slow arc.
        finger(1, 0.6, 2.4) { t in
            if t < 1.2 { return (0.30, 0.55) }
            let u = (t - 1.2) / 1.2
            let a = Double.pi * (1.05 - 0.9 * u)
            return (0.5 + 0.22 * cos(a) - 0.02, 0.55 - 0.28 * sin(a))
        }
        // A fast flick.
        finger(1, 3.0, 3.22) { t in
            let u = (t - 3.0) / 0.22
            return (0.15 + 0.7 * u, 0.70 - 0.25 * u)
        }
        // A two-finger scroll.
        for (id, x) in [(1, 0.42), (2, 0.58)] {
            finger(id, 3.8, 4.8) { t in (x, 0.75 - 0.45 * (t - 3.8)) }
        }
        tap(5.4, at: (0.5, 0.45), button: 0)
        tap(6.2, at: (0.5, 0.45), button: 1)
        key(0, 7.0, 7.5)
        key(1, 7.9, 8.4)
        // A touch-and-hold drag.
        finger(1, 9.0, 10.8) { t in
            let u = min(max((t - 9.45) / 1.2, 0), 1)
            let e = u * u * (3 - 2 * u)
            return (0.25 + 0.5 * e, 0.6 - 0.25 * e + 0.08 * sin(e * .pi))
        }
        at(9.4) { [weak self] in
            guard let self, let host = self.host else { return }
            if host.buttons.holdStart() { host.padHoldStart(at: .zero) }
        }
        at(10.8 + Self.step / 2) { [weak self] in
            guard let host = self?.host else { return }
            if host.buttons.holdEnd() { host.padHoldEnd() }
        }
        // A drag with the left key held.
        key(0, 11.4, 12.6)
        finger(1, 11.6, 12.4) { t in
            let u = (t - 11.6) / 0.8
            return (0.7 - 0.4 * u, 0.35 + 0.2 * u)
        }
        at(13.0) { [weak self] in self?.model?.keyboard.show() }
        tap(13.8, at: (0.5, 0.25), button: 0)
        tap(14.4, at: (0.5, 0.25), button: 1)
        at(15.2) { [weak self] in self?.model?.keyboard.hide() }
        actions.sort { $0.0 < $1.0 }
    }

    private func at(_ t: Double, _ f: @escaping () -> Void) { actions.append((t, f)) }

    private func finger(_ id: Int, _ t0: Double, _ t1: Double, _ path: @escaping (Double) -> (Double, Double)) {
        paths.append(Path(id: id, t0: t0, t1: t1, at: path))
    }

    private func tap(_ t: Double, at p: (Double, Double), button: Int) {
        if button == 0 {
            finger(1, t, t + 0.08) { _ in p }
        } else {
            finger(1, t, t + 0.08) { _ in (p.0 - 0.06, p.1) }
            finger(2, t, t + 0.08) { _ in (p.0 + 0.06, p.1) }
        }
        at(t + 0.08 + Self.step / 2) { [weak self] in
            guard let host = self?.host, let pt = self?.point(p) else { return }
            if host.buttons.tap(button) { host.padClick(button, at: pt) }
        }
    }

    private func key(_ b: Int, _ t0: Double, _ t1: Double) {
        at(t0) { [weak self] in self?.host?.pressKey(b, true) }
        at(t1) { [weak self] in self?.host?.pressKey(b, false) }
    }

    /// The unit square of the pad above the keys, in the touch view's points.
    private func point(_ p: (Double, Double)) -> CGPoint {
        guard let l = host?.layout else { return .zero }
        return CGPoint(x: p.0 * l.pad.w, y: p.1 * (l.grooveY - l.pad.y))
    }

    // MARK: Feeding

    private func feed(to t: Double) {
        guard let host, let model else { return }
        for i in paths.indices where !paths[i].done && t >= paths[i].t0 {
            var p = paths[i]
            var s = p.emitted < 0 ? p.t0 : p.emitted + Self.step
            while s <= min(t, p.t1) + 1e-9 {
                let pt = point(p.at(s))
                if !p.down {
                    p.down = true
                    let first = host.buttons.padFingers == 0
                    host.buttons.padFingers(host.buttons.padFingers + 1)
                    host.padFingerDown(p.id, at: pt, time: s + offset, first: first)
                } else {
                    let before = point(p.at(max(s - Self.step, p.t0)))
                    model.surfaceEvent(.move(id: p.id, pt, before))
                    host.padFingerMoved(p.id, samples: [(pt, s + offset)])
                }
                p.emitted = s
                s += Self.step
            }
            if t >= p.t1 {
                p.done = true
                host.padFingerUp(p.id, time: p.t1 + offset)
                host.buttons.padFingers(max(host.buttons.padFingers - 1, 0))
                if host.buttons.padFingers == 0, host.buttons.padLifted() { host.padLatchReleased() }
            }
            paths[i] = p
        }
        while next < actions.count, actions[next].0 <= t {
            actions[next].1()
            next += 1
        }
    }

    private func reset(offset o: Double) {
        offset = o
        next = 0
        for i in paths.indices { paths[i].emitted = -1; paths[i].down = false; paths[i].done = false }
    }

    // MARK: Running

    func begin() {
        guard let host else { return }
        let d = UserDefaults.standard
        host.clock = { [weak self] in self?.now ?? CACurrentMediaTime() }
        host.haptics.onFire = { [weak self] e, style, i in
            guard let self else { return }
            self.haptics.append(["t": (self.now * 1000).rounded() / 1000, "event": e.rawValue, "style": style, "intensity": i])
        }
        if d.bool(forKey: "padHapticCount") {
            for loop in 0..<2 {
                reset(offset: Double(loop) * Self.duration)
                fastForward(to: Self.duration, base: Double(loop) * Self.duration, keyboard: false)
            }
            write("pad-haptics.json", ["seconds": 2 * Self.duration, "haptics": haptics])
            return
        }
        if d.object(forKey: "padDemoAt") != nil {
            let target = d.double(forKey: "padDemoAt")
            fastForward(to: target, base: 0, keyboard: true)
            host.surface.frozen = true
            host.surface.render(at: target)
            if target >= 13.0 && target < 15.2 { model?.keyboard.show() }
            return
        }
        speed = d.object(forKey: "padDemoSpeed") != nil ? d.double(forKey: "padDemoSpeed") : 1
        start = CACurrentMediaTime() + 0.5
        host.surface.resetStats()
        host.surface.clockOverride = { [weak self] in self?.now ?? 0 }
        host.beforeStep = { [weak self] t in
            guard let self else { return false }
            self.feed(to: t)
            if t > Self.duration { self.finish(); return false }
            return true
        }
        host.surface.setNeedsFrame()
    }

    private var fastNow = -1.0
    var now: Double { fastNow >= 0 ? fastNow : max(0, (CACurrentMediaTime() - start) * speed) }

    private func fastForward(to target: Double, base: Double, keyboard: Bool) {
        guard let host else { return }
        var t = 0.0
        while t <= target + 1e-9 {
            fastNow = base + t
            feed(to: t)
            _ = host.padWillStep(host.surface, at: base + t)
            host.surface.field.step(to: base + t)
            t += Self.step
        }
        fastNow = base + target
    }

    private func finish() {
        guard let host, host.beforeStep != nil else { return }
        host.beforeStep = nil
        host.surface.clockOverride = nil
        let s = host.surface.stats
        write("pad-stats.json", [
            "frames": s.frames, "restFrames": s.restFrames,
            "cpuMedianMs": PadFrameStats.median(s.cpu), "cpuP95Ms": PadFrameStats.p95(s.cpu),
            "gpuMedianMs": PadFrameStats.median(s.gpu), "gpuP95Ms": PadFrameStats.p95(s.gpu),
            "touchMedianUs": PadFrameStats.median(s.touch), "touchP95Us": PadFrameStats.p95(s.touch),
            "gpuSamples": s.gpu.count, "cpuSamples": s.cpu.count,
            "grid": [host.surface.field.cols, host.surface.field.rows],
            "drawable": [Double(host.surface.bounds.width * host.surface.contentScaleFactor), Double(host.surface.bounds.height * host.surface.contentScaleFactor)],
        ])
        write("pad-haptics-realtime.json", ["haptics": haptics])
    }

    private func write(_ name: String, _ obj: Any) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }
}
