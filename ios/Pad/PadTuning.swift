import Foundation

/// Every number of the pad's look and haptics, in one place (docs/external-trackpad-plan.md).
/// Trackpad Lab changes them live and exports them; Henge uses the defaults.
/// Sizes are in points, times in seconds, alphas and energies from 0 to 1, colours sRGB hex.
struct PadTuning: Codable, Equatable {
    var grid = Grid()
    var grain = Grain()
    var light = Light()
    var trail = Trail()
    var colour = Colours()
    var ripple = Ripple()
    var ghost = Ghost()
    var keys = Keys()
    var layout = Layout()
    var keyboard = Keyboard()
    var contrast = Contrast()
    var frame = Frame()
    var haptics = Haptics()
    var motion = Motion()

    struct Grid: Codable, Equatable {
        var pitch = 5.0
        var idleRadius = 0.5
        var radiusGain = 1.4
        var radiusExponent = 0.6
        var idleAlpha = 0.07
        var alphaExponent = 0.8
        var edgePixels = 1.0
    }

    struct Grain: Codable, Equatable {
        var radiusJitter = 0.08
        var alphaJitter = 0.12
        var baseNoise = 0.015
    }

    struct Light: Codable, Equatable {
        var baseCentre = "#0B0C10"
        var baseEdge = "#050608"
        var page = "#000000"
        var vignetteStart = 0.55
        var sheenTop = 0.035
        var sheenEnd = 0.40
        var edgeTop = 0.16
        var edgeBottom = 0.06
        var edgeWidth = 0.5
        var grooveDark = 0.60
        var grooveDarkWidth = 1.0
        var grooveLight = 0.06
        var grooveLightWidth = 0.5
        var bloom = 0.22
    }

    struct Trail: Codable, Equatable {
        var stampSpacing = 2.5
        var sigmaSlow = 9.0
        var sigmaDrop = 3.5
        var sigmaSpeed = 1500.0
        var peakBase = 0.80
        var peakGain = 0.20
        var peakSpeed = 600.0
        /// Low-pass on the head's speed, so noisy samples do not flicker the width.
        var headSmoothing = 0.05
        var haloSigma = 11.0
        var haloPeak = 0.55
        var haloRise = 0.03
        var coreTau = 0.07
        var tailTauNumerator = 60.0
        var tailTauMin = 0.045
        var tailTauMax = 0.22
        var speedSmoothing = 0.15
        /// A linear drain under the exponential decay, in energy per second: each dot is dark
        /// 1.0 s after its last stamp, which a pure exponential at τ 0.22 to 0.30 s is not.
        var drain = 0.15
        var multiFingerSigma = 0.8
        var dragSigma = 1.25
        var dragTauMax = 0.30
        var dragChange = 0.12
        var dragRingRadius = 14.0
        var dragRingWidth = 2.5
        var dragRingPeak = 0.45
    }

    struct Colours: Codable, Equatable {
        var idle = "#FFFFFF"
        var core = "#F4F8FF"
        /// A move's trail at energy 1, 0.5 and 0.05: blue, as a drag's. A drag differs by its tail and ring.
        var move1 = "#C9DCFF"
        var move05 = "#7FA8FF"
        var move005 = "#3D6FE0"
        /// A drag's trail.
        var drag1 = "#C9DCFF"
        var drag05 = "#7FA8FF"
        var drag005 = "#3D6FE0"
        /// How far toward drag005 a drag's fade ends, on the idle dot.
        var dragIdleMix = 0.30
        var keyTint = "#5B8DFF"
    }

    struct Ripple: Codable, Equatable {
        var radius = 56.0
        var duration = 0.28
        var width = 10.0
        var peak = 0.9
        /// A Gaussian profile across the ring's width, against a plain band.
        var gaussian = 0.0
        var flash = 0.12
    }

    struct Ghost: Codable, Equatable {
        var delay = 0.6
        var duration = 1.2
        var radius = 70.0
        var sweep = 2.4
        var sessions = 3.0
    }

    struct Keys: Codable, Equatable {
        var rowHeight = 64.0
        var rowHeightSide = 52.0
        var rowHeightLabels = 76.0
        var inset = 0.0
        var gap = 8.0
        var innerRadius = 14.0
        var fill = 0.05
        var topEdge = 0.12
        var pressedFill = 0.14
        var pressedTint = 0.08
        var pressedEnergy = 0.3
        var pressedShadow = 0.40
        var attack = 0.06
        var release = 0.18
        /// s a tap-to-click lights its key, as a press of the key does. 0: no light.
        var tapFlash = 0.12
        var symbolSize = 22.0
        var symbolAlpha = 0.60
        var leftSymbol = "cursorarrow.click"
        var rightSymbol = "cursorarrow.click.2"
    }

    struct Layout: Codable, Equatable {
        var margin = 8.0
        var bottomGap = 4.0
        var pillCentre = 33.0
        var minPadRadius = 14.0
        /// 0 is a circular corner, 1 a continuous one, as the system draws.
        var cornerSmoothing = 1.0
    }

    struct Keyboard: Codable, Equatable {
        var gap = 8.0
        var cornerUp = 20.0
        var keysGoneAt = 0.6
        var keysDrop = 12.0
        var hideAbove = 120.0
        var minPadHeight = 96.0
    }

    struct Contrast: Codable, Equatable {
        var idleAlpha = 0.14
        var symbolAlpha = 1.0
        var keyFill = 0.10
        var lineWidth = 1.0
        var lineAlpha = 0.30
    }

    struct Frame: Codable, Equatable {
        var fingerMinHz = 80.0
        var fingerHz = 120.0
        var decayHz = 60.0
        /// Below this a dot counts as dark and the display link may stop.
        var dark = 1.0 / 255
    }

    struct Haptics: Codable, Equatable {
        /// What a first finger gives: "soft", "light", "rigid" (a tick of that style), "none".
        var touchDown = "soft"
        var touchDownIntensity = 0.35
        /// The keys and tap-to-click are the strongest, and a tap feels as its key does. Left feels as right.
        var tap = Event(style: "heavy", intensity: 1.0)
        var rightTap = Event(style: "heavy", intensity: 1.0)
        var leftKeyDown = Event(style: "heavy", intensity: 1.0)
        var leftKeyUp = Event(style: "heavy", intensity: 0.40)
        var rightKeyDown = Event(style: "heavy", intensity: 1.0)
        var rightKeyUp = Event(style: "heavy", intensity: 0.40)
        var holdStart = Event(style: "medium", intensity: 0.8)
        var holdEnd = Event(style: "light", intensity: 0.5)
        var reveal = Event(style: "light", intensity: 0.6)
        var minGap = 0.05

        struct Event: Codable, Equatable {
            var style: String
            var intensity: Double
        }
    }

    /// A haptic for every finger move, as strong as the finger's acceleration (faster or slower).
    struct Motion: Codable, Equatable {
        /// "texture" (a continuous Core Haptics event), "ticks" (taps at a distance of travel), "none".
        var style = "texture"
        var velocitySmoothing = 0.02     // s
        var accelSmoothing = 0.04        // s
        /// pt/s². Below floor nothing plays; above it the haptic starts at its minimum, and at full it is at its gain.
        var floor = 1500.0
        var full = 20000.0
        /// s with no sample: the finger is still, so its speed falls to zero.
        var still = 0.03
        /// The weakest motion haptic, and the strongest. Set on the phone: half of the first, felt values.
        var textureMin = 0.15
        var textureGain = 0.45
        var textureSharpness = 0.5
        var tickStyle = "rigid"
        var tickGain = 0.5
        var tickSpacing = 6.0            // pt
        var tickGap = 0.03               // s; the Taptic Engine cannot play much faster
        var tickMin = 0.175
    }
}

extension PadTuning {
    /// A tuning file over the defaults: keys the file lacks keep their default, so an old file still loads.
    static func load(_ data: Data) throws -> PadTuning {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PadTuning())) as? [String: Any] ?? [:]
        let over = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let merged = try JSONSerialization.data(withJSONObject: merge(base, over))
        return try JSONDecoder().decode(PadTuning.self, from: merged)
    }

    func export() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    private static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b {
            if let x = a[k] as? [String: Any], let y = v as? [String: Any] { out[k] = merge(x, y) } else if a[k] != nil { out[k] = v }
        }
        return out
    }

    /// "#RRGGBB" as sRGB components from 0 to 1. A bad string is magenta, so it shows.
    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (1, 0, 1) }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}
