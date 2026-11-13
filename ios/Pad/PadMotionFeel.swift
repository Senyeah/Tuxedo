import Foundation

/// The motion haptic's strength: the size of the finger's acceleration, from speeding up,
/// slowing down or turning. Pure, so the tests drive it with their own clock.
/// Two clocks: a sample's time is when the screen saw the finger, some 20 to 30 ms before it arrives.
/// A still finger is one with no sample arriving, so the frame clock compares only with arrivals.
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
    private var arrived = 0.0      // frame clock, at the last real sample
    private var seen = 0.0         // touch clock, of the last real sample
    private var stopTicked = false

    init(tuning: PadTuning.Motion = .init()) { self.tuning = tuning }

    var active: Bool { last != nil }
    var texture: Double { level > 0 ? felt(tuning.textureMin, tuning.textureGain) : 0 }

    private func felt(_ lo: Double, _ hi: Double) -> Double { lo + (max(hi, lo) - lo) * level }

    mutating func begin(x: Double, y: Double, t: Double, arrival: Double? = nil) {
        last = (x, y, t)
        vx = 0; vy = 0; accel = 0; level = 0; travel = 0; resting = false
        seen = t; arrived = arrival ?? t; stopTicked = false
    }

    mutating func end() {
        last = nil
        vx = 0; vy = 0; accel = 0; level = 0
    }

    /// A finger sample at touch time t, arriving at `arrival` on the frame clock (t when nil).
    /// Returns a tick's intensity when one is due.
    mutating func sample(x: Double, y: Double, t: Double, arrival: Double? = nil) -> Double? {
        guard let l = last else { begin(x: x, y: y, t: t, arrival: arrival); return nil }
        seen = max(seen, t); arrived = arrival ?? t; resting = false; stopTicked = false
        // An older sample than a still-finger step: its travel goes into the next sample.
        guard t > l.t + 1e-4 else { return nil }
        let dx = x - l.x, dy = y - l.y
        advance(dx: dx, dy: dy, dt: t - l.t)
        last = (x, y, t)
        travel += hypot(dx, dy)
        guard travel >= tuning.tickSpacing else { return nil }
        travel = min(travel - tuning.tickSpacing, tuning.tickSpacing) // no burst after a long gap
        guard level > 0, t - lastTick >= tuning.tickGap else { return nil }
        let i = felt(tuning.tickMin, tuning.tickGain)
        lastTick = t
        return i
    }

    /// Each frame, on the frame clock: a finger that sends no samples has stopped, and that stop is felt.
    /// Returns one tick for a stop that is strong enough.
    @discardableResult
    mutating func step(now: Double) -> Double? {
        guard let l = last, resting || now - arrived > tuning.still else { return nil }
        let t = seen + (now - arrived) // the touch clock's now
        guard t > l.t + 1e-4 else { return nil }
        advance(dx: 0, dy: 0, dt: t - l.t)
        last = (l.x, l.y, t)
        resting = true
        guard !stopTicked, level > 0, t - lastTick >= tuning.tickGap else { return nil }
        stopTicked = true
        lastTick = t
        return felt(tuning.tickMin, tuning.tickGain)
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
