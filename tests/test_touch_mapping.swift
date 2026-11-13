import CoreGraphics

@main
struct TouchMappingTests {
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    static func pos(_ x: CGFloat, _ y: CGFloat, _ r: CGRect) -> String {
        let p = TouchMapping.position(CGPoint(x: x, y: y), in: r)
        return "\(p.x),\(p.y)"
    }

    static func main() {
        // A 16:9 guest in a wider frame: bars at the sides.
        let wide = TouchMapping.pictureRect(guest: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 874, height: 402))
        precondition(near(wide, CGRect(x: (874 - 402 * 16.0 / 9) / 2, y: 0, width: 402 * 16.0 / 9, height: 402)))
        // In a taller frame: bars above and below.
        let tall = TouchMapping.pictureRect(guest: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 402, height: 874))
        precondition(near(tall, CGRect(x: 0, y: (874 - 402 * 9.0 / 16) / 2, width: 402, height: 402 * 9.0 / 16)))
        // A frame of the guest's own shape is the picture; a frame offset in its parent keeps its origin.
        let same = CGRect(x: 10, y: 20, width: 960, height: 540)
        precondition(near(TouchMapping.pictureRect(guest: CGSize(width: 1920, height: 1080), in: same), same))
        // Zoomed: the frame is larger than the window and starts above and left of it.
        let zoomed = CGRect(x: -437, y: -201, width: 1748, height: 804)
        let zr = TouchMapping.pictureRect(guest: CGSize(width: 2248, height: 1144), in: zoomed)
        precondition(abs(zr.height - 804) < 1e-9 && abs(zr.midX - zoomed.midX) < 1e-9)
        precondition(pos(zr.midX, zr.midY, zr) == "16384,16384")
        let corner = TouchMapping.position(.zero, in: zr)
        precondition(corner.x > 0 && corner.y > 0 && corner.x < 16384 && corner.y < 16384)
        // The phone's own 1:1 view: a 2622 x 1206 guest shown at 874 x 402 points.
        let native = TouchMapping.pictureRect(guest: CGSize(width: 2622, height: 1206), in: CGRect(x: 0, y: 0, width: 874, height: 402))
        precondition(near(native, CGRect(x: 0, y: 0, width: 874, height: 402)))
        precondition(pos(1.0 / 3, 0, native) == "12,0") // one guest pixel is 12.5 units: finer than the panel

        // Corners and the centre.
        let r = CGRect(x: 100, y: 50, width: 800, height: 450)
        precondition(pos(100, 50, r) == "0,0")
        precondition(pos(900, 50, r) == "32767,0")
        precondition(pos(100, 500, r) == "0,32767")
        precondition(pos(900, 500, r) == "32767,32767")
        precondition(pos(500, 275, r) == "16384,16384")
        // A point outside: not a start, and clamped to the edge while it moves.
        precondition(TouchMapping.startsInside(CGPoint(x: 500, y: 275), r))
        precondition(TouchMapping.startsInside(CGPoint(x: 100, y: 500), r)) // the edge counts
        precondition(!TouchMapping.startsInside(CGPoint(x: 99, y: 275), r))
        precondition(!TouchMapping.startsInside(CGPoint(x: 500, y: 501), r))
        precondition(pos(50, 275, r) == "0,16384")
        precondition(pos(2000, -40, r) == "32767,0")
        // Nothing to map: an empty picture takes nothing, and an empty guest size gives the frame.
        precondition(!TouchMapping.startsInside(.zero, .zero) && pos(5, 5, .zero) == "0,0")
        precondition(TouchMapping.pictureRect(guest: .zero, in: r) == r)

        // A rotation in flight: the old landscape picture inside the new portrait frame, letterboxed.
        let turning = TouchMapping.pictureRect(guest: CGSize(width: 2248, height: 1144), in: CGRect(x: 0, y: 0, width: 402, height: 874))
        precondition(abs(turning.width - 402) < 1e-9 && turning.minY > 0 && abs(turning.midY - 437) < 1e-9)
        precondition(!TouchMapping.startsInside(CGPoint(x: 200, y: 10), turning))
        let mid = TouchMapping.position(CGPoint(x: 201, y: 437), in: turning)
        precondition(abs(mid.x - 16384) <= 1 && abs(mid.y - 16384) <= 1)
        // And after it: the portrait guest fills the portrait frame.
        let turned = TouchMapping.pictureRect(guest: CGSize(width: 1200, height: 2608), in: CGRect(x: 0, y: 0, width: 402, height: 874))
        precondition(abs(turned.width - 402) < 1e-9 && abs(turned.height - 874) < 1)

        // Slots: the lowest free one, reused after a lift, ten at most.
        var slots = TouchSlots<Int>()
        precondition(slots.take(100) == 0 && slots.take(101) == 1 && slots.take(102) == 2)
        precondition(slots.take(101) == nil) // already holds one
        precondition(slots.release(101) == 1 && slots.slot(101) == nil)
        precondition(slots.take(103) == 1) // the freed slot again
        for k in 104..<111 { precondition(slots.take(k) != nil) }
        precondition(slots.held.count == 10 && slots.take(999) == nil)
        precondition(slots.release(5000) == nil)
        precondition(slots.releaseAll() == Array(0..<10) && slots.isEmpty)
        precondition(slots.take(7) == 0)

        print("touch mapping: ok")
    }
}
