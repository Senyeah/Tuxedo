import SwiftUI
import GameController
import LocalAuthentication

/// A running machine. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let machine: VirtualMachine
    let close: () -> Void

    init(machine: VirtualMachine, close: @escaping () -> Void) {
        self.machine = machine
        self.close = close
        let check = SessionGate.Check.for(environment: ProcessInfo.processInfo.environment)
        var gate = SessionGate(check: check, once: SessionGate.oncePerLaunch)
        if SessionGate.testUnlock(environment: ProcessInfo.processInfo.environment) { gate.unlockForTest() }
        _gate = State(initialValue: gate)
    }

    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var folders = FolderSession.shared
    @State private var folderNotice: String?
    @StateObject private var additions = TuxAdditions()
    @State private var wizard: AdditionsWizardRequest?
    @State private var pendingWizard: AdditionsWizardRequest? // waits for Details to close: one sheet at a time
    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var gate: SessionGate // Face ID before a Linux machine runs or comes back
    @State private var gateMessage: String?
    @State private var inactive = false // the app switcher's picture is taken while inactive
    private var hidesGuest: Bool { gate.hidesGuest(inactive: inactive) }
    @State private var state: Int32 = 0
    @State private var bootAttempt = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @AppStorage("tux.cpus") private var globalCpus = 4
    private var cpus: Int { machine.cpuCount(fallback: globalCpus) }
    @AppStorage("tux.matchScreenColors") private var matchScreenColors = true
    @AppStorage("tux.display.brightness") private var screenBrightness = 1.0
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var detailsPath: [String] = []
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @State private var pointerRefused = false
    @AppStorage("tux.controls.hintsShown") private var revealHintsShown = 0
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    @AppStorage(TrackpadFeel.hapticsKey) private var hapticLevel = PadHaptics.Level.all
    @AppStorage(TrackpadFeel.motionKey) private var motionFeel = PadTuning.Motion().style
    // Not observed here: only the pill follows the pad's layout.
    @State private var externalPad = PadSession(ghostKey: "tux.trackpad.ghostShown")
    @State private var panelPad = PadSession()
    @State private var confirmStop = false
    @State private var shutdownAsked: Date? // Linux: when the power button was pressed
    @State private var shutdownOverdue = false
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the guest's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @AppStorage(Sharing.PasteKeys.storageKey) private var pasteKeys = Sharing.PasteKeys.control.rawValue
    @AppStorage(KeyboardFollow.storageKey) private var keyboardFollows = true
    @State private var keyboardFollow = KeyboardFollow()
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the guest's screen the zoomed view shows
    // Phone Linux follows the screen (R8): windowMode is what this orientation wants, liveMode what the guest was sent.
    @State private var windowMode: GuestMode?
    @State private var liveMode: GuestMode?
    @State private var follower: ModeFollower?
    @State private var modeTask: Task<Void, Never>?
    // An external screen sets the guest's mode (R7).
    @State private var externalMode: GuestMode?
    @State private var lastWindow: WindowKey?
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var console = ConsoleModel()
    // Linux starts on the console: U-Boot draws on the GPU at once, so "until the GPU draws" would never show it.
    @State private var consoleChoice = ConsoleChoice.screen

    /// What in the saved machine decides a Linux guest's size.
    private struct ScreenChoiceKey: Equatable {
        var width: Int?, height: Int?, external: Bool?, whole: Bool?
        init(_ m: VirtualMachine) { (width, height, external, whole) = (m.screenWidth, m.screenHeight, m.screenFollowsExternal, m.wholeScreen) }
    }

    private enum ConsoleChoice { case screen, console }

    /// What the guest's size depends on: the window and its safe area, in points.
    private struct WindowKey: Equatable {
        var size: CGSize
        var insets: DisplayInsets
    }

    /// The machine as saved now: the screen choice in settings can change while it runs (R9).
    private var current: VirtualMachine { machines.all.first { $0.id == machine.id } ?? machine }

    /// A fixed Linux size (R9 choices, or an older saved size); nil follows the phone or an external screen.
    private func fixedMode(_ m: VirtualMachine) -> GuestMode? {
        guard !Device.isPad, m.screenWidth != nil else { return nil } // an iPad's saved size has always yielded to a screen
        return GuestMode(w: m.screen.width, h: m.screen.height)
    }

    /// On a monitor the phone is the pad: a console there would be invisible and still hold the keys. The saved choice stays.
    private var consoleShown: Bool { consoleChoice == .console && !display.isExternal }
    /// LINUX-PLAN-12: the picture takes direct touches. Only while the phone shows the picture; the saved choice stays.
    /// Upright on the phone: the picture under the status bar and the home bar, into the corners.
    /// The window's own bottom inset: the home bar, never the keyboard.
    private var windowBottom: CGFloat? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom
    }
    private func wholeScreen(landscape: Bool) -> Bool {
        current.wholeScreen == true && current.followsPhoneScreen && !landscape && !display.isExternal
    }
    private var touchActive: Bool { current.usesTouch && !consoleShown && !display.isExternal }
    /// Zoom is off in touch mode, and comes back with the pointer.
    private var zoomShown: Bool { zoomed && !touchActive }
    /// The guest is on a monitor: the phone is all pad, with its keys and the tools at the top.
    private var padShown: Bool { display.isExternal && !consoleShown && state != 2 }

    /// The guest's shape now: the phone's own screen for phone Linux, else the machine's fixed size.
    private var layoutAspect: CGFloat {
        if let m = externalMode ?? (current.followsPhoneScreen ? windowMode : nil) { return CGFloat(m.w) / CGFloat(m.h) }
        return current.aspect
    }
    /// The size the guest really has, for the pointer's pixels.
    private var guestScreen: (width: Int, height: Int) {
        if let m = liveMode { return (m.w, m.h) }
        return machine.screen
    }


    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let window = WindowKey(size: full, insets: DisplayInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing))
            let layout = Layout(full: full, insets: insets, homeBar: windowBottom ?? insets.bottom, landscape: landscape,
                                zoomed: zoomShown && !consoleShown, typing: typing,
                                centre: zoomCentre, aspect: layoutAspect, console: consoleShown,
                                room: DisplayModePolicy.phoneRoom(safe: window.insets, windowBottom: windowBottom ?? insets.bottom,
                                                                  landscape: landscape, whole: wholeScreen(landscape: landscape)),
                                native: current.followsPhoneScreen ? windowMode.map { DisplayModePolicy.framePoints($0, contentsScale: Device.nativeScale) } : nil)
            ZStack(alignment: .topLeading) {
                (landscape || zoomShown || layout.native != nil ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device, console: console,
                            showConsole: consoleShown, typing: $typing)
                    .opacity(display.isExternal ? 0 : 1)
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.fillsPhone ? 0 : 15, style: .continuous))
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                if state != 2 {
                    if !consoleShown { // the console takes touches itself
                        if padShown {
                            PadView(touchView: externalPad.surface, buttons: .guest, tuning: TrackpadFeel.tuning(motion: motionFeel),
                                    value: "Linux is on the external display",
                                    hapticLevel: hapticLevel, made: externalPad.attach)
                                .frame(width: full.width, height: full.height)
                                .position(x: full.width / 2, y: full.height / 2)
                        } else if touchActive {
                            TouchScreen(guestRect: touchPicture(layout))
                                .defersSystemGestures(on: .all) // the first edge swipe is the guest's
                                .frame(width: layout.touch.width, height: layout.touch.height)
                                .position(x: layout.touch.midX, y: layout.touch.midY)
                        } else {
                            Trackpad(keyboardUp: typing)
                                .frame(width: layout.touch.width, height: layout.touch.height)
                                .position(x: layout.touch.midX, y: layout.touch.midY)
                        }
                        if inputMode == .volumeButtons && volumeMode == .intercept {
                            // The capture interaction must live in the SwiftUI hierarchy to receive
                            // the volume-button events; it passes touches through to the trackpad.
                            CaptureInteractionView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                        }
                    }
                    if padShown {
                        padControls(full)
                    } else if !layout.fillsPhone {
                        uprightControls(layout, full: full)
                    } else {
                        floatingControls(layout)
                    }
                    if pointerRefused && !showRevealHint {
                        Label("Make Tuxedo full screen to use the trackpad or mouse as the machine's", systemImage: "cursorarrow.rays")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showRevealHint {
                        Label("Tap with four fingers to show the controls", systemImage: "hand.tap")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if let folderNotice, !showRevealHint, !hidesGuest {
                        Label(folderNotice, systemImage: "folder")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: min(full.width - 40, 520))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .position(x: full.width / 2, y: insets.top + 56)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                if state == 2 {
                    StoppedMachineView(outcome: tux_vm_exit_outcome(), reason: String(cString: tux_vm_exit_reason()),
                                   start: { bootAttempt += 1 }, close: close)
                        .frame(width: min(layout.touch.width - 32, 360))
                        .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                if let error { errorCard(error, layout) }
                if shutdownAsked != nil && state != 2 { shutdownCard(layout) }
                if hidesGuest { lockCover(layout, full) }
                KeyboardCatcher(active: $typing, suspended: consoleShown).frame(width: 0, height: 0)
                if state == 1 && !consoleShown && !display.isExternal {
                    // Plasma keeps the active window above the keyboard (KeyboardPanel)
                    KeyboardPanelProbe(guest: CGSize(width: guestScreen.width, height: guestScreen.height), frame: layout.screen)
                        .frame(width: layout.screen.width, height: layout.screen.height)
                        .position(x: layout.screen.midX, y: layout.screen.midY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomShown)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .animation(.easeInOut(duration: 0.25), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: folderNotice)
            .onChange(of: folders.notice) { text in
                folderNotice = text
                guard let text else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { // a download notice stays until it is done
                    if folderNotice == text && !text.hasPrefix("Downloading ") { folderNotice = nil; folders.notice = nil }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.revealTap)) { _ in
                controlsHidden = false
                showRevealHint = false
            }
            .onAppear {
                shown = layout.shown
                windowChanged(window)
                externalPad.visible = padShown && !hidesGuest
            }
            .onChange(of: padShown && !hidesGuest) { externalPad.visible = $0 }
            .onChange(of: layout.shown) { shown = $0 }
            .onChange(of: window) { windowChanged($0) } // the new value: the closure's captures are from the old body
            .onChange(of: display.externalPixels) { externalChanged($0) }
            .onChange(of: ScreenChoiceKey(current)) { _ in screenChoiceChanged() }
            .onChange(of: display.isExternal) {
                liftEverything() // the pad's views change: no finger or button stays down
            }
        }
        .statusBarHidden(zoomShown || Device.isPad || display.isExternal || wholeScreen(landscape: false))
        .persistentSystemOverlays(.hidden)
        // With the guest on a monitor the phone is a pad: a pointer at its top must not open the system's panels
        .defersSystemGestures(on: display.isExternal || touchActive ? .all : [])
        .sheet(isPresented: $showDetails, onDismiss: {
            if let request = pendingWizard { wizard = request; pendingWizard = nil }
        }) { details }
        .fullScreenCover(item: $wizard) { request in
            AdditionsWizardView(additions: additions, request: request,
                                typeCommand: { text in Sharing.paste(text + "\r", console: true) }, // the serial console is always there
                                close: { wizard = nil })
        }
        .onChange(of: additions.promptRequest) { _, request in
            guard let request else { return }
            openWizard(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: Autopilot.details)) { note in
            detailsPath = (note.object as? String) == "forwards" ? ["forwards"] : []
            showDetails = true
        }
        .confirmationDialog("Shut down \(machine.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Shut Down", role: .destructive) { finish() }
        } message: {
            Text("\(machine.name) is asked to shut down, as if you pressed its power button. It can take a few seconds.")
        }
        .onChange(of: zoomShown) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: touchActive) { touchModeChanged($0) }
        .onChange(of: liveMode) { mode in
            ExternalScreenReport.shared.guest = mode.flatMap { m in externalMode != nil ? (m, guestScale(for: m)) : nil }
        }
        .onChange(of: externalMode) { _ in
            ExternalScreenReport.shared.guest = liveMode.flatMap { m in externalMode != nil ? (m, guestScale(for: m)) : nil }
        }
        .onChange(of: gate.blanksExternal(inactive: inactive)) { display.guestHidden = $0 }
        .onAppear { display.guestHidden = gate.blanksExternal(inactive: inactive) }
        .onChange(of: scenePhase) { phase in
            inactive = phase != .active
            guard phase != .active else {
                display.refresh()
                setBackground(false)
                return
            }
            tux_vm_screen_touch_cancel()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            VolumeClicks.shared.releaseButtons()
            PointerButtons.guest.releaseAll()
            DeviceStatus.shared.leaveForeground()
            // An external screen's scene may still be up; then the app is not in the background: the machine runs on,
            // but the wallet locks and the return asks again.
            let away = SessionGate.away(scene: phase == .background ? .background : .inactive,
                                        appInBackground: UIApplication.shared.applicationState == .background, deviceLocking: false)
            if away.pause { setBackground(true) }
            else if away.lock { leaveGate() }
            else if phase == .inactive { setBackground(false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            if SessionGate.away(scene: .active, appInBackground: false, deviceLocking: true).lock { leaveGate(deviceLocking: true) } // the device locks
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            if scenePhase == .active { setBackground(false) } // asks again if the lock left the session away
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            setBackground(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            setBackground(false)
        }
        .onChange(of: showDetails) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: wizard) { _, request in
            if request != nil { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
            VolumeClicks.shared.start()
            tux_vm_set_touch_mode(touchActive ? 1 : 0)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            modeTask?.cancel()
            console.stop()
            tux_vm_screen_touch_cancel()
            tux_vm_set_touch_mode(0)
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
            VolumeClicks.shared.stop()
            PointerButtons.guest.releaseAll()
            DeviceStatus.shared.stop()
            ExternalScreenReport.shared.guest = nil
            gate.end()
            KeychainStore.shared.setUnlocked(false)
            FolderSession.shared.end()
            ForwardSession.shared.end()
            additions.stop()
        }
        .modifier(ExternalDisplayModifier(presentation: MachinePresentation(display: display, aspect: layoutAspect)))
        .task(id: bootAttempt) { await run() }
        .task { await Sharing.followGuestClipboard() }
        .task(id: bootAttempt) { await followGuestKeyboard() }
        .onChange(of: typing) { if !$0 { keyboardFollow.closed() } }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { state == 2 || showDetails || wizard != nil || confirmStop || error != nil || shutdownAsked != nil }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them
        let native: CGSize?   // phone Linux: the guest's size in points, drawn 1:1 inside the safe area

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        /// homeBar: the window's own bottom inset, without the keyboard.
        init(full: CGSize, insets: EdgeInsets, homeBar: CGFloat, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat,
             console: Bool, room: DisplayInsets, native: CGSize?) {
            self.insets = insets
            self.native = native
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if console && landscape {
                // Below the control pill; insets.bottom holds the keyboard while it is up.
                let top = insets.top + 58
                screen = CGRect(x: insets.leading, y: top, width: full.width - insets.leading - insets.trailing,
                                height: max(full.height - insets.bottom - top, 100))
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if console {
                // The console takes the room the trackpad has; the bar sits under it, above the keyboard.
                let top = insets.top + 6
                let height = max(full.height - insets.bottom - top - 54 - 20, 100)
                screen = CGRect(x: 8, y: top, width: full.width - 16, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                pad = screen
            } else if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if let native {
                // Whole pixels, so a guest pixel is a layer pixel. The room is phoneRoom's, as for the guest's size;
                // the controls keep the real insets.
                let px = Device.nativeScale
                let safeW = full.width - room.left - room.right
                let safeH = full.height - room.top - room.bottom
                screen = CGRect(x: ((room.left + (safeW - native.width) / 2) * px).rounded() / px,
                                y: ((room.top + (safeH - native.height) / 2) * px).rounded() / px,
                                width: native.width, height: native.height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the guest's top bar, and the guest above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? 2 * max(insets.leading, insets.trailing) : 0
                let height = max(min(room, (full.width - side) / aspect), 200)
                let width = height * aspect
                let y = typing ? insets.top + bar : (full.height - height) / 2
                screen = CGRect(x: (full.width - width) / 2, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if y - insets.top >= 54 { barY = insets.top + (y - insets.top) / 2 }
            } else if landscape {
                // Edge to edge. Phones wider than the guest fill the height with room to spare beside the
                // Dynamic Island; a squarer phone (iPhone Duo) fills all of it, island and corners included.
                let height = min(full.height, full.width / aspect)
                let width = height * aspect
                screen = CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                let height = width / aspect
                screen = CGRect(x: 8, y: insets.top + 6, width: width, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                // The keyboard covers the pad's lower part (PadLayout); a pad that kept its size keeps the pointer's speed.
                let top = toolsY + 54 + 10
                pad = CGRect(x: 8, y: top, width: width, height: max(full.height - homeBar - top, 60))
            }
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout, full: CGSize) -> some View {
        if !controlsHidden { // the pad keeps its place with the keyboard, so the bar can stay
            HStack {
                if consoleShown {
                    viewSwitch()
                } else {
                    tool("eye.slash", "Hide controls") { hideControls() }
                    Spacer()
                    viewSwitch()
                    Spacer()
                }
                tool("keyboard", "Keyboard") { typing.toggle() }
                Spacer()
                if !consoleShown {
                    inputSwitch()
                    Spacer()
                }
                pasteTool(keysMenu: Self.roomForKeysMenu(layout.pad.width + 16))
                Spacer()
                if consoleShown {
                    fitTool()
                } else {
                    tool("plus.magnifyingglass", "Zoom in") { zoomed = true }
                        .disabled(touchActive)
                        .opacity(touchActive ? 0.4 : 1)
                }
                Spacer()
                tool("info.circle", "Details") { showDetails = true }
                Spacer()
                tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        if !consoleShown { trackpadPanel(layout, full: full) }
    }

    /// The pad below the picture. Its view reaches the screen's bottom, so the pad sits on the home bar's
    /// safe edge as it does on its own (PadLayout); the corner is the old panel's.
    private func trackpadPanel(_ layout: Layout, full: CGSize) -> some View {
        let tuning = TrackpadFeel.tuning(motion: motionFeel, page: "#0B0C10") // Desk.page, dark
        let top = layout.pad.minY - tuning.layout.margin
        return PadView(touchView: panelPad.surface, buttons: .guest, tuning: tuning, value: "", hapticLevel: hapticLevel,
                       corner: 30 + tuning.layout.margin, made: panelPad.attach)
            .frame(width: full.width, height: max(full.height - top, 0))
            .position(x: full.width / 2, y: (top + full.height) / 2)
    }

    // MARK: On a monitor

    /// The session's tools in the pad's pill, at the top. The zoom and the touch switch have no picture to act on.
    @ViewBuilder private func padControls(_ full: CGSize) -> some View {
        if !controlsHidden {
            PadToolPill(pad: externalPad, tuning: TrackpadFeel.tuning(motion: motionFeel)) {
                padTool("eye.slash", "Hide controls") { hideControls() }
                padTool("keyboard", "Keyboard") { typing.toggle() }
                pasteTool(keysMenu: Self.roomForKeysMenu(full.width))
                padTool("info.circle", "Details") { showDetails = true }
                padTool("power", "Shut down", tint: Desk.bad) { stopTapped() }
            }
            .transition(.opacity)
        }
    }

    /// A tool in the pad's pill: PadPillButtonStyle gives it its size and alpha.
    private func padTool(_ symbol: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let tint { Image(systemName: symbol).foregroundStyle(tint) } else { Image(systemName: symbol) }
        }
        .accessibilityLabel(label)
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    /// A Linux desktop adds a menu for what to paste with: terminals want Ctrl-Shift-V. Details has the same choice.
    private func pasteTool(keysMenu: Bool = true) -> some View {
        HStack(spacing: 0) {
            PasteButton(payloadType: String.self) { texts in
                if let text = texts.first {
                    Sharing.paste(text, console: consoleShown, keys: Sharing.PasteKeys(rawValue: pasteKeys) ?? .control)
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(Desk.raised)
            .accessibilityHint("Types the copied text into the machine")
            if !consoleShown && keysMenu {
                Menu {
                    Picker("Paste with", selection: $pasteKeys) {
                        Text("Ctrl-V").tag(Sharing.PasteKeys.control.rawValue)
                        Text("Ctrl-Shift-V (terminals)").tag(Sharing.PasteKeys.controlShift.rawValue)
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 36)
                }
                .accessibilityLabel("Paste keys")
            }
        }
    }

    /// The guest picture in the touch view's coordinates, as the layer fits it into the screen's frame.
    private func touchPicture(_ layout: Layout) -> CGRect {
        let frame = layout.screen.offsetBy(dx: -layout.touch.minX, dy: -layout.touch.minY)
        return TouchMapping.pictureRect(guest: CGSize(width: guestScreen.width, height: guestScreen.height), in: frame)
    }

    /// A switch between the trackpad and touch: nothing stays down in the guest across it.
    private func touchModeChanged(_ on: Bool) {
        TuxLog.log("input", "touch input \(on ? "on" : "off")")
        tux_vm_set_touch_mode(on ? 1 : 0)
        if on {
            liftEverything()
        } else {
            tux_vm_screen_touch_cancel()
        }
    }

    /// Every pad finger up and every button let go, as a surface goes away.
    private func liftEverything() {
        let ms = UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000))
        for id in Int32(1)...5 { tux_vm_touch(id, 2, 0, 0, ms) }
        tux_vm_touch_frame(ms)
        externalPad.surface.reset()
        panelPad.surface.reset()
        PointerButtons.guest.releaseAll()
        tux_vm_mouse_button(0, 0) // a drag in progress ends
    }

    /// Hides the session's controls; four fingers on the screen bring them back. The first few times say so.
    private func hideControls() {
        controlsHidden = true
        typing = false
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    /// A Linux desktop says when the focused program wants text (tux-keyboard): the keyboard comes and goes with it.
    private func followGuestKeyboard() async {
        KeyboardFrame.start() // before the console can hide the probe
        var seq: UInt = 0
        _ = tux_share_keyboard_wanted(&seq)
        keyboardFollow = KeyboardFollow(seq: seq)
        while !Task.isCancelled {
            let wanted = tux_share_keyboard_wanted(&seq) != 0
            // The console has the keys while it shows. A hardware keyboard needs no keyboard on the screen.
            let allowed = keyboardFollows && state == 1 && !consoleShown && GCKeyboard.coalesced == nil
            // Nor during a drag: the keyboard would cover the pad's keys under the finger. It moves when the drag ends.
            let held = PointerButtons.guest.anyDown
            if let show = keyboardFollow.poll(wanted: wanted, seq: seq, typing: typing, allowed: allowed, held: held) { typing = show }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Linux: the screen and the serial console are both always there; this shows the other one.
    private func viewSwitch(tint: Color = Desk.text) -> some View {
        tool(consoleShown ? "display" : "terminal", consoleShown ? "Show the screen" : "Show the console", tint: tint) { switchView() }
    }

    private func switchView() {
        zoomed = false
        controlsHidden = false
        consoleChoice = consoleShown ? .screen : .console
        var m = current
        m.showsConsole = consoleChoice == .console ? true : nil
        Machines.shared.update(m)
    }

    /// Tells the guest the console's size, on request only.
    private func fitTool(tint: Color = Desk.text) -> some View {
        Button { console.fit() } label: {
            Text("Fit")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Fit the console to the view")
    }

    /// Linux: the picture takes direct touches, or it is a trackpad. As the view switch, it names what a tap selects.
    private func inputSwitch(tint: Color = Desk.text) -> some View {
        let touch = current.usesTouch
        return tool(touch ? "cursorarrow" : "hand.point.up.left", touch ? "Use the pointer" : "Use touch", tint: tint) {
            var m = current
            m.touchInput = !touch
            Machines.shared.update(m)
        }
        .accessibilityValue(touch ? "Touch" : "Pointer")
        .disabled(display.isExternal) // the phone shows no picture to touch
        .opacity(display.isExternal ? 0.4 : 1)
    }

    /// With the touch tool, a phone held upright has no room for the paste keys' menu (an estimate: 431 pt against 402).
    private static func roomForKeysMenu(_ width: CGFloat) -> Bool { width >= 440 }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let roomy = Self.roomForKeysMenu(layout.touch.width) || consoleShown
        let pill = HStack(spacing: roomy ? 4 : 2) {
            if consoleShown {
                viewSwitch(tint: .white)
            } else {
                tool("eye.slash", "Hide controls", tint: .white) { hideControls() }
                viewSwitch(tint: .white)
            }
            tool("keyboard", "Keyboard", tint: .white) { typing.toggle() }
            if !consoleShown { inputSwitch(tint: .white) }
            pasteTool(keysMenu: roomy)
            if consoleShown {
                fitTool(tint: .white)
            } else {
                tool(zoomShown ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomShown ? "Zoom out" : "Zoom in", tint: zoomShown ? Desk.accentLight : .white) { zoomed.toggle() }
                    .disabled(touchActive)
                    .opacity(touchActive ? 0.4 : 1)
            }
            tool("info.circle", "Details", tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if controlsHidden {
            EmptyView()
        } else if let barY = layout.barY {
            pill.position(x: layout.touch.midX, y: barY)
        } else if landscape || typing {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        if zoomShown { zoomMap(layout) }
    }

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / layoutAspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if tux_vm_pointer(&x, &y) == 0 {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(guestScreen.width), y: CGFloat(y) / CGFloat(guestScreen.height)))
            }
            if tick % 60 == 0, let image = MachinePreview.capture(width: 224, height: Int(224 / layoutAspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    /// The window changed (rotation): the frame moves at once, the guest's mode follows after the debounce.
    private func windowChanged(_ window: WindowKey) {
        let full = window.size, insets = window.insets
        lastWindow = window
        guard current.followsPhoneScreen, full.width > 0 else { return }
        // The keyboard raises SwiftUI's bottom inset; the window's own inset does not hold it.
        let bottom = windowBottom ?? insets.bottom
        let room = DisplayModePolicy.phoneRoom(safe: insets, windowBottom: bottom, landscape: full.width > full.height,
                                               whole: wholeScreen(landscape: full.width > full.height))
        let mode = DisplayModePolicy.phoneMode(window: full, insets: room, nativeScale: Device.nativeScale)
        guard mode != windowMode else { return }
        TuxLog.log("display", "window \(Int(full.width))x\(Int(full.height)) pt, safe insets t\(insets.top) l\(insets.left) b\(insets.bottom) (used \(bottom)) r\(insets.right), typing \(typing), "
                   + "scale \(Device.nativeScale) -> \(mode.w)x\(mode.h)")
        windowMode = mode
        guard var f = follower else { return }
        let pending = f.orientation(mode, now: ProcessInfo.processInfo.systemUptime)
        follower = f
        schedule(pending)
    }

    /// An external screen came or went: the guest follows its size, and the machine remembers it.
    private func externalChanged(_ pixels: CGSize?) {
        saveExternalScreen(pixels)
        TuxLog.log("display", "external screen \(pixels.map { "\(Int($0.width))x\(Int($0.height))" } ?? "gone")")
        applyLinuxScreen()
    }

    /// The screen choice changed in settings: the guest takes it at once.
    private func screenChoiceChanged() {
        if let lastWindow { windowChanged(lastWindow) } // the phone mode may be stale after a fixed size
        applyLinuxScreen()
    }

    /// The target for the saved choice and the screens there now, sent through the follower.
    private func applyLinuxScreen() {
        let m = current
        let mode = DisplayModePolicy.linuxTarget(fixed: fixedMode(m), live: display.externalPixels,
                                                 remembered: m.lastExternalScreen.map { CGSize(width: $0.width, height: $0.height) },
                                                 wantsExternal: m.screenFollowsExternal == true)
        externalMode = mode
        TuxLog.log("display", "linux screen choice -> guest \(mode.map { "\($0.w)x\($0.h)" } ?? "phone mode")")
        guard var f = follower else { return } // before boot, run() reads it
        let pending = f.externalDisplay(mode, now: ProcessInfo.processInfo.systemUptime)
        follower = f
        schedule(pending)
    }

    /// The scale the guest is told with `mode`: 2 on the phone, by height on an external screen.
    private func guestScale(for mode: GuestMode) -> Double {
        if externalMode != nil { return DisplayModePolicy.guestScale(shortSide: min(mode.w, mode.h), isPhone: false) }
        return current.followsPhoneScreen ? 2 : 1
    }

    private func schedule(_ pending: ModeFollower.Pending?) {
        modeTask?.cancel()
        guard let pending else { return }
        modeTask = Task {
            while !Task.isCancelled {
                let wait = pending.at - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9) + 1_000_000) }
                guard !Task.isCancelled else { return }
                var f = follower
                if let m = f?.take(now: ProcessInfo.processInfo.systemUptime) {
                    follower = f
                    liveMode = m
                    let scale = guestScale(for: m)
                    tux_vm_set_display_scale(scale) // before the mode: the guest reads both when the mode event comes
                    tux_vm_set_display(UInt32(m.w), UInt32(m.h))
                    TuxLog.log("session", "linux screen \(m.w)x\(m.h) scale \(scale) (\(externalMode != nil ? "external" : "phone"))")
                    return
                }
                if f?.pending == nil { return }
            }
        }
    }

    private func saveExternalScreen(_ pixels: CGSize?) {
        guard let pixels else { return }
        let size = PixelSize(width: Int(pixels.width), height: Int(pixels.height))
        guard var current = Machines.shared.all.first(where: { $0.id == machine.id }), current.lastExternalScreen != size else { return }
        current.lastExternalScreen = size
        Machines.shared.update(current)
    }

    /// The external screen's guest mode, if a screen is there or shows up within about a second of boot.
    private func bootExternalMode() async -> GuestMode? {
        func mode() -> GuestMode? { display.externalPixels.map { DisplayModePolicy.externalMode(pixels: $0) } }
        if let m = mode() { return m }
        let present = UIApplication.shared.connectedScenes.contains { $0.session.role == .windowExternalDisplayNonInteractive }
        guard present else { return nil }
        for _ in 0..<20 where !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let m = mode() { return m }
        }
        return nil
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This machine could not start").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("Close") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    /// Shown while the guest is asked to power off; "Turn off now" appears if it takes too long.
    private func shutdownCard(_ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Shutting down…").font(.system(size: 17, weight: .semibold))
            }
            if shutdownOverdue {
                Text("\(machine.name) is taking a while. You can turn it off now; anything not saved on it is lost.")
                    .font(.system(size: 14)).foregroundStyle(Desk.dim)
                Button("Turn off now") {
                    tux_vm_stop()
                    close()
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.bad)
            }
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "Starting…" : "Not started"
        case 1: return userCode ? "Debian is running" : "Booting"
        case 3: return "Finishing shutdown…"
        default: return "Stopped (\(String(cString: tux_vm_exit_reason())))"
        }
    }

    private var details: some View {
        NavigationStack(path: $detailsPath) {
            List {
                Section(phase) {
                    LabeledContent("CPUs on", value: "\(cpusOn) of \(cpus)")
                    LabeledContent("Temperature", value: Self.thermalLabel(thermalState))
                    LabeledContent("Translated blocks", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("Network frames", value: "\(framesOut) out, \(framesIn) in")
                    LabeledContent("Up", value: "\(Int(Date().timeIntervalSince(started))) s")
                }
                Section("Port forwards") { ForwardsDetails(machine: machine.id) } // where to connect is what Details is opened for
                Section("Display") {
                    Toggle("Color matching", isOn: $matchScreenColors)
                    LabeledContent("Brightness", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("Brightness dims only the machine's screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pointer") {
                    LabeledContent("Scroll speed", value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text("Scroll speed changes apply immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sharing") {
                    LabeledContent("Clipboard", value: helperRunning ? "On" : "Not running")
                    Picker("Paste with", selection: $pasteKeys) {
                        Text("Ctrl-V").tag(Sharing.PasteKeys.control.rawValue)
                        Text("Ctrl-Shift-V (terminals)").tag(Sharing.PasteKeys.controlShift.rawValue)
                    }
                    Text(helperRunning
                         ? "What you copy in the guest is copied here too, and the paste button pastes from here into the guest. Paste with chooses Ctrl-V or Ctrl-Shift-V, which terminals want. When there is room, the arrow beside the paste button also chooses it."
                         : "The clipboard helper runs on a Debian desktop. Without it, and on the console, the paste button types the text into the guest.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Folders") {
                    NavigationLink {
                        FoldersPage(machine: machine.id)
                    } label: {
                        LabeledContent("Folders from Files", value: "\(current.folders?.count ?? 0)")
                    }
                    Text("Add, pick again, change the mode, or export and discard a Copy-on-write folder's changes. Changes apply at once.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                additionsSection
                Section("Log") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { _ in ForwardsPage(machine: machine.id) }
        }
    }

    /// Tuxedo Additions: the state rows and the button. Never for a machine from before Tuxedo.
    @ViewBuilder private var additionsSection: some View {
        let report = additions.state.report ?? current.additionsReport
        let live = additions.state.report != nil
        let legacy = report?.caps.legacy == true || current.guestUser == nil
        Section(AdditionsText.sectionTitle) {
            if legacy {
                Text(AdditionsText.legacyGuest).font(.footnote).foregroundStyle(.secondary)
            } else {
                LabeledContent("In this app", value: additions.versions?.packages["tux-guest"] ?? (additions.hasMedia ? "Unknown" : "No media"))
                LabeledContent("In the guest", value: AdditionsPolicy.guestVersion(report?.caps) ?? (report == nil ? AdditionsText.noReport : AdditionsText.notInstalled))
                LabeledContent("CD", value: additions.inserted ? "Inserted" : "Out")
                if report != nil && !live {
                    Text("This is the last report from an earlier session.").font(.footnote).foregroundStyle(.secondary)
                }
                if AdditionsPolicy.updateAvailable(live ? report?.caps : nil, versions: additions.versions) {
                    Label(AdditionsText.updateBanner, systemImage: "arrow.down.circle").font(.footnote).foregroundStyle(Desk.warn)
                }
                if !additions.hasMedia {
                    Text(AdditionsText.notInThisApp).font(.footnote).foregroundStyle(Desk.bad)
                } else if let problem = additions.lastError ?? additions.state.badMedia {
                    Text(problem).font(.footnote).foregroundStyle(Desk.bad)
                }
                Button {
                    if additions.insert() { openWizard(AdditionsWizardRequest()) } // insert does nothing when the CD is in
                } label: {
                    Text(additions.inserted ? AdditionsText.open : AdditionsText.insert)
                }
                .disabled(state != 1 || !additions.running || !additions.hasMedia)
                .accessibilityLabel(additions.inserted ? "Open Tuxedo Additions" : "Insert the Tuxedo Additions CD")
                if additions.inserted && !additions.state.running {
                    Button(AdditionsText.eject) { additions.eject() }
                        .accessibilityLabel("Eject the Tuxedo Additions CD")
                }
                Text(AdditionsText.detailsNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Opens the wizard now, or when Details has closed.
    private func openWizard(_ request: AdditionsWizardRequest) {
        if showDetails {
            pendingWizard = request
            showDetails = false
        } else {
            wizard = request
        }
    }

    // MARK: Running

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot — performance reduced"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func run() async {
        error = nil
        state = 0
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        zoomed = false
        tux_vm_screen_touch_cancel()
        controlsHidden = false
        showRevealHint = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        shutdownAsked = nil
        shutdownOverdue = false
        consoleChoice = current.showsConsole == true ? .console : .screen
        console.reset()
        console.start()
        while tux_vm_state() == 3 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled else { return }
        gate.end() // a restart asks again
        KeychainStore.shared.setUnlocked(false)
        askToOpen()
        while gate.phase != .open { // a refusal waits here for Try Again or Close
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let ram = GuestMemory.prepare(machine)
        TuxLog.log("session", "available memory \(tux_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "There is not room for this machine's memory: it needs a few GB of free storage."
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        // After the Face ID check: the folders are private. They stay open while the wallet is locked (decision 6).
        FolderSession.shared.start(current)
        ForwardSession.shared.start(current)
        KeychainStore.shared.attach(machine)
        KeychainStore.shared.setUnlocked(gate.secretsUnlocked)
        DeviceStatus.shared.start { [display] in !display.isExternal }
        EngineTuning.apply()
        let saved = current
        var phone = GuestMode(w: saved.screen.width, h: saved.screen.height)
        if saved.followsPhoneScreen {
            while windowMode == nil && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard !Task.isCancelled, let mode = windowMode else { return }
            phone = mode
        }
        let fixed = fixedMode(saved)
        let live = fixed == nil ? await bootExternalMode() : nil // a fixed size ignores screens
        guard !Task.isCancelled else { return }
        if current.followsPhoneScreen, let latest = windowMode { phone = latest } // rotation during the wait
        let remembered = saved.lastExternalScreen.map { CGSize(width: $0.width, height: $0.height) }
        let external = DisplayModePolicy.linuxTarget(fixed: fixed, live: live.map { CGSize(width: $0.w, height: $0.h) },
                                                 remembered: remembered, wantsExternal: saved.screenFollowsExternal == true)
        let boot = external ?? phone
        externalMode = external
        liveMode = boot
        follower = ModeFollower(initial: boot, phone: phone, external: external)
        tux_vm_set_display_scale(guestScale(for: boot))
        tux_vm_set_display(UInt32(boot.w), UInt32(boot.h))
        let rc: Int32
        TuxLog.log("session", "linux screen \(guestScreen.width)x\(guestScreen.height)\(current.followsPhoneScreen ? " (phone native, scale 2)" : "")\(machine.accel == true ? ", graphics acceleration" : "")\(machine.decodesVideo ? ", video decode" : "")\(machine.encodesVideo ? ", video encode" : "")")
        rc = tux_vm_boot_linux(machine.firmware.path, machine.disk.path, ram, Int32(cpus), machine.accel == true ? 1 : 0,
                                machine.decodesVideo ? 1 : 0, machine.encodesVideo ? 1 : 0, &buffer, buffer.count)
        if rc != 0 {
            error = String(cString: buffer)
            FolderSession.shared.end()
            ForwardSession.shared.end()
            return
        }
        started = Date()
        additions.begin(current) // after the boot: the engine made a new, empty log of events
        var used = Machines.shared.all.first { $0.id == machine.id } ?? machine // keeps lastExternalScreen
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = tux_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = tux_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = tux_vm_state()
            if state == 3 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            if let asked = shutdownAsked, Date().timeIntervalSince(asked) >= 30 { shutdownOverdue = true }
            cpusOn = tux_vm_cpus_on()
            userCode = userCode || tux_vm_guest_el0() != 0
            let now = Date(), blocks = tux_vm_blocks()
            blocksPerSecond = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            framesOut = tux_vm_net_frames(1)
            framesIn = tux_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(TuxLog.recentLines(200))
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                thermalState = heat
                TuxLog.log("session", "thermal state: \(Self.thermalLabel(heat))")
            }
            if state == 2 {
                typing = false
                showDetails = false
                wizard = nil
                additions.stop()
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                gate.end() // no machine runs: the wallet locks
                KeychainStore.shared.setUnlocked(false)
                FolderSession.shared.end()
                ForwardSession.shared.end()
                let outcome = tux_vm_exit_outcome()
                if shutdownAsked != nil && outcome == Int32(TUX_VM_OUTCOME_SHUTDOWN.rawValue) {
                    close() // the person asked for it: no stopped card
                    break
                }
                TuxLog.log("session", "showing stopped machine: \(String(cString: tux_vm_exit_reason()))")
                if outcome == Int32(TUX_VM_OUTCOME_RESTART.rawValue) && tux_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = tux_vm_gpu_frames()
                TuxLog.log("perf", "blocks/s \(String(format: "%.0f", blocksPerSecond)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(framesOut), rx \(framesIn), dns \(tux_vm_dns(0)) answered \(tux_vm_dns(2)) unanswered, "
                             + "thermal \(Self.thermalLabel(heat))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick % 30 == 0 { TuxLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MachinePreview.save(for: machine) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        if state == 1 { confirmStop = true } else { close() }
    }

    /// The machine pauses while the app is away, so iOS freezing it does not jump the guest's clock (RCU stalls).
    /// A machine with graphics acceleration always pauses, even while it plays sound: iOS allows no Metal work in the background.
    /// Every machine locks in the background and asks for Face ID when the app comes back (SessionGate).
    private func setBackground(_ away: Bool) {
        if away {
            leaveGate()
        } else if gate.phase == .away {
            askToOpen() // resumes when it passes
            return
        } else if gate.covered {
            return
        }
        let was = tux_vm_paused() != 0
        tux_vm_set_background(away ? 1 : 0) // sound keeps only a machine without acceleration running; it pauses when the sound stops
        let now = tux_vm_paused() != 0
        if now != was { TuxLog.log("session", now ? "paused in the background" : "resumed") }
    }

    /// The wallet locks and the next return asks again (SessionGate.away).
    private func leaveGate(deviceLocking: Bool = false) {
        gate.leave(deviceLocking: deviceLocking)
        guard gate.phase == .away else { return } // still open: Face ID passed in this launch
        typing = false
        KeychainStore.shared.setUnlocked(false)
    }

    private func askToOpen() {
        switch gate.ask() {
        case .nothing:
            return
        case .opened: // TUX_AUTOPILOT
            if gate.check == .skippedForTest {
                TuxLog.log("session", "face id: skipped (TUX_AUTOPILOT); wallet \(gate.secretsUnlocked ? "unlocked by the test" : "locked")")
            }
            KeychainStore.shared.setUnlocked(gate.secretsUnlocked)
            setBackground(false)
        case .check(let ticket):
            gateMessage = nil
            Task { @MainActor in
                let outcome = await SessionAuth.check(machine.name)
                switch outcome {
                case .passed:
                    gate.checked(ticket, passed: true)
                    guard gate.secretsUnlocked else { return } // the app left during the check
                    KeychainStore.shared.setUnlocked(true)
                    setBackground(false)
                case .failed(let message):
                    gate.checked(ticket, passed: false)
                    gateMessage = message
                }
            }
        }
    }

    /// Hides the guest until the check passes. A refusal offers the check again, or leaves.
    private func lockCover(_ layout: Layout, _ full: CGSize) -> some View {
        ZStack {
            Color.black.frame(width: full.width, height: full.height)
            if gate.phase == .refused {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(machine.name) is locked").font(.system(size: 17, weight: .semibold))
                    Text(gateMessage ?? "Face ID did not pass.").font(.system(size: 14)).foregroundStyle(Desk.dim)
                    if state == 1 {
                        Text("Turn Off stops it at once: anything not saved on it is lost.").font(.system(size: 14)).foregroundStyle(Desk.dim)
                    }
                    HStack(spacing: 24) {
                        Button("Try Again") { askToOpen() }.foregroundStyle(Desk.accentLight)
                        Button(state == 1 ? "Turn Off" : "Close") {
                            if state == 1 { tux_vm_stop() }
                            close()
                        }
                        .foregroundStyle(state == 1 ? Desk.bad : Desk.accentLight)
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
                .padding(18)
                .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
                .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                Image(systemName: "faceid").font(.system(size: 44)).foregroundStyle(Desk.dim)
            }
        }
        .frame(width: full.width, height: full.height)
    }

    private func finish() {
        if state == 1 {
            MachinePreview.saveNow(for: machine)
            tux_vm_power_button()
            shutdownAsked = Date()
            shutdownOverdue = false
            return // the run loop closes the view when the guest is off
        }
        close()
    }
}
