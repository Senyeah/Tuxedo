import Foundation

// The motion haptic's strength from the finger's acceleration (ios/Pad/PadMotionFeel.swift).
@main
struct PadMotionTests {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); failures += 1 }
    }

    struct Run {
        var peak = 0.0, last = 0.0
        var ticks: [(t: Double, i: Double)] = []
        var levels: [(t: Double, level: Double)] = []
    }

    /// Moves along x with speed v(t) for `seconds`, sampled at `hz`, then frames at 120 Hz with no samples for `after`.
    static func run(hz: Double, seconds: Double, after: Double = 0, tuning: PadTuning.Motion = .init(),
                    speed: (Double) -> Double) -> Run {
        var f = PadMotionFeel(tuning: tuning)
        var r = Run()
        var x = 0.0, t = 0.0
        f.begin(x: 0, y: 0, t: 0)
        let dt = 1 / hz
        while t < seconds - 1e-9 {
            x += speed(t) * dt
            t += dt
            if let i = f.sample(x: x, y: 0, t: t) { r.ticks.append((t, i)) }
            r.levels.append((t, f.level))
            r.peak = max(r.peak, f.level)
        }
        var s = t
        while s < t + after {
            s += 1.0 / 120
            f.step(now: s)
            r.levels.append((s, f.level))
        }
        r.last = f.level
        return r
    }

    static func main() {
        let m = PadTuning.Motion()
        func expected(_ a: Double) -> Double { min(max((a - m.floor) / (m.full - m.floor), 0), 1) }

        // A steady finger has no acceleration, so it is silent once the start has passed.
        let steady = run(hz: 240, seconds: 1) { _ in 600 }
        let late = steady.levels.filter { $0.t > 0.4 }.map(\.level).max() ?? 1
        check(late == 0, "a steady move is silent, got \(late)")
        check(steady.ticks.allSatisfy { $0.t < 0.4 }, "a steady move gives no ticks after its start")

        // Below the floor nothing plays.
        let gentle = run(hz: 240, seconds: 0.6) { t in min(t, 0.3) * 1000 } // 1000 pt/s²
        check(gentle.peak == 0, "a gentle start is under the floor, got \(gentle.peak)")

        // Stronger acceleration, stronger haptic, about in proportion.
        var peaks: [Double] = []
        for a in [8000.0, 16000, 24000] {
            let r = run(hz: 240, seconds: 0.3) { t in a * min(t, 0.15) }
            peaks.append(r.peak)
            check(abs(r.peak - expected(a)) < 0.12, "at \(a) pt/s² the level is \(r.peak), about \(expected(a)) expected")
        }
        check(peaks[0] < peaks[1] && peaks[1] < peaks[2], "the level rises with the acceleration: \(peaks)")
        check(run(hz: 240, seconds: 0.3) { t in 200000 * min(t, 0.05) }.peak <= 1, "the level stops at 1")

        // Slowing down is felt as much as speeding up.
        let up = run(hz: 240, seconds: 0.3) { t in 16000 * min(t, 0.15) }
        let down = run(hz: 240, seconds: 0.5) { t in t < 0.2 ? 2400 : max(2400 - 16000 * (t - 0.2), 0) }
        let downPeak = down.levels.filter { $0.t > 0.2 }.map(\.level).max() ?? 0
        check(abs(downPeak - up.peak) < 0.1, "slowing down (\(downPeak)) feels as speeding up (\(up.peak))")

        // A sudden stop with no more samples: felt at once, silent soon after.
        let stop = run(hz: 240, seconds: 0.4, after: 0.6) { _ in 1500 }
        let afterStop = stop.levels.filter { $0.t > 0.4 && $0.t < 0.5 }.map(\.level).max() ?? 0
        check(afterStop > 0.2, "a sudden stop is felt, got \(afterStop)")
        check(stop.last == 0, "a still finger goes silent, got \(stop.last)")
        let silentBy = stop.levels.first { $0.t > 0.45 && $0.level == 0 }?.t ?? 99
        check(silentBy < 0.7, "a still finger is silent 0.3 s after the stop, at \(silentBy)")

        // The same motion gives the same feel at 60, 120 and 240 Hz.
        let rates = [60.0, 120, 240].map { hz in run(hz: hz, seconds: 0.3) { t in 16000 * min(t, 0.15) }.peak }
        check((rates.max()! - rates.min()!) < 0.1, "the level does not depend on the sample rate: \(rates)")

        // Turning is acceleration too: a circle of 50 pt at 1000 pt/s is 20000 pt/s².
        var f = PadMotionFeel()
        f.begin(x: 50, y: 0, t: 0)
        var turn = 0.0
        for i in 1...240 {
            let t = Double(i) / 240, a = t * 1000 / 50
            _ = f.sample(x: 50 * cos(a), y: 50 * sin(a), t: t)
            if t > 0.3 { turn = max(turn, f.level) }
        }
        check(abs(turn - expected(20000)) < 0.12, "a turn is felt as its acceleration: \(turn), about \(expected(20000))")

        // Ticks: only with acceleration, never faster than the gap, never above the gain.
        let flick = run(hz: 240, seconds: 0.3) { t in 30000 * min(t, 0.1) }
        check(!flick.ticks.isEmpty, "a flick gives ticks")
        check(zip(flick.ticks, flick.ticks.dropFirst()).allSatisfy { $1.t - $0.t >= m.tickGap - 1e-9 }, "ticks keep their gap")
        check(flick.ticks.allSatisfy { $0.i <= m.tickGain + 1e-9 && $0.i >= m.tickMin - 1e-9 }, "ticks stay within the minimum and the gain")

        // An older sample is skipped, and its travel comes in the next one.
        var g = PadMotionFeel()
        g.begin(x: 0, y: 0, t: 1)
        _ = g.sample(x: 5, y: 0, t: 0.99)
        g.step(now: 1.1)
        _ = g.sample(x: 10, y: 0, t: 1.105)
        check(g.level.isFinite && g.accel.isFinite, "an older sample does no harm")
        g.end()
        check(!g.active && g.level == 0, "the end stops the feel")

        // As on the phone: touches sampled at 240 Hz arrive 25 ms late, in a batch each 120 Hz frame,
        // and each frame steps on the arrival clock. The move must be felt as without the latency.
        func delayed(_ latency: Double, frameHz: Double, speed: (Double) -> Double, seconds: Double, after: Double)
            -> (peak: Double, last: Double, stopTicks: Int) {
            var f = PadMotionFeel()
            var queue: [(x: Double, t: Double)] = []
            var x = 0.0, t = 0.0, frame = 0.0, peak = 0.0, stopTicks = 0
            f.begin(x: 0, y: 0, t: 0, arrival: latency)
            while frame < seconds + after {
                frame += 1 / frameHz
                while t + 1.0 / 240 <= min(frame - latency, seconds) {
                    t += 1.0 / 240
                    x += speed(t) / 240
                    queue.append((x, t))
                }
                for s in queue { _ = f.sample(x: s.x, y: 0, t: s.t, arrival: frame) }
                queue.removeAll()
                if f.step(now: frame) != nil { stopTicks += 1 }
                if frame < seconds + latency { peak = max(peak, f.level) }
            }
            return (peak, f.level, stopTicks)
        }
        let direct = run(hz: 240, seconds: 0.3) { t in 16000 * min(t, 0.15) }.peak
        for hz in [60.0, 120] {
            let r = delayed(0.025, frameHz: hz, speed: { t in 16000 * min(t, 0.15) }, seconds: 0.3, after: 0)
            check(abs(r.peak - direct) < 0.1, "with 25 ms touch latency at \(hz) Hz the level is \(r.peak), \(direct) without")
        }
        let steadyLate = delayed(0.025, frameHz: 60, speed: { _ in 600 }, seconds: 1, after: 0)
        check(steadyLate.last == 0, "a steady move with touch latency is silent at its end, got \(steadyLate.last)")
        let stopLate = delayed(0.025, frameHz: 120, speed: { _ in 1500 }, seconds: 0.4, after: 0.6)
        check(stopLate.last == 0, "a stop with touch latency goes silent")
        check(stopLate.stopTicks == 1, "a sudden stop gives one tick, got \(stopLate.stopTicks)")

        if failures > 0 { print("test_pad_motion: \(failures) failed"); exit(1) }
        print("test_pad_motion: all passed")
    }
}
