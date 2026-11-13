import Foundation

/// The pad's energy grid, one cell for each dot. `core` is fast and white, `tail` is slow and
/// carries the trail, `grab` is how much of a drag laid that tail down (the only blue).
/// Pure Swift: touches go in as samples, the renderer takes the cells out.
struct PadField {
    enum Sample {
        case down(id: Int, x: Double, y: Double, t: Double)
        case move(id: Int, x: Double, y: Double, t: Double)
        case up(id: Int, t: Double)
        case click(x: Double, y: Double)
    }

    var tuning: PadTuning
    var reduceMotion = false
    /// The left button is down: new trail is a drag's.
    var dragging = false

    private(set) var cols = 0, rows = 0
    /// The first dot's centre, in the host view's points.
    private(set) var originX = 0.0, originY = 0.0
    private(set) var core: [Float] = [], tail: [Float] = [], grab: [Float] = []
    private(set) var time = 0.0
    private var lastDt = 0.0
    private(set) var smoothSpeed = 0.0
    private(set) var grabLevel = 0.0
    /// The brightest cell after the last step.
    private(set) var brightest: Float = 0

    private struct Finger {
        var x, y, t: Double
        var head = 0.0       // smoothed speed for the stamp's width and peak
        var carry = 0.0      // distance since the last stamp
        var moved = 0.0      // distance in this frame
        var halo = 0.0
        var down = true
    }
    private struct Ripple { var x, y, age: Double }
    private struct Ghost { var cx, cy, start: Double; var lastX = 0.0, lastY = 0.0; var began = false }

    private var fingers: [Int: Finger] = [:]
    private var ripples: [Ripple] = []
    private var flashes: [Ripple] = []
    private var ghost: Ghost?
    private var pending: [Sample] = []
    private var kx: [Float] = [], ky: [Float] = []
    private static let ghostId = -1

    init(tuning: PadTuning = PadTuning()) { self.tuning = tuning }

    /// Lays the grid over a pad rectangle, centred, each dot on a pixel centre. Clears the field.
    mutating func resize(x: Double, y: Double, width: Double, height: Double, scale: Double) {
        let p = tuning.grid.pitch
        cols = max(1, Int(floor(width / p)))
        rows = max(1, Int(floor(height / p)))
        let s = max(scale, 1)
        func snap(_ v: Double) -> Double { (floor(v * s) + 0.5) / s }
        originX = snap(x + (width - Double(cols - 1) * p) / 2)
        originY = snap(y + (height - Double(rows - 1) * p) / 2)
        core = Array(repeating: 0, count: cols * rows)
        tail = core
        grab = core
        fingers = [:]
        ripples = []
        flashes = []
        brightest = 0
    }

    /// One append: the touch handler's whole cost.
    mutating func add(_ s: Sample) { pending.append(s) }

    var fingersDown: Int { fingers.values.filter { $0.down }.count }

    /// Something to draw: a lit dot, a finger, a ripple, the ghost, or a sample not yet used.
    var isLit: Bool {
        brightest > Float(tuning.frame.dark) || !fingers.isEmpty || !ripples.isEmpty || !flashes.isEmpty
            || ghost != nil || !pending.isEmpty || abs(grabLevel - (dragging ? 1 : 0)) > 1e-6
    }

    /// The tail's time constant for a speed, in seconds.
    func tailTau(speed v: Double) -> Double {
        let tr = tuning.trail
        let top = tr.tailTauMax + (tr.dragTauMax - tr.tailTauMax) * grabLevel
        return min(max(tr.tailTauNumerator / max(v, 1e-6), tr.tailTauMin), top)
    }

    /// The first-use stroke: an arc around a point, from `start`. A touch stops it.
    mutating func startGhost(cx: Double, cy: Double, at start: Double) {
        ghost = Ghost(cx: cx, cy: cy, start: start)
    }

    var ghostActive: Bool { ghost != nil }

    // MARK: Step

    mutating func step(to now: Double) {
        let dt = min(max(now - time, 0), 0.1)
        time = now
        let tr = tuning.trail
        let target = dragging ? 1.0 : 0.0
        if dt > 0 {
            let d = dt / max(tuning.trail.dragChange, 1e-3)
            grabLevel = grabLevel < target ? min(target, grabLevel + d) : max(target, grabLevel - d)
        }

        // The speed from the last frame's samples: one frame late, far inside the 0.15 s low-pass.
        var fastest = 0.0
        for f in fingers.values where f.down && lastDt > 0 { fastest = max(fastest, f.moved / lastDt) }
        if dt > 0 { smoothSpeed += (fastest - smoothSpeed) * (1 - exp(-dt / tr.speedSmoothing)) }
        for k in fingers.keys { fingers[k]!.moved = 0 }
        if dt > 0 { lastDt = dt }
        let tauC = tr.coreTau, tauT = tailTau(speed: smoothSpeed)

        decay(dt: dt, tauC: tauC, tauT: tauT)
        stepGhost()
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        for s in samples { apply(s, tauC: tauC, tauT: tauT) }

        if reduceMotion {
            for i in core.indices { core[i] = 0; tail[i] = 0 }
            brightest = 0
        }
        halos(dt: dt)
        ripplesStep(dt: dt)
    }

    /// e ← e·exp(−dt/τ), less a linear drain: the exact step of de/dt = −e/τ − drain,
    /// so the look is the same at 60 Hz and 120 Hz.
    private mutating func decay(dt: Double, tauC: Double, tauT: Double) {
        guard dt > 0 else { return }
        let k = tuning.trail.drain
        let ac = exp(-dt / tauC), at = exp(-dt / tauT)
        let a1 = Float(ac), b1 = Float(k * tauC * (1 - ac))
        let a2 = Float(at), b2 = Float(k * tauT * (1 - at))
        var top: Float = 0
        core.withUnsafeMutableBufferPointer { c in
            tail.withUnsafeMutableBufferPointer { t in
                for i in 0..<c.count {
                    let x = max(0, c[i] * a1 - b1), y = max(0, t[i] * a2 - b2)
                    c[i] = x
                    t[i] = y
                    top = max(top, max(x, y))
                }
            }
        }
        brightest = top
    }

    private mutating func apply(_ s: Sample, tauC: Double, tauT: Double) {
        switch s {
        case let .down(id, x, y, t):
            if id != Self.ghostId, ghost != nil { endGhost() }
            fingers[id] = Finger(x: x, y: y, t: t)
            stampSegment(id: id, toX: x, toY: y, t: t, tauC: tauC, tauT: tauT, first: true)
        case let .move(id, x, y, t):
            stampSegment(id: id, toX: x, toY: y, t: t, tauC: tauC, tauT: tauT, first: false)
        case let .up(id, _):
            guard var f = fingers[id] else { return }
            if reduceMotion { f.down = false; fingers[id] = f } else { fingers[id] = nil }
        case let .click(x, y):
            if reduceMotion { flashes.append(Ripple(x: x, y: y, age: 0)) } else { ripples.append(Ripple(x: x, y: y, age: 0)) }
        }
    }

    private func sigma(head: Double) -> Double {
        let tr = tuning.trail
        var s = tr.sigmaSlow - tr.sigmaDrop * min(max(head / tr.sigmaSpeed, 0), 1)
        if fingersDown >= 2 { s *= tr.multiFingerSigma }
        return s * (1 + (tr.dragSigma - 1) * grabLevel)
    }

    private mutating func stampSegment(id: Int, toX x: Double, toY y: Double, t: Double, tauC: Double, tauT: Double, first: Bool) {
        guard var f = fingers[id] else { return }
        let tr = tuning.trail
        let dx = x - f.x, dy = y - f.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let dts = t - f.t
        if !first, dts > 0 {
            f.head += (dist / dts - f.head) * (1 - exp(-dts / tr.headSmoothing))
        }
        f.moved += dist
        let sig = sigma(head: f.head)
        let peak = tr.peakBase + tr.peakGain * min(max(f.head / tr.peakSpeed, 0), 1)
        let age = max(time - t, 0)
        let wc = exp(-age / tauC), wt = exp(-age / tauT)
        if !reduceMotion {
            if first {
                stamp(x: x, y: y, sigma: sig, core: peak * wc, tail: peak * wt)
            } else if dist > 0 {
                var along = tr.stampSpacing - f.carry
                while along <= dist {
                    let u = along / dist
                    stamp(x: f.x + dx * u, y: f.y + dy * u, sigma: sig, core: peak * wc, tail: peak * wt)
                    along += tr.stampSpacing
                }
                f.carry = dist - (along - tr.stampSpacing)
            }
        }
        f.x = x
        f.y = y
        f.t = t
        fingers[id] = f
    }

    private mutating func halos(dt: Double) {
        let tr = tuning.trail
        let rise = 1 - exp(-dt / max(tr.haloRise, 1e-3))
        for (id, var f) in fingers {
            if f.down {
                f.halo += (1 - f.halo) * rise
            } else {
                f.halo *= exp(-dt / 0.05)
                if f.halo < 0.004 { fingers[id] = nil; continue }
            }
            fingers[id] = f
            let s = tr.haloSigma * (fingersDown >= 2 ? tr.multiFingerSigma : 1)
            let v = tr.haloPeak * f.halo
            stamp(x: f.x, y: f.y, sigma: s, core: v, tail: v)
            if grabLevel > 0, f.down {
                ring(x: f.x, y: f.y, radius: tr.dragRingRadius, sigma: tr.dragRingWidth, peak: tr.dragRingPeak * grabLevel * f.halo, gaussian: 1)
            }
        }
    }

    private mutating func ripplesStep(dt: Double) {
        let rp = tuning.ripple
        for i in ripples.indices.reversed() {
            let u = ripples[i].age / max(rp.duration, 1e-3)
            if u >= 1 { ripples.remove(at: i); continue }
            let ease = 1 - pow(1 - u, 3)
            ring(x: ripples[i].x, y: ripples[i].y, radius: rp.radius * ease, sigma: rp.width / 2,
                 peak: rp.peak * (1 - u), gaussian: rp.gaussian)
            ripples[i].age += dt
        }
        for i in flashes.indices.reversed() {
            let u = flashes[i].age / max(rp.flash, 1e-3)
            if u >= 1 { flashes.remove(at: i); continue }
            let v = tuning.trail.haloPeak + (1 - tuning.trail.haloPeak) * (1 - u)
            stamp(x: flashes[i].x, y: flashes[i].y, sigma: tuning.trail.haloSigma, core: v, tail: 0)
            flashes[i].age += dt
        }
    }

    // MARK: Ghost

    private mutating func stepGhost() {
        guard var g = ghost else { return }
        let gh = tuning.ghost
        let u = (time - g.start) / max(gh.duration, 1e-3)
        guard u >= 0 else { return }
        if u >= 1 { endGhost(); return }
        let e = u * u * (3 - 2 * u)
        let a = -.pi / 2 - gh.sweep / 2 + gh.sweep * e
        let x = g.cx + gh.radius * cos(a), y = g.cy + gh.radius * 0.6 * sin(a) + gh.radius * 0.3
        pending.insert(g.began ? .move(id: Self.ghostId, x: x, y: y, t: time) : .down(id: Self.ghostId, x: x, y: y, t: time), at: 0)
        g.began = true
        g.lastX = x
        g.lastY = y
        ghost = g
    }

    private mutating func endGhost() {
        ghost = nil
        fingers[Self.ghostId] = nil
    }

    // MARK: Stamps

    /// A Gaussian: each cell takes the larger of its value and the stamp's, so a slow finger
    /// cannot push a cell above the stamp's peak.
    mutating func stamp(x: Double, y: Double, sigma: Double, core cv: Double, tail tv: Double) {
        guard cols > 0, sigma > 0 else { return }
        let p = tuning.grid.pitch
        let cx = (x - originX) / p, cy = (y - originY) / p
        let r = Int(ceil(3 * sigma / p))
        let i0 = max(0, Int(cx.rounded()) - r), i1 = min(cols - 1, Int(cx.rounded()) + r)
        let j0 = max(0, Int(cy.rounded()) - r), j1 = min(rows - 1, Int(cy.rounded()) + r)
        guard i0 <= i1, j0 <= j1 else { return }
        let k = -0.5 / (sigma * sigma)
        kx.removeAll(keepingCapacity: true)
        ky.removeAll(keepingCapacity: true)
        for i in i0...i1 { let d = (Double(i) - cx) * p; kx.append(Float(exp(k * d * d))) }
        for j in j0...j1 { let d = (Double(j) - cy) * p; ky.append(Float(exp(k * d * d))) }
        let c = Float(cv), t = Float(tv), g = Float(grabLevel)
        var top = brightest
        for j in j0...j1 {
            let gy = ky[j - j0], row = j * cols
            for i in i0...i1 {
                let w = kx[i - i0] * gy
                let n = row + i
                let a = c * w, b = t * w
                if a > core[n] { core[n] = a }
                if b > tail[n] { tail[n] = b; grab[n] = g }
                top = max(top, max(a, b))
            }
        }
        brightest = top
    }

    /// A ring into the core only, so it leaves no trail. `gaussian` mixes a plain band toward
    /// a Gaussian profile across the width.
    mutating func ring(x: Double, y: Double, radius: Double, sigma: Double, peak: Double, gaussian: Double) {
        guard cols > 0, peak > 0 else { return }
        let p = tuning.grid.pitch
        let reach = radius + 3 * sigma
        let i0 = max(0, Int(floor((x - reach - originX) / p))), i1 = min(cols - 1, Int(ceil((x + reach - originX) / p)))
        let j0 = max(0, Int(floor((y - reach - originY) / p))), j1 = min(rows - 1, Int(ceil((y + reach - originY) / p)))
        guard i0 <= i1, j0 <= j1 else { return }
        var top = brightest
        for j in j0...j1 {
            let dy = originY + Double(j) * p - y
            for i in i0...i1 {
                let dx = originX + Double(i) * p - x
                let d = abs((dx * dx + dy * dy).squareRoot() - radius)
                let band = min(max((sigma + p / 2 - d) / p, 0), 1)
                let gauss = exp(-d * d / (2 * sigma * sigma))
                let v = Float(peak * (band + (gauss - band) * gaussian))
                let n = j * cols + i
                if v > core[n] { core[n] = v }
                top = max(top, v)
            }
        }
        brightest = top
    }

    // MARK: Upload

    /// RGBA8 for each cell: √core, √tail (more steps at the dim end), grab, 0.
    func encode(into out: UnsafeMutablePointer<UInt8>) {
        core.withUnsafeBufferPointer { c in
            tail.withUnsafeBufferPointer { t in
                grab.withUnsafeBufferPointer { g in
                    for i in 0..<c.count {
                        out[4 * i] = UInt8(min(c[i].squareRoot(), 1) * 255 + 0.5)
                        out[4 * i + 1] = UInt8(min(t[i].squareRoot(), 1) * 255 + 0.5)
                        out[4 * i + 2] = UInt8(min(max(g[i], 0), 1) * 255 + 0.5)
                        out[4 * i + 3] = 0
                    }
                }
            }
        }
    }

    /// A cell's values, for tests.
    func cell(_ i: Int, _ j: Int) -> (core: Float, tail: Float, grab: Float) {
        let n = j * cols + i
        return (core[n], tail[n], grab[n])
    }
}

/// The colour maths of the shader, in Swift, so that tests can check it. The shader in
/// PadSurfaceView.swift must match.
enum PadLook {
    typealias RGB = SIMD3<Double>

    static func rgb(_ hex: String) -> RGB { let c = PadTuning.rgb(hex); return RGB(c.0, c.1, c.2) }
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * t }
    static func luma(_ c: RGB) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// The trail's colour at a tail energy: white for a move, blue for a drag. At zero it is
    /// the idle dot's colour (for a drag, 30 % toward the blue), so the fade lands on the idle dot.
    static func tailColour(_ e: Double, grab: Double, _ t: PadTuning) -> RGB {
        let c = t.colour
        let idle = rgb(c.idle)
        func ramp(_ s1: RGB, _ s05: RGB, _ s005: RGB, _ s0: RGB) -> RGB {
            if e >= 0.5 { return mix(s05, s1, min((e - 0.5) / 0.5, 1)) }
            if e >= 0.05 { return mix(s005, s05, (e - 0.05) / 0.45) }
            return mix(s0, s005, max(e, 0) / 0.05)
        }
        let move = ramp(rgb(c.move1), rgb(c.move05), rgb(c.move005), idle)
        let drag = ramp(rgb(c.drag1), rgb(c.drag05), rgb(c.drag005), mix(idle, rgb(c.drag005), c.dragIdleMix))
        return mix(move, drag, grab)
    }

    static func litAlpha(_ e: Double, _ t: PadTuning, contrast: Bool = false) -> Double {
        let idle = contrast ? t.contrast.idleAlpha : t.grid.idleAlpha
        return (1 - idle) * pow(max(e, 0), t.grid.alphaExponent)
    }

    /// The centre pixel of a dot over the base: the idle dot, then the lit light added on top.
    static func dotCentre(core: Double, tail: Double, grab: Double, base: RGB, _ t: PadTuning, contrast: Bool = false) -> RGB {
        let idleA = contrast ? t.contrast.idleAlpha : t.grid.idleAlpha
        var c = mix(base, rgb(t.colour.idle), idleA)
        let e = max(core, tail)
        let lit = mix(tailColour(tail, grab: grab, t), rgb(t.colour.core), min(max(core, 0), 1))
        c += lit * litAlpha(e, t, contrast: contrast)
        return RGB(min(c.x, 1), min(c.y, 1), min(c.z, 1))
    }
}
