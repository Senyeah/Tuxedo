import Foundation

/// The motion haptic's strength: the size of the finger's acceleration, from speeding up,
/// slowing down or turning. Pure, so the tests drive it with their own clock.
struct PadMotionFeel {
    var tuning: PadTuning.Motion
    /// 0 to 1, before the style's gain.
    private(set) var level = 0.0
    /// pt/s², smoothed.
    private(set) var accel = 0.0

    private var last: (x: Double, y: Double, t: Double)?
    private var vx = 0.0, vy = 0.0
    private var travel = 0.0
    private var lastTick = -Double.infinity
    private var resting = false

    init(tuning: PadTuning.Motion = .init()) { self.tuning = tuning }

    var active: Bool { last != nil }
    var texture: Double { level * tuning.textureGain }

    mutating func begin(x: Double, y: Double, t: Double) {
        last = (x, y, t)
        vx = 0; vy = 0; accel = 0; level = 0; travel = 0; resting = false
    }

    mutating func end() {
        last = nil
        vx = 0; vy = 0; accel = 0; level = 0
    }

    /// A finger sample. Returns a tick's intensity when one is due.
    mutating func sample(x: Double, y: Double, t: Double) -> Double? {
        guard let l = last else { begin(x: x, y: y, t: t); return nil }
        // An older sample than a still-finger step: its travel goes into the next sample.
        guard t > l.t + 1e-4 else { return nil }
        let dx = x - l.x, dy = y - l.y
        advance(dx: dx, dy: dy, dt: t - l.t)
        last = (x, y, t)
        resting = false
        travel += hypot(dx, dy)
        guard travel >= tuning.tickSpacing else { return nil }
        travel = min(travel - tuning.tickSpacing, tuning.tickSpacing) // no burst after a long gap
        let i = level * tuning.tickGain
        guard t - lastTick >= tuning.tickGap, i >= tuning.tickMin else { return nil }
        lastTick = t
        return i
    }

    /// Each frame: a finger that sends no samples has stopped, and that stop is felt.
    mutating func step(now: Double) {
        guard let l = last, now > l.t + 1e-4, resting || now - l.t > tuning.still else { return }
        advance(dx: 0, dy: 0, dt: now - l.t)
        last = (l.x, l.y, now)
        resting = true
    }

    private mutating func advance(dx: Double, dy: Double, dt: Double) {
        let h = min(dt, 0.05)
        let kv = 1 - exp(-h / max(tuning.velocitySmoothing, 1e-4))
        let nx = vx + (dx / dt - vx) * kv, ny = vy + (dy / dt - vy) * kv
        let raw = hypot(nx - vx, ny - vy) / h
        vx = nx; vy = ny
        accel += (raw - accel) * (1 - exp(-h / max(tuning.accelSmoothing, 1e-4)))
        level = min(max((accel - tuning.floor) / max(tuning.full - tuning.floor, 1), 0), 1)
    }
}
