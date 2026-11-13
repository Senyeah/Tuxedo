import Metal
import QuartzCore
import UIKit

/// What the view asks of its owner before each frame.
protocol PadSurfaceHost: AnyObject {
    /// Update the layout, the keys and the drag state for `now`. Return true to keep frames
    /// coming for a reason the field does not know (a key or the keyboard moving).
    func padWillStep(_ surface: PadSurfaceView, at now: CFTimeInterval) -> Bool
}

/// Frame costs, for the Lab and the budget.
struct PadFrameStats {
    var frames = 0
    /// Frames drawn with nothing lit and nothing moving: the budget is 0.
    var restFrames = 0
    var cpu: [Double] = []   // ms, the main thread's part of a frame
    var gpu: [Double] = []   // ms, from the command buffer's GPU times
    var touch: [Double] = [] // µs, the visual part of a touch handler

    mutating func add(_ v: Double, to a: WritableKeyPath<PadFrameStats, [Double]>) {
        self[keyPath: a].append(v)
        if self[keyPath: a].count > 2000 { self[keyPath: a].removeFirst(self[keyPath: a].count - 2000) }
    }

    static func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
    static func p95(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(Double(a.count) * 0.95))] }
}

/// The pad: one CAMetalLayer, one full-screen triangle, one fragment pass. The display link runs
/// only while something is lit or moving; at rest the view draws nothing.
final class PadSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    weak var host: PadSurfaceHost?
    var field: PadField
    var tuning: PadTuning { didSet { field.tuning = tuning; setNeedsFrame() } }
    var geometry = PadLayout() { didSet { if geometry != oldValue { setNeedsFrame() } } }
    var keyPress: (Double, Double) = (0, 0)
    var increaseContrast = false { didSet { if increaseContrast != oldValue { setNeedsFrame() } } }
    /// Present inside Core Animation's transaction, so the pad's edge and the keyboard move in the same frame.
    var syncWithCoreAnimation = false
    /// A script's clock in place of the display link's.
    var clockOverride: (() -> CFTimeInterval)?
    /// A recorded still: frames redraw the layout but the field no longer steps.
    var frozen = false
    private(set) var stats = PadFrameStats()
    private(set) var running = false

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textures: [MTLTexture] = []
    private var textureIndex = 0
    private var noise: MTLTexture?
    private var sampler: MTLSamplerState?
    private var bytes: [UInt8] = []
    private let inFlight = DispatchSemaphore(value: 3)
    private var link: CADisplayLink?
    private var gridKey = PadRect(x: 0, y: 0, w: 0, h: 0)
    private var lastFingers = false
    private var clock: CFTimeInterval = 0
    private var needFrame = false

    init(tuning: PadTuning) {
        self.tuning = tuning
        field = PadField(tuning: tuning)
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .black
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        build()
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    // MARK: Setup

    private func build() {
        guard let device else { return }
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "padVertex")
            d.fragmentFunction = lib.makeFunction(name: "padFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("pad shader: \(error)")
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToZero
        s.tAddressMode = .clampToZero
        sampler = device.makeSamplerState(descriptor: s)
        let n = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 64, height: 64, mipmapped: false)
        n.usage = .shaderRead
        noise = device.makeTexture(descriptor: n)
        let tile = Self.blueNoise
        tile.withUnsafeBytes { noise?.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != size, size.width > 0 { metalLayer.drawableSize = size }
        regrid()
        setNeedsFrame()
    }

    /// A new pad rectangle lays a new grid. The trail is lost; a rotation is a new start.
    private func regrid() {
        guard let device else { return }
        let r = geometry.pad
        guard r != gridKey, r.w > 0, r.h > 0 else { return }
        gridKey = r
        field.resize(x: r.x, y: r.y, width: r.w, height: r.h, scale: Double(metalLayer.contentsScale))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: field.cols, height: field.rows, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
        bytes = [UInt8](repeating: 0, count: field.cols * field.rows * 4)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { setNeedsLayout(); setNeedsFrame() }
    }

    // MARK: Clock

    /// Draw at least one more frame: input arrived, or the layout or the tuning changed.
    func setNeedsFrame() {
        needFrame = true
        guard window != nil, !running else { return }
        running = true
        let l = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        l.preferredFrameRateRange = rateRange(fingers: field.fingersDown > 0)
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// The scene is not active: no frames.
    func stop() {
        link?.invalidate()
        link = nil
        running = false
    }

    private func rateRange(fingers: Bool) -> CAFrameRateRange {
        let f = tuning.frame
        return fingers
            ? CAFrameRateRange(minimum: Float(f.fingerMinHz), maximum: Float(f.fingerHz), preferred: Float(f.fingerHz))
            : CAFrameRateRange(minimum: Float(f.decayHz), maximum: Float(f.decayHz), preferred: Float(f.decayHz))
    }

    private final class LinkTarget {
        weak var view: PadSurfaceView?
        init(_ v: PadSurfaceView) { view = v }
        @objc func tick(_ l: CADisplayLink) {
            guard let view else { l.invalidate(); return }
            view.frameTick(l)
        }
    }

    private func frameTick(_ l: CADisplayLink) {
        let start = CACurrentMediaTime()
        clock = clockOverride?() ?? l.targetTimestamp
        let wasLit = field.isLit
        let hostWants = host?.padWillStep(self, at: clock) ?? false
        regrid()
        if !frozen { field.step(to: clock) }
        let asked = needFrame
        needFrame = false
        let lit = field.isLit
        if !wasLit && !lit && !hostWants && !asked { stats.restFrames += 1 }
        draw()
        stats.add((CACurrentMediaTime() - start) * 1000, to: \.cpu)
        let fingers = field.fingersDown > 0
        if fingers != lastFingers { l.preferredFrameRateRange = rateRange(fingers: fingers); lastFingers = fingers }
        if frozen ? !hostWants : (!lit && !hostWants && !needFrame) { stop() }
    }

    /// Steps the model to `time` with no display link and draws once: for recorded frames.
    func render(at time: CFTimeInterval) {
        clock = time
        _ = host?.padWillStep(self, at: time)
        regrid()
        field.step(to: time)
        draw()
    }

    /// The visual part of a touch handler: one append.
    func add(_ s: PadField.Sample) {
        let t0 = CACurrentMediaTime()
        field.add(s)
        setNeedsFrame()
        stats.add((CACurrentMediaTime() - t0) * 1e6, to: \.touch)
    }

    func resetStats() { stats = PadFrameStats() }

    // MARK: Draw

    private func draw() {
        guard let pipeline, let queue, !textures.isEmpty, let drawable = metalLayer.nextDrawable() else { return }
        guard inFlight.wait(timeout: .now() + .milliseconds(50)) == .success else { return }
        textureIndex = (textureIndex + 1) % textures.count
        let tex = textures[textureIndex]
        bytes.withUnsafeMutableBufferPointer { b in
            field.encode(into: b.baseAddress!)
            tex.replace(region: MTLRegionMake2D(0, 0, field.cols, field.rows), mipmapLevel: 0, withBytes: b.baseAddress!, bytesPerRow: field.cols * 4)
        }
        var u = uniforms()
        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * u.count, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentTexture(noise, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let sem = inFlight
        cb.addCompletedHandler { [weak self] b in
            sem.signal()
            let g = (b.gpuEndTime - b.gpuStartTime) * 1000
            if g > 0 { DispatchQueue.main.async { self?.stats.add(g, to: \.gpu) } }
        }
        stats.frames += 1
        if syncWithCoreAnimation {
            metalLayer.presentsWithTransaction = true
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            metalLayer.presentsWithTransaction = false
            cb.present(drawable)
            cb.commit()
        }
    }

    private func uniforms() -> [SIMD4<Float>] {
        let t = tuning, g = geometry
        func v(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> SIMD4<Float> { SIMD4(Float(a), Float(b), Float(c), Float(d)) }
        func r(_ x: PadRect) -> SIMD4<Float> { v(x.x, x.y, x.w, x.h) }
        func c(_ hex: String, _ w: Double = 0) -> SIMD4<Float> { let k = PadTuning.rgb(hex); return v(k.0, k.1, k.2, w) }
        let hc = increaseContrast
        return [
            v(Double(bounds.width), Double(bounds.height), Double(metalLayer.contentsScale), t.grid.pitch),          // 0
            v(field.originX, field.originY, Double(field.cols), Double(field.rows)),                                // 1
            r(g.pad),                                                                                               // 2
            v(g.padBottom, g.radius, g.lowerRadius, g.keysOpacity),                                                 // 3
            r(g.leftNow), r(g.rightNow),                                                                            // 4, 5
            v(g.keyOuterRadius, g.keyInnerRadius, g.grooveNow, keyPress.0),                                         // 6
            v(keyPress.1, t.keys.pressedEnergy, hc ? t.contrast.keyFill : t.keys.fill, t.keys.topEdge),             // 7
            v(t.keys.pressedFill, t.keys.pressedTint, t.keys.pressedShadow, hc ? 1 : 0),                            // 8
            v(t.grid.idleRadius, t.grid.radiusGain, t.grid.radiusExponent, hc ? t.contrast.idleAlpha : t.grid.idleAlpha), // 9
            v(t.grid.alphaExponent, t.grid.edgePixels, t.grain.radiusJitter, t.grain.alphaJitter),                  // 10
            v(t.grain.baseNoise, t.light.vignetteStart, t.light.sheenTop, t.light.sheenEnd),                        // 11
            v(t.light.edgeTop, t.light.edgeBottom, hc ? t.contrast.lineWidth : t.light.edgeWidth, t.light.bloom),   // 12
            v(t.light.grooveDark, t.light.grooveDarkWidth, t.light.grooveLight, t.light.grooveLightWidth),          // 13
            c(t.light.baseCentre, t.colour.dragIdleMix),                                                            // 14
            c(t.light.baseEdge, t.contrast.lineAlpha),                                                              // 15
            c(t.colour.idle, t.layout.cornerSmoothing),                                                             // 16
            c(t.colour.core, t.contrast.lineWidth),                                                                 // 17
            c(t.colour.move1), c(t.colour.move05), c(t.colour.move005),                                             // 18-20
            c(t.colour.drag1), c(t.colour.drag05), c(t.colour.drag005),                                             // 21-23
            c(t.colour.keyTint), c(t.light.page),                                                                   // 24, 25
        ]
    }

    // MARK: Blue noise

    /// A 64 × 64 tile by void and cluster (rank by largest void), made once.
    static let blueNoise: [UInt8] = {
        let n = 64, count = n * n
        var energy = [Double](repeating: 0, count: count)
        var rank = [Int](repeating: -1, count: count)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            energy[i] = Double(seed >> 40) / Double(1 << 24) * 1e-6
        }
        let sigma = 1.9, reach = 6
        var kernel = [Double](repeating: 0, count: (2 * reach + 1) * (2 * reach + 1))
        for dy in -reach...reach { for dx in -reach...reach {
            kernel[(dy + reach) * (2 * reach + 1) + dx + reach] = exp(-Double(dx * dx + dy * dy) / (2 * sigma * sigma))
        } }
        for k in 0..<count {
            var best = -1
            var bestE = Double.infinity
            for i in 0..<count where rank[i] < 0 && energy[i] < bestE { bestE = energy[i]; best = i }
            rank[best] = k
            let bx = best % n, by = best / n
            for dy in -reach...reach { for dx in -reach...reach {
                let x = (bx + dx + n) % n, y = (by + dy + n) % n
                energy[y * n + x] += kernel[(dy + reach) * (2 * reach + 1) + dx + reach]
            } }
        }
        return rank.map { UInt8((Double($0) + 0.5) / Double(count) * 255) }
    }()

    // MARK: Shader

    /// Compiled at first use from source, as the guest's renderers are. The colour maths must match PadLook.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; };

    vertex VOut padVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    // A rounded box with a radius for each corner (tl, tr, br, bl), y down. s mixes the circular
    // corner toward a continuous one (a superellipse that starts earlier).
    static float roundBox(float2 p, float2 half_, float4 rad, float s) {
        float r = p.x < 0.0 ? (p.y < 0.0 ? rad.x : rad.w) : (p.y < 0.0 ? rad.y : rad.z);
        r = min(r * (1.0 + 0.25 * s), min(half_.x, half_.y));
        float2 q = abs(p) - half_ + r;
        float2 m = max(q, 0.0);
        float n = 2.0 + 0.8 * s;
        float len = pow(pow(m.x, n) + pow(m.y, n), 1.0 / n);
        return min(max(q.x, q.y), 0.0) + len - r;
    }

    // How much of a pixel (size w) the interval [a, b] covers.
    static float span(float x, float w, float a, float b) {
        return clamp((min(b, x + 0.5 * w) - max(a, x - 0.5 * w)) / w, 0.0, 1.0);
    }

    static float hash(uint2 c, uint k) {
        uint h = c.x * 73856093u ^ c.y * 19349663u ^ k * 83492791u;
        h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
        return float(h & 0xFFFFu) / 32767.5 - 1.0;
    }

    static float3 ramp(float e, float3 s1, float3 s05, float3 s005, float3 s0) {
        if (e >= 0.5) return mix(s05, s1, min((e - 0.5) / 0.5, 1.0));
        if (e >= 0.05) return mix(s005, s05, (e - 0.05) / 0.45);
        return mix(s0, s005, max(e, 0.0) / 0.05);
    }

    static float3 tailColour(float e, float grab, constant float4 *u) {
        float3 idle = u[16].rgb;
        float3 mv = ramp(e, u[18].rgb, u[19].rgb, u[20].rgb, idle);
        float3 dg = ramp(e, u[21].rgb, u[22].rgb, u[23].rgb, mix(idle, u[23].rgb, u[14].w));
        return mix(mv, dg, grab);
    }

    fragment float4 padFragment(VOut in [[stage_in]], constant float4 *u [[buffer(0)]],
                                texture2d<float> field [[texture(0)]], texture2d<float> noise [[texture(1)]],
                                sampler lin [[sampler(0)]]) {
        float scale = u[0].z;
        float px = 1.0 / scale;
        float2 p = in.pos.xy / scale;
        float3 page = u[25].rgb;
        bool hc = u[8].w > 0.5;
        float smooth_ = u[16].w;

        float4 pad = u[2];
        float top = pad.y, bottom = u[3].x;
        float2 centre = float2(pad.x + 0.5 * pad.z, 0.5 * (top + bottom));
        float2 half_ = float2(0.5 * pad.z, 0.5 * (bottom - top));
        float d = roundBox(p - centre, half_, float4(u[3].y, u[3].y, u[3].z, u[3].z), smooth_);
        float inside = clamp(0.5 - d * scale, 0.0, 1.0);
        if (inside <= 0.0) return float4(page, 1.0);

        // The base: a radial vignette, fixed blue noise, and the sheen from above.
        float2 fullCentre = pad.xy + 0.5 * pad.zw;
        float vig = smoothstep(u[11].y, 1.0, length(p - fullCentre) / (0.5 * length(pad.zw)));
        float3 col = mix(u[14].rgb, u[15].rgb, vig);
        float n = noise.read(uint2(in.pos.xy) % 64u).r;
        col += (n - 0.5) * 2.0 * u[11].x;
        col += u[11].z * (1.0 - clamp((p.y - top) / (u[11].w * pad.w), 0.0, 1.0));

        // The keys: raised areas, pressed ones lit and pushed in.
        float ko = u[3].w;
        float outer = u[6].x, inner = u[6].y;
        float press[2] = { u[6].w, u[7].x };
        float4 rects[2] = { u[4], u[5] };
        float4 radii[2] = { float4(inner, inner, inner, outer), float4(inner, inner, outer, inner) };
        for (int k = 0; k < 2; k++) {
            float4 kr = rects[k];
            float dk = roundBox(p - (kr.xy + 0.5 * kr.zw), 0.5 * kr.zw, radii[k], smooth_);
            float cov = clamp(0.5 - dk * scale, 0.0, 1.0) * ko;
            if (cov <= 0.0) continue;
            float pr = press[k];
            float fill = mix(u[7].z, u[8].x, pr);
            col = mix(col, float3(1.0), fill * cov);
            col = mix(col, u[24].rgb, u[8].y * pr * cov);
            float topness = 1.0 - clamp((p.y - kr.y) / max(inner, 1.0), 0.0, 1.0);
            float band = span(dk, px, -0.5, 0.0);
            col = mix(col, float3(1.0), u[7].w * (1.0 - pr) * band * topness * ko);
            float shadow = clamp(1.0 + dk, 0.0, 1.0) * topness * pr;
            col = mix(col, float3(0.0), u[8].z * shadow * cov);
        }

        // The grooves: under the pad, and between the keys. Light from above lights the lower lip.
        float gy = u[6].z;
        float gx = 0.5 * (u[4].x + u[4].z + u[5].x);
        if (hc) {
            float w = u[17].w;
            float line_ = max(span(p.y, px, gy - 0.5 * w, gy + 0.5 * w),
                              span(p.x, px, gx - 0.5 * w, gx + 0.5 * w) * step(gy, p.y));
            col = mix(col, float3(1.0), u[15].w * line_ * ko);
        } else {
            float dw = u[13].y, lw = u[13].w;
            float dark = max(span(p.y, px, gy - 0.5 * dw, gy + 0.5 * dw),
                             span(p.x, px, gx - 0.5 * dw, gx + 0.5 * dw) * step(gy, p.y));
            col = mix(col, float3(0.0), u[13].x * dark * ko);
            float light = span(p.y, px, gy + 0.5 * dw, gy + 0.5 * dw + lw);
            col = mix(col, float3(1.0), u[13].z * light * ko);
        }

        // The dots.
        float pitch = u[0].w;
        float2 dims = u[1].zw;
        float2 g = (p - u[1].xy) / pitch;
        float2 cell = round(g);
        float2 dc = u[1].xy + cell * pitch;
        float dd = length(p - dc);
        float4 s = (all(cell >= 0.0) && all(cell < dims)) ? field.read(uint2(cell)) : float4(0.0);
        float eC = max(s.r * s.r, s.a * s.a), eT = s.g * s.g, grab = s.b;
        for (int k = 0; k < 2; k++) {
            float4 kr = rects[k];
            if (press[k] > 0.0 && roundBox(dc - (kr.xy + 0.5 * kr.zw), 0.5 * kr.zw - 1.0, radii[k], smooth_) < 0.0)
                eC = max(eC, u[7].y * press[k] * ko);
        }
        float e = max(eC, eT);
        uint2 ci = uint2(int2(cell) + 4096);
        float rj = 1.0 + u[10].z * hash(ci, 1u), aj = 1.0 + u[10].w * hash(ci, 2u);
        float idleA = u[9].w;
        float soft = u[10].y * px;
        float rI = u[9].x * rj;
        col = mix(col, u[16].rgb, idleA * aj * clamp((rI - dd) / soft + 0.5, 0.0, 1.0));
        if (e > 0.0) {
            float rL = (u[9].x + u[9].y * pow(e, u[9].z)) * rj;
            float aL = (1.0 - idleA) * pow(e, u[10].x) * aj;
            float3 lit = mix(tailColour(eT, grab, u), u[17].rgb, clamp(eC, 0.0, 1.0));
            col += lit * aL * clamp((rL - dd) / soft + 0.5, 0.0, 1.0);
        }

        // The bloom: the grid itself, filtered, in the trail's colour.
        float4 b = field.sample(lin, (g + 0.5) / dims);
        float eb = max(max(b.r * b.r, b.a * b.a), b.g * b.g);
        col += tailColour(b.g * b.g, b.b, u) * u[12].w * eb;

        // The edge: a fine inner line, brighter at the top.
        float ew = u[12].z;
        float edge = span(d, px, -ew, 0.0);
        float ea = hc ? u[15].w : mix(u[12].x, u[12].y, clamp((p.y - top) / max(bottom - top, 1.0), 0.0, 1.0));
        col = mix(col, float3(1.0), ea * edge);

        col = mix(page, min(col, 1.0), inside);
        return float4(col, 1.0);
    }
    """
}
