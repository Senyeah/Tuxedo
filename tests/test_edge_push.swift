import Foundation

@main
struct EdgePushTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    /// Moves the pointer by (dx, dy) in its axes while the mouse reports (gx, gy), n times at 60 Hz.
    static func move(_ e: inout EdgePush, from p: inout (Double, Double), d: (Double, Double), g: (Double, Double),
                     n: Int, t: inout Double) {
        for _ in 0..<n {
            t += 1.0 / 60
            _ = e.motion(g.0, g.1, now: t)
            p = (min(max(p.0 + d.0, 0), 402), min(max(p.1 + d.1, 0), 874))
            e.pointer(p.0, p.1, now: t)
        }
    }

    /// Pushes with a tiny delta for `seconds`, the pointer still. Returns the summed extra pixels.
    static func push(_ e: inout EdgePush, at p: (Double, Double), g: (Double, Double), seconds: Double, t: inout Double) -> (Int, Int) {
        var sum = (0, 0)
        for _ in 0..<Int(seconds * 60) {
            t += 1.0 / 60
            let (x, y) = e.motion(g.0, g.1, now: t)
            e.pointer(p.0, p.1, now: t) // the system sends the still position too
            sum.0 += Int(x)
            sum.1 += Int(y)
        }
        return sum
    }

    static func main() {
        var t = 0.0

        // Nothing learnt: no push, even at an edge.
        var e = EdgePush(bounds: (402, 874))
        e.pointer(402, 400, now: t)
        check(push(&e, at: (402, 400), g: (0.3, 0), seconds: 1, t: &t) == (0, 0), "an unlearnt axis must not push")

        // Upright phone: guest x is pointer x, guest y is pointer y.
        e = EdgePush(bounds: (402, 874))
        var p = (200.0, 400.0)
        e.pointer(p.0, p.1, now: t)
        move(&e, from: &p, d: (4, 0), g: (8, 0), n: 30, t: &t)
        move(&e, from: &p, d: (0, 4), g: (0, 8), n: 30, t: &t)
        move(&e, from: &p, d: (-4, 0), g: (-8, 0), n: 20, t: &t)
        move(&e, from: &p, d: (0, -4), g: (0, -8), n: 20, t: &t)
        check(push(&e, at: p, g: (0.3, 0), seconds: 1, t: &t) == (0, 0), "inside the edges there is no push")
        move(&e, from: &p, d: (10, 0), g: (20, 0), n: 40, t: &t)
        check(p.0 == 402, "the pointer reached the right edge")
        check(push(&e, at: p, g: (-0.3, 0), seconds: 0.1, t: &t) == (0, 0), "a pull away resets the push")
        let right = push(&e, at: p, g: (0.3, 0), seconds: 1.12, t: &t)
        check(right.0 > 300 && right.0 < 2000 && right.1 == 0, "a push right moves the guest right only, got \(right)")
        let faster = push(&e, at: p, g: (0.3, 0), seconds: 1, t: &t)
        check(faster.0 > 2500 && faster.0 <= 3001, "the push ramps up to its top speed, got \(faster)")
        check(push(&e, at: p, g: (-0.3, 0), seconds: 0.5, t: &t) == (0, 0), "a pull away from the edge must not push")
        let dwell = push(&e, at: p, g: (0.3, 0), seconds: 0.1, t: &t)
        check(dwell == (0, 0), "a short touch of the edge must not push")

        // Corner: both axes.
        move(&e, from: &p, d: (0, 10), g: (0, 20), n: 60, t: &t)
        check(p == (402, 874), "the pointer is in the bottom-right corner")
        let corner = push(&e, at: p, g: (0.3, 0.3), seconds: 1, t: &t)
        check(corner.0 > 300 && corner.1 > 300, "a corner pushes both axes, got \(corner)")

        // Left edge.
        move(&e, from: &p, d: (-10, 0), g: (-20, 0), n: 60, t: &t)
        _ = push(&e, at: p, g: (0.3, 0), seconds: 0.1, t: &t)
        let left = push(&e, at: p, g: (-0.3, 0), seconds: 1, t: &t)
        check(left.0 < -300 && left.1 == 0, "a push left moves the guest left, got \(left)")

        // Phone on its side: guest x is pointer y, guest y is pointer -x.
        e = EdgePush(bounds: (402, 874))
        p = (200, 400)
        e.pointer(p.0, p.1, now: t)
        move(&e, from: &p, d: (0, 4), g: (8, 0), n: 30, t: &t)
        move(&e, from: &p, d: (-4, 0), g: (0, 8), n: 30, t: &t)
        move(&e, from: &p, d: (0, 10), g: (20, 0), n: 60, t: &t)
        check(p.1 == 874, "the pointer reached the far end of its y axis")
        let side = push(&e, at: p, g: (0.3, 0), seconds: 1, t: &t)
        check(side.0 > 300 && side.1 == 0, "on its side a push right still moves the guest right, got \(side)")
        move(&e, from: &p, d: (-10, 0), g: (0, 20), n: 60, t: &t)
        check(p.0 == 0, "the pointer reached x 0")
        let down = push(&e, at: p, g: (0, 0.3), seconds: 1, t: &t)
        check(down.1 > 300 && down.0 == 0, "on its side a push down moves the guest down, got \(down)")

        // Limits learnt from the pointer when no bounds are given.
        e = EdgePush()
        p = (200, 400)
        e.pointer(p.0, p.1, now: t)
        move(&e, from: &p, d: (10, 0), g: (20, 0), n: 60, t: &t)
        let learnt = push(&e, at: p, g: (0.3, 0), seconds: 1, t: &t)
        check(learnt.0 > 300, "the edge is learnt from where the pointer stops, got \(learnt)")

        // A slow move in the middle: the pointer moves every sample, so there is no push.
        e = EdgePush()
        p = (100, 400)
        e.pointer(p.0, p.1, now: t)
        move(&e, from: &p, d: (10, 0), g: (20, 0), n: 25, t: &t)
        var slow = 0
        for _ in 0..<60 {
            t += 1.0 / 60
            slow += Int(e.motion(0.5, 0, now: t).0)
            p.0 += 0.5
            e.pointer(p.0, p.1, now: t)
        }
        check(slow == 0, "a slow move at the furthest point seen must not push, got \(slow)")

        print("PASS: no push unlearnt or inside, dwell, ramp, pull-away, corner, both edges, phone on its side, learnt limits")
    }
}
