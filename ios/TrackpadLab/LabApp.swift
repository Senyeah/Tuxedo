import SwiftUI
import UIKit

@main
struct LabApp: App {
    var body: some Scene {
        WindowGroup { LabRoot() }
    }
}

/// The Lab's state: the tuning, the settings the owner switches on the phone, the pointer and the pad.
final class LabModel: ObservableObject {
    @Published var tuning: PadTuning
    @Published var hapticLevel: PadHaptics.Level = .all { didSet { UserDefaults.standard.set(hapticLevel.rawValue, forKey: "labHaptics") } }
    @Published var inputMode: PadInputMode = .touchscreen { didSet { UserDefaults.standard.set(inputMode.rawValue, forKey: "labInputMode") } }
    @Published var full: Bool { didSet { UserDefaults.standard.set(full, forKey: "labFull") } }
    @Published var showLog = false
    @Published var showTuning = false
    @Published var log: [String] = []
    @Published var pill = CGPoint(x: -100, y: -100)
    @Published var pillOpacity = 1.0
    @Published var saved = ""

    let pointer = LabPointer()
    let keyboard = LabKeyboardView()
    private(set) lazy var buttons = PointerButtons { [weak self] b, down in
        self?.pointer.button(b, down)
        self?.note("\(b == 0 ? "left" : "right") \(down ? "down" : "up")")
    }
    private(set) lazy var surface = LabSurface(buttons: buttons)
    private(set) weak var host: PadHostView?
    let forced: PadAccessibility
    private(set) var demo: LabDemo?

    static var tuningURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pad-tuning.json")
    }

    init() {
        let d = UserDefaults.standard
        tuning = (try? Data(contentsOf: Self.tuningURL)).flatMap { try? PadTuning.load($0) } ?? PadTuning()
        full = d.string(forKey: "padLayout").map { $0 == "full" } ?? d.bool(forKey: "labFull")
        if let m = d.string(forKey: "labInputMode").flatMap(PadInputMode.init(rawValue:)) { inputMode = m }
        if let h = d.string(forKey: "labHaptics").flatMap(PadHaptics.Level.init(rawValue:)) { hapticLevel = h }
        showLog = d.bool(forKey: "labLog")
        func flag(_ k: String) -> Bool? { d.object(forKey: k) == nil ? nil : d.bool(forKey: k) }
        forced = PadAccessibility(reduceMotion: flag("padReduceMotion"), increaseContrast: flag("padContrast"), buttonShapes: flag("padButtonShapes"))
        keyboard.onText = { [weak self] s in
            guard let self else { return }
            if s == "\u{8}" { _ = self.pointer.typed.popLast() } else { self.pointer.typed += s }
        }
    }

    func attach(_ host: PadHostView) {
        self.host = host
        surface.feedback = host
        surface.tapsClick = { [weak self, weak host] in
            PadClickRule.tapsClick(self?.inputMode ?? .touchscreen, keyboardUp: host?.keyboardUp ?? false)
        }
        surface.twoFingerTapClicks = { [weak self, weak host] in
            PadClickRule.twoFingerTapClicks(self?.inputMode ?? .touchscreen, keyboardUp: host?.keyboardUp ?? false)
        }
        surface.onEvent = { [weak self] e in self?.surfaceEvent(e) }
        surface.onTuning = { [weak self] in self?.showTuning = true }
        surface.onReveal = { [weak self] in self?.note("reveal") }
        keyboard.onShown = { [weak self, weak host] up in
            self?.note("keyboard \(up ? "up" : "down")")
            host?.surface.setNeedsFrame()
        }
        host.onLayout = { [weak self] l in
            guard let self else { return }
            let p = CGPoint(x: l.pillX, y: l.pillY)
            if p != self.pill { self.pill = p }
        }
        host.onPillOpacity = { [weak self] o in self?.pillOpacity = o }
        host.haptics.onFire = { [weak self] e, style, intensity in
            self?.note("haptic \(e.rawValue) \(style) \(intensity)")
        }
        host.motion.onLog = { [weak self] line in self?.note(line) }
        host.haptics.prepare()
        let d = UserDefaults.standard
        if d.object(forKey: "padDemo") != nil || d.object(forKey: "padDemoAt") != nil || d.object(forKey: "padHapticCount") != nil {
            let demo = LabDemo(model: self, host: host)
            self.demo = demo
            // A requested rotation lands first; a new grid would clear the field.
            let wait = d.string(forKey: "padOrientation") == nil ? 0.4 : 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { demo.begin() }
        } else if d.bool(forKey: "padGhost") || d.integer(forKey: "padGhostShown") < Int(tuning.ghost.sessions) {
            d.set(d.integer(forKey: "padGhostShown") + 1, forKey: "padGhostShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { host.playGhost() }
        }
    }

    /// The pointer hears each event first, as the guest does in Henge.
    func surfaceEvent(_ e: LabSurface.Event) {
        switch e {
        case let .move(_, now, before):
            let n = max(buttons.padFingers, 1)
            if n == 1 { pointer.move(now.x - before.x, now.y - before.y) } else if n == 2 { pointer.scroll(by: (now.y - before.y) / 2) }
        default: break
        }
    }

    private lazy var logFile: FileHandle? = {
        guard UserDefaults.standard.bool(forKey: "labLogFile") else { return nil }
        let url = Self.tuningURL.deletingLastPathComponent().appendingPathComponent("lab-events.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    func note(_ s: String) {
        logFile?.write(String(format: "%.3f %@\n", CACurrentMediaTime(), s).data(using: .utf8)!)
        guard showLog else { return }
        log.append(s)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    func toggleKeyboard() { keyboard.shown ? keyboard.hide() : keyboard.show() }

    func export() {
        do {
            try tuning.export().write(to: Self.tuningURL)
            saved = "Saved to Documents/pad-tuning.json"
        } catch {
            saved = "Not saved: \(error.localizedDescription)"
        }
    }

    func reset() {
        tuning = PadTuning()
        saved = ""
    }

    var statsText: String {
        guard let s = host?.surface.stats else { return "" }
        return String(format: "%d frames, %d at rest. Main thread %.3f ms (p95 %.3f), of which the field %.3f ms. GPU %.3f ms (p95 %.3f). Touch %.1f µs.",
                      s.frames, s.restFrames, PadFrameStats.median(s.cpu), PadFrameStats.p95(s.cpu), PadFrameStats.median(s.model),
                      PadFrameStats.median(s.gpu), PadFrameStats.p95(s.gpu), PadFrameStats.median(s.touch))
    }
}

struct LabRoot: View {
    @StateObject private var model = LabModel()

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width > geo.size.height
            ZStack {
                Color.black
                LabKeyboard(view: model.keyboard).frame(width: 1, height: 1).opacity(0.01)
                if model.full {
                    pad
                } else if side {
                    HStack(spacing: 0) {
                        LabPointerView(pointer: model.pointer, log: model.log, showLog: model.showLog)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(.leading, max(geo.safeAreaInsets.leading, 12))
                            .padding(.vertical, 12)
                            .frame(width: geo.size.width * 0.4 + geo.safeAreaInsets.leading)
                        pad
                    }
                } else {
                    VStack(spacing: 0) {
                        LabPointerView(pointer: model.pointer, log: model.log, showLog: model.showLog)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(.horizontal, 12)
                            .padding(.top, geo.safeAreaInsets.top + 8)
                            .frame(height: geo.size.height * 0.34 + geo.safeAreaInsets.top)
                        pad
                    }
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showTuning) { LabTuningView(model: model) }
        .onAppear(perform: lockOrientation)
    }

    private var pad: some View {
        PadView(touchView: model.surface, buttons: model.buttons, tuning: model.tuning, forced: model.forced,
                value: "Linux is on the external display", hapticLevel: model.hapticLevel, made: model.attach)
            .overlay(alignment: .topLeading) { pill }
    }

    /// A stand-in for Henge's tool pill: the keyboard, and the tuning sheet.
    private var pill: some View {
        PadPill(tuning: model.tuning, increaseContrast: model.forced.increaseContrast) {
            Button(action: model.toggleKeyboard) { Image(systemName: "keyboard") }
                .accessibilityLabel("Keyboard")
            Button { model.showTuning = true } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Tuning")
        }
        .fixedSize()
        .position(x: model.pill.x, y: model.pill.y)
        .opacity(model.pillOpacity)
    }

    private func lockOrientation() {
        guard let want = UserDefaults.standard.string(forKey: "padOrientation"),
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = want == "landscape" ? .landscapeRight : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}
