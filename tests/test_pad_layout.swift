import Foundation

// Where the pad and its keys go, and the keyboard rule (ios/Pad/PadLayout.swift).
@main
struct PadLayoutTests {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); failures += 1 }
    }

    static let upright = PadLayout.Input(width: 402, height: 874, safeTop: 62, safeLeft: 0, safeBottom: 34, safeRight: 0)
    static let sideLeft = PadLayout.Input(width: 874, height: 402, safeTop: 0, safeLeft: 62, safeBottom: 21, safeRight: 62)
    static let sideRight = PadLayout.Input(width: 874, height: 402, safeTop: 0, safeLeft: 62, safeBottom: 21, safeRight: 62)
    static let small = PadLayout.Input(width: 320, height: 568, safeTop: 20, safeLeft: 0, safeBottom: 0, safeRight: 0, deviceCorner: 0)
    static let iPad = PadLayout.Input(width: 1376, height: 1032, safeTop: 0, safeLeft: 0, safeBottom: 20, safeRight: 0, deviceCorner: 18)

    static func safeRect(_ i: PadLayout.Input) -> PadRect {
        PadRect(x: i.safeLeft, y: i.safeTop, w: i.width - i.safeLeft - i.safeRight, h: i.height - i.safeTop - i.safeBottom)
    }

    static func rectangles(_ name: String, _ i: PadLayout.Input) {
        for labels in [false, true] {
            var input = i
            input.labels = labels
            let l = PadLayout.make(input)
            let n = "\(name)\(labels ? " with labels" : "")"
            check(safeRect(input).contains(l.pad), "\(n): the pad is in the safe area")
            for (k, key) in [("left", l.left), ("right", l.right)] {
                check(key.w >= 44 && key.h >= 44, "\(n): the \(k) key is \(key.w) × \(key.h), under 44 pt")
                check(l.pad.contains(key), "\(n): the \(k) key is inside the pad's outline")
            }
            check(!l.left.overlaps(l.right), "\(n): the keys overlap")
            check(l.left.maxX <= l.right.minX, "\(n): left is on the left")
            let surface = PadRect(x: l.pad.x, y: l.pad.y, w: l.pad.w, h: l.grooveY - l.pad.y)
            check(!surface.overlaps(l.left) && !surface.overlaps(l.right), "\(n): the pad surface and the keys overlap")
            check(abs((l.pad.minX - input.safeLeft) - (input.width - input.safeRight - l.pad.maxX)) < 1e-9, "\(n): the side margins differ")
            check(l.pillY > l.pad.minY && l.pillY < l.grooveY, "\(n): the pill is on the pad, above the keys")
        }
    }

    static func main() {
        // The plan's numbers, upright on a 402 × 874 pt phone.
        do {
            let l = PadLayout.make(upright)
            check(!l.side, "upright is not on its side")
            check(l.pad == PadRect(x: 8, y: 70, w: 386, h: 874 - 34 - 4 - 70), "upright pad: \(l.pad)")
            check(l.radius == 54, "the outer corner is 62 − 8")
            check(l.left.w == 181 && l.left.h == 64, "upright key is 181 × 64: \(l.left)")
            check(l.left.minX == l.pad.minX + 8 && l.left.maxY == l.pad.maxY - 8 && l.right.maxX == l.pad.maxX - 8,
                  "the keys are 8 pt in from the pad's sides and bottom: \(l.left), \(l.right)")
            check(l.right.minX - l.left.maxX == 8, "the gap between the keys is the inset")
            check(l.keyOuterRadius == 46, "a key's outer corner is the pad's, less the inset")
            check(l.pad.maxY == 874 - 38, "the key row ends 38 pt from the glass")
            check(l.pillY == 62 + 33, "the pill's centre is at the safe top + 33")
        }
        do {
            let l = PadLayout.make(sideLeft)
            check(l.side, "on its side")
            check(l.pad.minX == 62 && l.pad.maxX == 874 - 62, "on its side the pad is at the safe insets")
            check(l.pad.minY == 8 && l.pad.maxY == 402 - 25, "on its side: 8 pt from the top, 25 pt from the glass")
            check(l.left.h == 52 && l.left.w >= 180, "on its side a key is at least 180 × 52: \(l.left)")
        }
        rectangles("upright", upright)
        rectangles("landscape left", sideLeft)
        rectangles("landscape right", sideRight)
        rectangles("small window", small)
        rectangles("iPad", iPad)
        check(PadLayout.make(small).radius == 14, "a square-cornered screen still gets a 14 pt corner")

        // The keyboard rule: the ends.
        let full = 392.0 // 336 pt of keyboard and the 56 pt key row
        do {
            let down = PadLayout.make(upright, keyboard: .init(cover: 0, fullCover: full))
            check(down.padBottom == down.pad.maxY && down.lowerRadius == 54 && down.keysOpacity == 1 && down.keysShift == 0,
                  "keyboard down: the pad is full and the keys show")
            check(down.keysTakeTouches, "keyboard down: the keys take touches")
            let up = PadLayout.make(upright, keyboard: .init(cover: full, fullCover: full))
            check(up.padBottom == 874 - full - 8, "keyboard up: the pad ends 8 pt above the keyboard: \(up.padBottom)")
            check(up.lowerRadius == 20, "keyboard up: the lower corners are 20 pt")
            check(up.keysOpacity == 0 && up.keysShift == 12, "keyboard up: the keys are gone, 12 pt down")
            check(!up.keysTakeTouches, "keyboard up: the keys take no touches")
            check(up.pillOpacity == 1, "upright, the pill stays with the keyboard up")
            check(up.pad == down.pad, "the pad's rectangle does not change with the keyboard")
            let side = PadLayout.make(sideLeft, keyboard: .init(cover: 266, fullCover: 266))
            check(side.pillOpacity == 0, "on its side the pill goes with the keyboard up")
            check(side.padBottom - side.pad.minY >= 96, "on its side the pad above the keyboard is at least 96 pt")
            let rm = PadLayout.make(upright, keyboard: .init(cover: full, fullCover: full), reduceMotion: true)
            check(rm.keysShift == 0 && rm.keysOpacity == 0, "Reduce Motion: the keys fade in place")
        }
        // The keys are gone from p = 0.6, and they take touches only at p = 0.
        do {
            for p in stride(from: 0.6, through: 1.0, by: 0.05) {
                check(PadLayout.make(upright, keyboard: .init(cover: p * full, fullCover: full)).keysOpacity == 0, "keys show at p \(p)")
            }
            let early = PadLayout.make(upright, keyboard: .init(cover: 1, fullCover: full))
            check(!early.keysTakeTouches, "a keyboard on its way takes the keys' touches away")
            check(early.keysOpacity > 0.99, "at the start the keys are still there")
        }
        // Each value moves one way only as the keyboard comes up.
        do {
            var last = PadLayout.make(upright, keyboard: .init(cover: 0, fullCover: full))
            var c = 0.0
            while c <= full {
                let l = PadLayout.make(upright, keyboard: .init(cover: c, fullCover: full))
                check(l.padBottom <= last.padBottom && l.lowerRadius <= last.lowerRadius && l.keysOpacity <= last.keysOpacity
                      && l.keysShift >= last.keysShift && l.pillOpacity <= last.pillOpacity, "a value turns back at cover \(c)")
                check(l.padBottom - l.pad.minY >= 96, "the pad is under 96 pt at cover \(c)")
                last = l
                c += 0.5
            }
        }
        // A 56 pt row (a hardware keyboard) keeps the keys, above the row.
        do {
            let row = 56.0 + 34
            let l = PadLayout.make(upright, keyboard: .init(cover: row, fullCover: row))
            check(l.keysOpacity == 1 && l.keysTakeTouches, "the row only: the keys stay")
            check(l.leftNow.maxY <= 874 - row - 8 + 1e-9, "the row only: the keys sit above the row: \(l.leftNow)")
            check(l.padBottom == 874 - row - 8, "the row only: the pad ends above the row")
            check(l.lowerRadius == 54, "the row only: the corners do not change")
        }
        // A keyboard that is not docked covers nothing.
        do {
            check(PadLayout.cover(guideTop: 500, viewHeight: 874, docked: false) == 0, "an undocked keyboard covers nothing")
            check(PadLayout.cover(guideTop: 482, viewHeight: 874, docked: true) == 392, "a docked keyboard covers to its top")
            check(PadLayout.cover(guideTop: 900, viewHeight: 874, docked: true) == 0, "a keyboard below the view covers nothing")
            let l = PadLayout.make(iPad, keyboard: .init(cover: 0, fullCover: 0))
            check(l.padBottom == l.pad.maxY && l.keysOpacity == 1, "iPad, floating keyboard: the pad stays full")
        }
        // Rotation with the keyboard up: p stays 1 and the keys stay hidden.
        do {
            let a = PadLayout.make(upright, keyboard: .init(cover: full, fullCover: full))
            let b = PadLayout.make(sideLeft, keyboard: .init(cover: 266, fullCover: 266))
            check(a.progress == 1 && b.progress == 1 && b.keysOpacity == 0, "rotation keeps the keys hidden")
        }

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("test_pad_layout: all passed")
    }
}
