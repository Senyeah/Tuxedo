import Foundation

/// A rectangle in points, so that the layout stays pure Swift.
struct PadRect: Equatable {
    var x, y, w, h: Double
    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var midX: Double { x + w / 2 }
    func contains(_ r: PadRect, slack: Double = 1e-9) -> Bool {
        r.minX >= minX - slack && r.maxX <= maxX + slack && r.minY >= minY - slack && r.maxY <= maxY + slack
    }
    func overlaps(_ r: PadRect) -> Bool { r.minX < maxX && r.maxX > minX && r.minY < maxY && r.maxY > minY }
    func offset(dy: Double) -> PadRect { PadRect(x: x, y: y + dy, w: w, h: h) }
}

/// Where the pad, its two keys and the tool pill go, and how they follow the keyboard.
/// The pad's rectangle never changes with the keyboard (the sensor map keeps one scale);
/// only its drawn lower edge and the keys move.
struct PadLayout: Equatable {
    struct Input: Equatable {
        var width: Double
        var height: Double
        var safeTop = 0.0, safeLeft = 0.0, safeBottom = 0.0, safeRight = 0.0
        var deviceCorner = 62.0
        /// Button Shapes or an accessibility text size: the keys show text and the row grows.
        var labels = false
    }

    /// The keyboard's cover from the bottom of the view, now and when it is fully up.
    struct Keyboard: Equatable {
        var cover = 0.0
        var fullCover = 0.0
        static let down = Keyboard()
    }

    var side = false
    /// The whole pad at rest: the touch view and the Metal view.
    var pad = PadRect(x: 0, y: 0, w: 0, h: 0)
    var radius = 0.0
    var rowHeight = 0.0
    var grooveY = 0.0
    var left = PadRect(x: 0, y: 0, w: 0, h: 0)
    var right = PadRect(x: 0, y: 0, w: 0, h: 0)
    var keyOuterRadius = 0.0
    var keyInnerRadius = 0.0
    var pillX = 0.0, pillY = 0.0

    // With the keyboard.
    var padBottom = 0.0
    var lowerRadius = 0.0
    var keysOpacity = 1.0
    /// How far the keys move down (+) or up (−) from rest.
    var keysShift = 0.0
    var keysTakeTouches = true
    var pillOpacity = 1.0
    /// The keyboard's cover as a share of its travel, 0 down, 1 up; 0 for a cover that keeps the keys.
    var progress = 0.0

    static func make(_ i: Input, keyboard k: Keyboard = .down, tuning t: PadTuning = PadTuning(), reduceMotion: Bool = false) -> PadLayout {
        var l = PadLayout()
        let m = t.layout.margin
        l.side = i.width > i.height
        let left = l.side ? max(i.safeLeft, m) : i.safeLeft + m
        let right = i.width - (l.side ? max(i.safeRight, m) : i.safeRight + m)
        let top = i.safeTop + m
        // At least the margin from the glass where nothing sits under the bottom edge.
        let bottom = i.height - i.safeBottom - max(t.layout.bottomGap, m - i.safeBottom)
        l.pad = PadRect(x: left, y: top, w: max(right - left, 0), h: max(bottom - top, 0))
        l.radius = max(t.layout.minPadRadius, i.deviceCorner - m)
        l.rowHeight = i.labels ? t.keys.rowHeightLabels : (l.side ? t.keys.rowHeightSide : t.keys.rowHeight)

        let inset = t.keys.inset, gap = t.keys.gap
        let rowY = l.pad.maxY - l.rowHeight
        let keyW = (l.pad.w - 2 * inset - gap) / 2
        l.grooveY = rowY
        l.left = PadRect(x: l.pad.x + inset, y: rowY + inset, w: keyW, h: l.rowHeight - 2 * inset)
        l.right = PadRect(x: l.pad.x + inset + keyW + gap, y: rowY + inset, w: keyW, h: l.rowHeight - 2 * inset)
        l.keyInnerRadius = t.keys.innerRadius
        l.keyOuterRadius = max(l.radius - inset, t.keys.innerRadius)
        l.pillX = i.width / 2
        l.pillY = i.safeTop + t.layout.pillCentre

        l.follow(k, height: i.height, tuning: t, reduceMotion: reduceMotion)
        return l
    }

    /// The keyboard rule. Everything is a function of the cover, so a keyboard that stops,
    /// turns back or is dragged down needs no more code.
    private mutating func follow(_ k: Keyboard, height: Double, tuning t: PadTuning, reduceMotion: Bool) {
        let kb = t.keyboard
        let c = max(k.cover, 0)
        let full = max(k.fullCover, c)
        let rest = pad.maxY
        padBottom = max(pad.y + kb.minPadHeight, min(rest, height - c - kb.gap))
        if full > kb.hideAbove {
            // A software keyboard: the keys go and the lower corners tighten.
            progress = full > 0 ? min(max(c / full, 0), 1) : 0
            lowerRadius = radius + (kb.cornerUp - radius) * progress
            let fade = min(progress / max(kb.keysGoneAt, 1e-6), 1)
            keysOpacity = 1 - fade
            keysShift = reduceMotion ? 0 : kb.keysDrop * fade
            keysTakeTouches = c <= 0
            pillOpacity = side ? 1 - fade : 1
        } else {
            // Only a short row (a hardware keyboard): the keys stay, above it.
            progress = 0
            lowerRadius = radius
            keysOpacity = 1
            keysShift = padBottom - rest
            keysTakeTouches = true
            pillOpacity = 1
        }
    }

    /// The keyboard's cover from a view's bottom, from where its keyboard layout guide's top is.
    /// A keyboard that is not docked covers nothing: the pad stays full.
    static func cover(guideTop: Double, viewHeight: Double, docked: Bool) -> Double {
        docked ? max(0, viewHeight - guideTop) : 0
    }

    var leftNow: PadRect { left.offset(dy: keysShift) }
    var rightNow: PadRect { right.offset(dy: keysShift) }
    var grooveNow: Double { grooveY + keysShift }
}
