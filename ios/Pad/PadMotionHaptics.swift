import CoreHaptics
import UIKit

/// Plays PadMotionFeel for the first finger: a looped continuous event whose intensity follows the
/// feel ("texture"), or light taps at a distance of travel ("ticks").
final class PadMotionHaptics {
    var tuning: PadTuning.Motion {
        didSet {
            feel.tuning = tuning
            if tuning.textureSharpness != oldValue.textureSharpness { player = nil }
            if tuning.style != oldValue.style { stopTexture() }
        }
    }
    private(set) var feel: PadMotionFeel
    private var finger: Int?
    private var engine: CHHapticEngine?
    private var running = false
    private var player: CHHapticAdvancedPatternPlayer?
    private var playing = false
    private var sent = -1.0
    private var ticks: [String: UIImpactFeedbackGenerator] = [:]

    init(tuning: PadTuning.Motion) {
        self.tuning = tuning
        feel = PadMotionFeel(tuning: tuning)
    }

    var active: Bool { feel.active }

    func prepare() {
        switch tuning.style {
        case "texture": startEngine()
        case "ticks": tick().prepare()
        default: break
        }
    }

    func down(_ id: Int, x: Double, y: Double, t: Double) {
        guard finger == nil, tuning.style != "none" else { return }
        finger = id
        feel.begin(x: x, y: y, t: t)
        if tuning.style == "texture" { startTexture() } else { tick().prepare() }
    }

    func moved(_ id: Int, x: Double, y: Double, t: Double) {
        guard id == finger else { return }
        if let i = feel.sample(x: x, y: y, t: t), tuning.style == "ticks" {
            let g = tick()
            g.impactOccurred(intensity: CGFloat(min(i, 1)))
            g.prepare()
        }
        send()
    }

    func up(_ id: Int) {
        guard id == finger else { return }
        cancel()
    }

    /// The scene left, or the haptic level changed.
    func cancel() {
        finger = nil
        feel.end()
        stopTexture()
    }

    func step(now: Double) {
        guard feel.active else { return }
        feel.step(now: now)
        send()
    }

    private func tick() -> UIImpactFeedbackGenerator {
        if let g = ticks[tuning.tickStyle] { return g }
        let style: UIImpactFeedbackGenerator.FeedbackStyle = switch tuning.tickStyle {
        case "soft": .soft
        case "rigid": .rigid
        case "medium": .medium
        case "heavy": .heavy
        default: .light
        }
        let g = UIImpactFeedbackGenerator(style: style)
        ticks[tuning.tickStyle] = g
        return g
    }

    // MARK: Texture

    private func startEngine() {
        guard !running, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        if engine == nil {
            guard let e = try? CHHapticEngine() else { return }
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = true
            e.stoppedHandler = { [weak self] _ in DispatchQueue.main.async { self?.engineStopped() } }
            e.resetHandler = { [weak self] in DispatchQueue.main.async { self?.engineStopped() } }
            engine = e
        }
        do { try engine?.start(); running = true } catch { running = false }
    }

    private func engineStopped() {
        running = false
        playing = false
        player = nil
    }

    private func startTexture() {
        startEngine()
        guard running, let engine else { return }
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(tuning.textureSharpness)),
            ], relativeTime: 0, duration: 30)
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let p = try? engine.makeAdvancedPlayer(with: pattern) else { return }
            p.loopEnabled = true
            player = p
        }
        sent = -1
        send(force: 0)
        do { try player?.start(atTime: CHHapticTimeImmediate); playing = true } catch { playing = false }
    }

    private func stopTexture() {
        if playing { try? player?.stop(atTime: CHHapticTimeImmediate) }
        playing = false
        sent = -1
    }

    private func send(force: Double? = nil) {
        guard tuning.style == "texture", let player else { return }
        let v = force ?? feel.texture
        guard force != nil || abs(v - sent) >= 0.01 else { return }
        sent = v
        let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(min(max(v, 0), 1)), relativeTime: 0)
        try? player.sendParameters([p], atTime: CHHapticTimeImmediate)
    }
}
