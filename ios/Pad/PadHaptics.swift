import QuartzCore
import UIKit

/// The pad's haptics: UIFeedbackGenerator only, one generator for each style, the table in
/// PadTuning.Haptics. Nothing else makes a generator for one press.
final class PadHaptics {
    enum Level: String, CaseIterable, Codable {
        case all, clicksOnly, off
    }

    enum Event: String, CaseIterable {
        case touchDown, tap, rightTap, leftKeyDown, leftKeyUp, rightKeyDown, rightKeyUp, holdStart, holdEnd, reveal
    }

    var level: Level = .all
    var tuning: PadTuning.Haptics
    /// Each haptic that played, for the Lab's log and the reviewers' counts.
    var onFire: ((Event, String, Double) -> Void)?

    private var generators: [String: UIImpactFeedbackGenerator] = [:]
    private var last: CFTimeInterval = -1
    private var lastRank = 0

    init(tuning: PadTuning.Haptics) {
        self.tuning = tuning
        for (name, style) in [("soft", UIImpactFeedbackGenerator.FeedbackStyle.soft), ("rigid", .rigid),
                              ("heavy", .heavy), ("medium", .medium), ("light", .light)] {
            generators[name] = UIImpactFeedbackGenerator(style: style)
        }
    }

    /// When the pad appears, and at each touch-down before the haptic.
    func prepare() {
        guard level != .off else { return }
        for g in generators.values { g.prepare() }
    }

    private func entry(_ e: Event) -> PadTuning.Haptics.Event? {
        let t = tuning
        switch e {
        case .touchDown: return t.touchDown == "none" ? nil : .init(style: t.touchDown, intensity: t.touchDownIntensity)
        case .tap: return t.tap
        case .rightTap: return t.rightTap
        case .leftKeyDown: return t.leftKeyDown
        case .leftKeyUp: return t.leftKeyUp
        case .rightKeyDown: return t.rightKeyDown
        case .rightKeyUp: return t.rightKeyUp
        case .holdStart: return t.holdStart
        case .holdEnd: return t.holdEnd
        case .reveal: return t.reveal
        }
    }

    func fire(_ e: Event, now: CFTimeInterval = CACurrentMediaTime()) {
        guard level != .off, let x = entry(e) else { return }
        if e == .touchDown && level == .clicksOnly { return }
        // One haptic in each 50 ms, except a key's release (a press and its release are one click),
        // and a click after a lesser haptic: a quick tap must not lose its click to its touch-down tick.
        let release = e == .leftKeyUp || e == .rightKeyUp
        let rank = Self.rank(e)
        guard release || last < 0 || now - last >= tuning.minGap || rank > lastRank else { return }
        guard let g = generators[x.style] else { return }
        g.impactOccurred(intensity: CGFloat(min(max(x.intensity, 0), 1)))
        g.prepare()
        last = now
        lastRank = rank
        onFire?(e, x.style, x.intensity)
    }

    private static func rank(_ e: Event) -> Int {
        switch e {
        case .touchDown: return 0
        case .reveal: return 1
        case .holdStart, .holdEnd: return 2
        case .tap, .rightTap, .leftKeyDown, .rightKeyDown, .leftKeyUp, .rightKeyUp: return 3
        }
    }
}
