// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// On an iPhone the mouse drives AssistiveTouch's pointer, which stops at the phone's edges, and then the
/// mouse deltas almost stop too. While that pointer is held against an edge, this keeps the guest's pointer
/// going that way. The pointer's position comes in its own (system) axes, so which one belongs to each
/// guest axis is learnt from ordinary movement: it then works in every orientation.
struct EdgePush {
    static let dwell = 0.12          // s held at the edge before the push starts
    static let rampTime = 1.0        // s from the start speed to the top speed
    static let startSpeed = 400.0    // guest px/s
    static let topSpeed = 3000.0
    static let learnt = 100.0        // correlation needed before an axis may push
    static let span = 150.0          // pointer travel seen on an axis before its limits are trusted
    static let still = 0.1           // s the pointer must not move on that axis

    private var lo = [Double.infinity, Double.infinity], hi = [-Double.infinity, -Double.infinity]
    private var last: [Double]?
    private var pending = [0.0, 0.0]               // guest-space deltas since the last position
    private var corr = [[0.0, 0.0], [0.0, 0.0]]    // corr[guest axis][pointer axis]
    private var since: [Double?] = [nil, nil]
    private var lastTime: Double?
    private var rest = [0.0, 0.0]
    private var changed = [0.0, 0.0]               // when each pointer axis last moved

    init(bounds: (Double, Double)? = nil) {
        if let b = bounds { lo = [0, 0]; hi = [b.0, b.1] }
    }

    /// A position of the system pointer, in its own axes.
    mutating func pointer(_ x: Double, _ y: Double, now: Double) {
        let p = [x, y]
        for r in 0..<2 { lo[r] = min(lo[r], p[r]); hi[r] = max(hi[r], p[r]) }
        if let l = last {
            let d = [p[0] - l[0], p[1] - l[1]]
            for r in 0..<2 where abs(d[r]) > 0.25 { changed[r] = now }
            if d != [0, 0] {
                for a in 0..<2 { for r in 0..<2 { corr[a][r] += pending[a] * d[r] } }
            }
            pending = [0, 0] // a still pointer (at an edge) must not count against the next move
        }
        last = p
    }

    /// A mouse delta in guest axes (x right, y down). Returns the extra guest pixels to send.
    mutating func motion(_ gx: Double, _ gy: Double, now: Double) -> (Int32, Int32) {
        pending[0] += gx
        pending[1] += gy
        let dt = min(max(now - (lastTime ?? now), 0), 0.05)
        lastTime = now
        let g = [gx, gy]
        var out = [Int32(0), 0]
        for a in 0..<2 {
            guard let dir = edgeDirection(a, now: now), g[a] != 0, (g[a] > 0) == (dir > 0) else {
                since[a] = nil
                continue
            }
            let start = since[a] ?? now
            since[a] = start
            let held = now - start
            guard held >= Self.dwell else { continue }
            let k = min(1, (held - Self.dwell) / Self.rampTime)
            rest[a] += dir * (Self.startSpeed + k * (Self.topSpeed - Self.startSpeed)) * dt
            let whole = rest[a].rounded(.towardZero)
            rest[a] -= whole
            out[a] = Int32(whole)
        }
        return (out[0], out[1])
    }

    /// +1 or -1 when the pointer axis that moves with guest axis a is at its limit in that direction.
    private func edgeDirection(_ a: Int, now: Double) -> Double? {
        guard let p = last else { return nil }
        let c = corr[a]
        let r = abs(c[0]) >= abs(c[1]) ? 0 : 1
        guard abs(c[r]) >= Self.learnt, abs(c[r]) >= 3 * abs(c[1 - r]) else { return nil }
        guard hi[r] - lo[r] >= Self.span, now - changed[r] >= Self.still else { return nil }
        let sign: Double = c[r] > 0 ? 1 : -1
        if p[r] >= hi[r] - 0.5 { return sign }
        if p[r] <= lo[r] + 0.5 { return -sign }
        return nil
    }
}
