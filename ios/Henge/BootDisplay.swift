import SwiftUI
import QuartzCore
import CoreGraphics

/// The Mac's screen, refreshed a few times a second: what its GPU draws once
/// macOS is up. Before that, the boot framebuffer, which only ever holds the
/// progress bar (a virtual Mac's firmware draws no logo into it), so the logo
/// over it is the app's own.
struct BootDisplay: View {
    let display: DisplayRouter
    let role: DisplayTargetSelection.Role
    /// The id this view's layer connects to the router under.
    var surface = UUID()
    /// A Linux guest has no Apple logo; its console shows over the screen while `showConsole` is set.
    var guest: GuestKind = .mac
    var console: ConsoleModel?
    var showConsole = false
    var typing: Binding<Bool> = .constant(false)

    @State private var image: CGImage?
    @State private var gpuLive = false
    @State private var stopped = false
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0

    var body: some View {
        ZStack {
            Color.black
            if !stopped {
                if !gpuLive && guest == .mac {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        if image.height > image.width {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 44))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 44))
                            .foregroundStyle(.white)
                    }
                }
                GPUScreen(display: display, role: role, surface: surface,
                          matchScreenColors: matchScreenColors, brightness: screenBrightness)
                    .allowsHitTesting(false)
            }
            if role == .external && guest == .linux && !gpuLive && !stopped {
                Text("Starting the machine…").font(.title2).foregroundStyle(.white.opacity(0.8))
            }
            if let console, showConsole { ConsoleView(model: console, typing: typing) }
        }
        .task {
            var generation = henge_vm_generation()
            // Keep watching the lifecycle after the GPU takes over. Removing
            // GPUScreen clears its last frame on both device and external screens.
            while !Task.isCancelled {
                let next = henge_vm_generation(), state = henge_vm_state()
                if next != generation {
                    generation = next
                    gpuLive = false
                    image = nil
                }
                if state == 2 || state == 3 {
                    stopped = true
                    image = nil
                    gpuLive = false
                } else {
                    stopped = false
                    if !gpuLive && henge_vm_gpu_frames() > 0 {
                        gpuLive = true
                        image = nil
                    }
                    if !gpuLive && guest == .mac { image = Self.snapshot() ?? image }
                }
                try? await Task.sleep(nanoseconds: gpuLive ? 250_000_000 : 100_000_000)
            }
        }
    }

    static func snapshot() -> CGImage? {
        nil // the Mac boot framebuffer is gone (L4 removes this)
    }
}

/// A layer the engine draws the Mac's frames into, with the GPU, without the main thread.
private struct GPUScreen: UIViewRepresentable {
    let display: DisplayRouter
    let role: DisplayTargetSelection.Role
    let surface: UUID
    let matchScreenColors: Bool
    let brightness: Double
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    final class Screen: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }

        private let id: UUID
        private let display: DisplayRouter
        private let role: DisplayTargetSelection.Role
        private var attached = false
        private var lastSize: CGSize = .zero

        init(display: DisplayRouter, role: DisplayTargetSelection.Role, surface: UUID) {
            self.id = surface
            self.display = display
            self.role = role
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            layer.contentsGravity = .resizeAspect
            layer.isOpaque = false
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attachIfReady() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfReady()
        }

        private func attachIfReady() {
            guard let window, bounds.width > 0, bounds.height > 0,
                  let metal = layer as? CAMetalLayer else { return }
            // UIKit leaves a CAMetalLayer view at scale 1; the drawable is capped by bounds x scale.
            let scale = window.screen.nativeScale
            if contentScaleFactor != scale {
                contentScaleFactor = scale
                if attached { display.refresh(id) }
            }
            if !attached {
                attached = true
                lastSize = bounds.size
                display.connect(id, layer: metal, role: role, screenPixels: role == .external ? externalPixels(window) : nil)
            } else if lastSize != bounds.size {
                lastSize = bounds.size
                display.refresh(id)
            }
        }

        /// The external screen's current mode: the guest sizes to it, and the monitor must not resample it again.
        private func externalPixels(_ window: UIWindow) -> CGSize {
            let screen = window.windowScene?.screen ?? window.screen
            screen.overscanCompensation = .none
            var size = screen.currentMode?.size ?? screen.nativeBounds.size
            if size.width < 1 || size.height < 1 { size = screen.nativeBounds.size } // zero mode would give a tiny guest
            let modes = screen.availableModes.map { "\(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: " ")
            HengeLog.log("display", "external screen \(Int(size.width))x\(Int(size.height)) px, modes \(modes), overscan insets \(screen.overscanCompensationInsets)")
            return size
        }

        func detach() {
            guard attached else { return }
            attached = false
            display.disconnect(id)
        }
    }

    private func setColorSpace(_ view: Screen) {
        let metalLayer = view.layer as! CAMetalLayer
        // The guest's display profile is sRGB, and the presenter writes sRGB
        // values. A nil colorspace skips matching on wide-gamut iPad screens.
        metalLayer.colorspace = matchScreenColors ? Self.srgb : nil
        view.alpha = CGFloat(min(max(brightness, 0.4), 1))
    }

    func makeUIView(context: Context) -> Screen {
        if ProcessInfo.processInfo.environment["HV_COLOR_PROBE"] != nil {
            // What the screen itself is, for the colour probe (the engine logs the layer and the frames).
            let s = UIScreen.main
            let gamut = s.traitCollection.displayGamut == .P3 ? "P3" : s.traitCollection.displayGamut == .SRGB ? "sRGB" : "unspecified"
            HengeLog.log("colorprobe", "colorprobe: v=1 src=swift event=screen gamut=\(gamut) scale=\(s.scale) nativeScale=\(s.nativeScale) "
                       + "bounds=\(Int(s.bounds.width))x\(Int(s.bounds.height)) maxEDR=\(s.potentialEDRHeadroom) currentEDR=\(s.currentEDRHeadroom) "
                       + "brightness=\(String(format: "%.2f", s.brightness)) refreshHz=\(s.maximumFramesPerSecond)")
        }
        let view = Screen(display: display, role: role, surface: surface)
        setColorSpace(view)
        return view
    }
    func updateUIView(_ view: Screen, context: Context) { setColorSpace(view) }
    static func dismantleUIView(_ view: Screen, coordinator: ()) { view.detach() }
}
