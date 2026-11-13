import CoreHaptics
import UIKit

/// Plays PadMotionFeel for the first finger: a looped continuous event whose intensity follows the
/// feel ("texture"), or light taps at a distance of travel ("ticks").
final class PadMotionHaptics {
    var tuning: PadTuning.Motion {
        didSet {
            feel.tuning = tuning
            if tuning.textureSharpness != oldValue.textureSharpness { stopTexture(); player = nil }
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
    /// One line for each stroke and each failure, for the Lab's log.
    var onLog: ((String) -> Void)?
    private var stroke = (accel: 0.0, texture: 0.0, ticks: 0, samples: 0)

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

    func down(_ id: Int, x: Double, y: Double, t: Double, now: Double) {
        guard finger == nil, tuning.style != "none" else { return }
        finger = id
        stroke = (0, 0, 0, 0)
        feel.begin(x: x, y: y, t: t, arrival: now)
        if tuning.style == "texture" { startTexture() } else { tick().prepare() }
    }

    func moved(_ id: Int, x: Double, y: Double, t: Double, now: Double) {
        guard id == finger else { return }
        stroke.samples += 1
        if let i = feel.sample(x: x, y: y, t: t, arrival: now), tuning.style == "ticks" {
            let g = tick()
            g.impactOccurred(intensity: CGFloat(min(i, 1)))
            g.prepare()
            stroke.ticks += 1
        }
        note()
        send()
    }

    func up(_ id: Int) {
        guard id == finger else { return }
        if stroke.samples > 0 {
            onLog?(String(format: "motion %@: %d samples, peak %.0f pt/s², texture peak %.2f, %d ticks, engine %@, player %@",
                          tuning.style, stroke.samples, stroke.accel, stroke.texture, stroke.ticks,
                          running ? "on" : "off", playing ? "playing" : "stopped"))
        }
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
        if let i = feel.step(now: now), tuning.style == "ticks" {
            let g = tick()
            g.impactOccurred(intensity: CGFloat(min(i, 1)))
            g.prepare()
            stroke.ticks += 1
        }
        note()
        send()
    }

    private func note() {
        stroke.accel = max(stroke.accel, feel.accel)
        stroke.texture = max(stroke.texture, feel.texture)
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
            guard let e = try? CHHapticEngine() else { onLog?("motion: no haptic engine"); return }
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = true
            e.stoppedHandler = { [weak self] reason in
                DispatchQueue.main.async { self?.onLog?("motion: engine stopped (\(reason.rawValue))"); self?.engineStopped() }
            }
            e.resetHandler = { [weak self] in DispatchQueue.main.async { self?.engineStopped() } }
            engine = e
        }
        do { try engine?.start(); running = true } catch { running = false; onLog?("motion: the haptic engine did not start: \(error)") }
    }

    private func engineStopped() {
        running = false
        playing = false
        player = nil
    }

    private func startTexture() {
        startEngine()
        guard running else { return }
        if startPlayer() { return }
        // An engine that shut itself down when idle: start it again, once.
        engineStopped()
        startEngine()
        if running, !startPlayer() { onLog?("motion: the texture did not start") }
    }

    /// send() sets the strength at once after the start, from 0 at a touch-down.
    private func startPlayer() -> Bool {
        guard let engine else { return false }
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(tuning.textureSharpness)),
            ], relativeTime: 0, duration: 30)
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let p = try? engine.makeAdvancedPlayer(with: pattern) else { return false }
            p.loopEnabled = true
            player = p
        }
        do {
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            onLog?("motion: the player did not start: \(error)")
            player = nil
            return false
        }
        playing = true
        sent = -1
        send()
        return true
    }

    private func stopTexture() {
        if playing { try? player?.stop(atTime: CHHapticTimeImmediate) }
        playing = false
        sent = -1
    }

    private func send() {
        guard tuning.style == "texture", playing, let player else { return }
        let v = min(max(feel.texture, 0), 1)
        guard sent < 0 || abs(v - sent) >= 0.01 else { return }
        let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(v), relativeTime: 0)
        do { try player.sendParameters([p], atTime: CHHapticTimeImmediate); sent = v } catch { sent = -1 }
    }
}
