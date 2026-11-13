import Foundation

// The pad's energy grid and its colour maths (ios/Pad/PadField.swift), as the plan's tests list.
@main
struct PadFieldTests {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); failures += 1 }
    }
    static func near(_ a: Double, _ b: Double, rel: Double) -> Bool { abs(a - b) <= rel * max(abs(b), 1e-9) }

    /// An 800 × 800 pt field at 3x, its dots on a 5 pt grid.
    static func field(_ t: PadTuning = PadTuning()) -> PadField {
        var f = PadField(tuning: t)
        f.resize(x: 0, y: 0, width: 800, height: 800, scale: 3)
        return f
    }

    /// One finger along y = 400 at `speed` pt/s, samples at 120 Hz, frames at `hz`. Returns the time of the lift.
    @discardableResult
    static func stroke(_ f: inout PadField, from x0: Double, speed: Double, seconds: Double, hz: Double = 120, start: Double = 0, lift: Bool = true) -> Double {
        var t = start
        f.add(.down(id: 1, x: x0, y: 400, t: t))
        f.step(to: t)
        let sampleDt = 1.0 / 120
        var next = t + sampleDt
        while t < start + seconds {
            t += 1 / hz
            while next <= t + 1e-9 {
                f.add(.move(id: 1, x: x0 + speed * (next - start), y: 400, t: next))
                next += sampleDt
            }
            f.step(to: t)
        }
        if lift { f.add(.up(id: 1, t: t)); f.step(to: t) }
        return t
    }

    static func maxCell(_ f: PadField) -> Float {
        var m: Float = 0
        for j in 0..<f.rows { for i in 0..<f.cols { let c = f.cell(i, j); m = max(m, max(max(c.core, c.tail), c.ring)) } }
        return m
    }

    static func main() {
        let t = PadTuning()

        // One stamp: the centre, 1σ and 3σ. σ = one pitch, on a dot.
        do {
            var f = field()
            let x = f.originX + 40 * 5, y = f.originY + 80 * 5
            f.stamp(x: x, y: y, sigma: 5, core: 1, tail: 0.8)
            check(near(Double(f.cell(40, 80).core), 1, rel: 1e-5), "stamp centre")
            check(near(Double(f.cell(41, 80).core), exp(-0.5), rel: 1e-4), "stamp at 1σ is exp(−½)")
            check(near(Double(f.cell(40, 83).tail), 0.8 * exp(-4.5), rel: 1e-3), "stamp at 3σ is exp(−4.5)")
            check(f.cell(45, 80).core == 0, "nothing past 3σ")
        }

        // Decay is exp(−t/τ) at 60 Hz and at 120 Hz, within 0.5 %. With no drain, it is exact.
        do {
            var nt = t
            nt.trail.drain = 0
            for hz in [60.0, 120.0] {
                var f = field(nt)
                f.stamp(x: f.originX + 100, y: f.originY + 100, sigma: 5, core: 1, tail: 1)
                var now = 0.0
                f.step(to: 0)
                for _ in 0..<Int(0.3 * hz) { now += 1 / hz; f.step(to: now) }
                let c = f.cell(20, 20)
                check(near(Double(c.core), exp(-now / nt.trail.coreTau), rel: 0.005), "core decay at \(hz) Hz: \(c.core)")
                check(near(Double(c.tail), exp(-now / f.tailTau(speed: 0)), rel: 0.005), "tail decay at \(hz) Hz: \(c.tail)")
            }
            // With the drain the look still does not depend on the frame rate.
            var vals: [Double] = []
            for hz in [60.0, 120.0] {
                var f = field()
                f.stamp(x: f.originX + 100, y: f.originY + 100, sigma: 5, core: 1, tail: 1)
                var now = 0.0
                f.step(to: 0)
                for _ in 0..<Int(0.3 * hz) { now += 1 / hz; f.step(to: now) }
                vals.append(Double(f.cell(20, 20).tail))
            }
            check(near(vals[0], vals[1], rel: 0.005), "the drained decay is the same at 60 and 120 Hz: \(vals)")
        }

        // The tail's τ at 0, 273, 1,333 and 3,000 pt/s.
        do {
            let f = field()
            check(near(f.tailTau(speed: 0), 0.22, rel: 1e-9), "τ at rest is 0.22")
            check(near(f.tailTau(speed: 273), 60.0 / 273, rel: 1e-9), "τ at 273 pt/s is 0.22")
            check(near(f.tailTau(speed: 1333), 0.045, rel: 0.001), "τ at 1,333 pt/s is 0.045")
            check(near(f.tailTau(speed: 3000), 0.045, rel: 1e-9), "τ at 3,000 pt/s is 0.045")
        }

        // At 1,000 pt/s the visible trail (down to 5 %) behind the finger is at most 180 pt.
        do {
            var f = field()
            stroke(&f, from: 20, speed: 1000, seconds: 0.7, lift: false)
            let head = 20 + 1000 * 0.7
            let j = Int(((400 - f.originY) / 5).rounded())
            var tailEnd = head
            for i in 0..<f.cols where Double(f.cell(i, j).tail) >= 0.05 { tailEnd = min(tailEnd, f.originX + Double(i) * 5) }
            let length = head - tailEnd
            print("trail at 1,000 pt/s: \(Int(length)) pt")
            check(length <= 180, "trail at 1,000 pt/s is \(length) pt, more than 180")
            check(length >= 60, "trail at 1,000 pt/s is \(length) pt, too short to see")
        }

        // Every cell is dark 1.0 s after the last input: a slow stroke, a flick, and a drag.
        for (name, speed, drag) in [("slow", 100.0, false), ("flick", 3000.0, false), ("drag", 200.0, true)] {
            var f = field()
            f.dragging = drag
            let end = stroke(&f, from: 20, speed: speed, seconds: 0.12)
            f.dragging = false
            var now = end
            while now < end + 1.0 { now += 1.0 / 60; f.step(to: now) }
            let m = maxCell(f)
            check(m < 1.0 / 255, "\(name): a cell is \(m) 1.0 s after the lift")
            // and the display link may stop
            var g = f
            g.step(to: now + 1.0 / 60)
            check(!g.isLit, "\(name): the field still reads as lit")
        }

        // Reduce Motion: no tail and no ripple. The halo follows the finger.
        do {
            var f = field()
            f.reduceMotion = true
            stroke(&f, from: 20, speed: 400, seconds: 0.5, lift: false)
            let j = Int(((400 - f.originY) / 5).rounded())
            check(f.cell(4, j).tail == 0, "Reduce Motion leaves no trail at the start of the stroke")
            let head = Int(((220 - f.originX) / 5).rounded())
            check(f.cell(head, j).core > 0.4, "Reduce Motion keeps the halo under the finger")
        }
        // A ripple lights a ring at its radius; with Reduce Motion it does not.
        for rm in [false, true] {
            var f = field()
            f.reduceMotion = rm
            f.step(to: 0)
            f.add(.click(x: 200, y: 200))
            var now = 0.0
            for _ in 0..<12 { now += 1.0 / 120; f.step(to: now) }
            let u = (now - 1.0 / 120) / t.ripple.duration
            let r = t.ripple.radius * (1 - pow(1 - u, 3))
            let ri = Int(((200 + r - f.originX) / 5).rounded()), rj = Int(((200 - f.originY) / 5).rounded())
            let v = f.cell(ri, rj).ring
            if rm { check(v < 0.01, "Reduce Motion draws no ripple ring: \(v)") } else { check(v > 0.2, "a ripple lights its ring: \(v)") }
        }

        // A slow finger does not push a cell above its peak.
        do {
            var f = field()
            stroke(&f, from: 20, speed: 10, seconds: 2, lift: false)
            let peak = Float(t.trail.peakBase + t.trail.peakGain * 10 / t.trail.peakSpeed)
            check(maxCell(f) <= peak + 1e-4, "a slow finger reached \(maxCell(f)), more than its peak \(peak)")
        }

        // A move lays down white, a drag lays down blue.
        do {
            var f = field()
            stroke(&f, from: 20, speed: 300, seconds: 0.3, lift: false)
            let j = Int(((400 - f.originY) / 5).rounded())
            check(f.cell(15, j).grab == 0, "a move's trail is not a drag's")
            var g = field()
            g.dragging = true
            stroke(&g, from: 20, speed: 300, seconds: 0.3, lift: false)
            check(g.cell(15, j).grab > 0.9, "a drag's trail is a drag's: \(g.cell(15, j).grab)")
        }

        // The fade lands on the idle dot: no energy makes a dot darker than idle, and the
        // colour does not jump at the end of the fade.
        do {
            let base = PadLook.rgb(t.light.baseCentre)
            for contrast in [false, true] {
                let idle = PadLook.dotCentre(core: 0, tail: 0, grab: 0, base: base, t, contrast: contrast)
                let idleLuma = PadLook.luma(idle)
                for grab in [0.0, 0.5, 1.0] {
                    for coreShare in [0.0, 0.5, 1.0] {
                        var last = idle, lastLuma = idleLuma
                        var e = 0.0
                        while e <= 1.0 {
                            let c = PadLook.dotCentre(core: e * coreShare, tail: e, grab: grab, base: base, t, contrast: contrast)
                            let l = PadLook.luma(c)
                            check(l >= idleLuma - 1e-12, "luma at e \(e), grab \(grab) is below idle")
                            check(l >= lastLuma - 0.001, "luma falls as energy rises at e \(e), grab \(grab)")
                            let jump = max(abs(c.x - last.x), abs(c.y - last.y), abs(c.z - last.z))
                            check(jump < 0.01, "the colour jumps by \(jump) at e \(e), grab \(grab)")
                            last = c
                            lastLuma = l
                            e += 0.001
                        }
                    }
                }
            }
            // A drag's fade ends tinted 30 % toward the blue, not dim.
            let end = PadLook.tailColour(0, grab: 1, t)
            check(end.z > end.x, "a drag's fade ends with some blue")
            check(PadLook.tailColour(0, grab: 0, t) == PadLook.rgb(t.colour.idle), "a move's fade ends on the idle colour")
        }

        // The tuning file: a partial file keeps the other defaults.
        do {
            let partial = #"{"trail": {"coreTau": 0.09}, "unknown": 1}"#.data(using: .utf8)!
            let loaded = try! PadTuning.load(partial)
            check(loaded.trail.coreTau == 0.09, "the file sets coreTau")
            check(loaded.trail.tailTauMax == 0.22 && loaded.grid.pitch == 5, "the file keeps the other defaults")
            let round = try! PadTuning.load(try! t.export())
            check(round == t, "export then load is the same tuning")
        }

        // Cost of one frame on this Mac: a finger moving, decay, stamps and the upload.
        for (name, w, h) in [("iPhone upright", 386.0, 766.0), ("iPad 13-inch", 1360.0, 1000.0)] {
            var f = PadField()
            f.resize(x: 0, y: 0, width: w, height: h, scale: 3)
            var bytes = [UInt8](repeating: 0, count: f.cols * f.rows * 4)
            let frames = 2000
            var now = 0.0
            f.add(.down(id: 1, x: 50, y: 50, t: 0))
            let start = DispatchTime.now().uptimeNanoseconds
            for n in 0..<frames {
                now += 1.0 / 120
                let a = Double(n) * 0.05
                f.add(.move(id: 1, x: w / 2 + 150 * cos(a), y: h / 2 + 150 * sin(a), t: now))
                f.step(to: now)
                bytes.withUnsafeMutableBufferPointer { f.encode(into: $0.baseAddress!) }
            }
            let us = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(frames) / 1000
            print(String(format: "frame cost, %@ (%d × %d dots): %.1f µs on this Mac", name, f.cols, f.rows, us))
        }

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("test_pad_field: all passed")
    }
}
