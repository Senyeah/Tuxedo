import SwiftUI
import GameController

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @ObservedObject private var machines = Machines.shared
    @StateObject private var display = DisplayRouter()
    @State private var error: String?
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
    @AppStorage("henge.cpus") private var globalCpus = 4
    private var cpus: Int { mac.cpuCount(fallback: globalCpus) }
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.scale") private var cursorScale = Device.isPad ? 1 : 3
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @State private var pointerRefused = false
    @AppStorage("henge.controls.hintsShown") private var revealHintsShown = 0
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage("henge.tips.stillWallpaperShown") private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    @State private var shutdownAsked: Date? // Linux: when the power button was pressed
    @State private var shutdownOverdue = false
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @AppStorage(Sharing.PasteKeys.storageKey) private var pasteKeys = Sharing.PasteKeys.control.rawValue
    @AppStorage(KeyboardFollow.storageKey) private var keyboardFollows = true
    @State private var keyboardFollow = KeyboardFollow()
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    // Phone Linux follows the screen (R8): windowMode is what this orientation wants, liveMode what the guest was sent.
    @State private var windowMode: GuestMode?
    @State private var liveMode: GuestMode?
    @State private var follower: ModeFollower?
    @State private var modeTask: Task<Void, Never>?
    // An external screen sets the guest's mode (R7): externalMode is Linux's, macBootMode the size a Mac booted at.
    @State private var externalMode: GuestMode?
    @State private var macBootMode: GuestMode?
    @State private var lastWindow: WindowKey?
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var console = ConsoleModel()
    // Linux starts on the console: U-Boot draws on the GPU at once, so "until the GPU draws" would never show it.
    @State private var consoleChoice = ConsoleChoice.screen

    /// What in the saved machine decides a Linux guest's size.
    private struct ScreenChoiceKey: Equatable {
        var width: Int?, height: Int?, external: Bool?, whole: Bool?
        init(_ m: VirtualMac) { (width, height, external, whole) = (m.screenWidth, m.screenHeight, m.screenFollowsExternal, m.wholeScreen) }
    }

    private enum ConsoleChoice { case screen, console }

    /// What the guest's size depends on: the window and its safe area, in points.
    private struct WindowKey: Equatable {
        var size: CGSize
        var insets: DisplayInsets
    }

    /// The machine as saved now: the screen choice in settings can change while it runs (R9).
    private var current: VirtualMac { machines.all.first { $0.id == mac.id } ?? mac }

    /// A fixed Linux size (R9 choices, or an older saved size); nil follows the phone or an external screen.
    private func fixedMode(_ m: VirtualMac) -> GuestMode? {
        guard m.guest == .linux, !Device.isPad, m.screenWidth != nil else { return nil } // an iPad's saved size has always yielded to a screen
        return GuestMode(w: m.screen.width, h: m.screen.height)
    }

    private var consoleShown: Bool { mac.guest == .linux && consoleChoice == .console }
    /// LINUX-PLAN-12: the picture takes direct touches. Only while the phone shows the picture; the saved choice stays.
    /// Upright on the phone: the picture under the status bar and the home bar, into the corners.
    private func wholeScreen(landscape: Bool) -> Bool {
        current.wholeScreen == true && current.followsPhoneScreen && !landscape && !display.isExternal
    }
    private var touchActive: Bool { mac.guest == .linux && current.usesTouch && !consoleShown && !display.isExternal }
    /// Zoom is off in touch mode, and comes back with the pointer.
    private var zoomShown: Bool { zoomed && !touchActive }

    /// The guest's shape now: the phone's own screen for phone Linux, else the machine's fixed size.
    private var layoutAspect: CGFloat {
        if let m = externalMode ?? macBootMode ?? (current.followsPhoneScreen ? windowMode : nil) { return CGFloat(m.w) / CGFloat(m.h) }
        return current.aspect
    }
    /// The size the guest really has, for the pointer's pixels.
    private var guestScreen: (width: Int, height: Int) {
        if let m = mac.guest == .linux ? liveMode : macBootMode { return (m.w, m.h) }
        return mac.screen
    }


    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let window = WindowKey(size: full, insets: DisplayInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing))
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomShown && !consoleShown, typing: typing,
                                centre: zoomCentre, aspect: layoutAspect, console: consoleShown, whole: wholeScreen(landscape: landscape),
                                native: current.followsPhoneScreen ? windowMode.map { DisplayModePolicy.framePoints($0, contentsScale: Device.nativeScale) } : nil)
            ZStack(alignment: .topLeading) {
                (landscape || zoomShown || layout.native != nil ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device, guest: mac.guest, console: console,
                            showConsole: consoleShown, typing: $typing)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal && state != 2 {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("\(mac.guest == .linux ? "Linux" : "Mac") on external display").font(.headline)
                                Text("Use the trackpad, keyboard or a connected mouse.")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
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
                        if touchActive {
                            TouchScreen(guestRect: touchPicture(layout))
                                .defersSystemGestures(on: .all) // the first edge swipe is the guest's
                                .frame(width: layout.touch.width, height: layout.touch.height)
                                .position(x: layout.touch.midX, y: layout.touch.midY)
                        } else {
                            Trackpad()
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
                    if !layout.fillsPhone {
                        uprightControls(layout)
                    } else {
                        floatingControls(layout)
                    }
                    if pointerRefused && !showRevealHint {
                        Label("Make Henge full screen to use the trackpad or mouse as the \(mac.noun)'s", systemImage: "cursorarrow.rays")
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
                    if showWallpaperTip && mac.guest == .mac && !showRevealHint && !pointerRefused {
                        Label("For more speed, give this Mac a still wallpaper and set its screen saver to Never in System Settings.", systemImage: "speedometer")
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
                    StoppedMachineView(kind: mac.guest, outcome: henge_vm_exit_outcome(), reason: String(cString: henge_vm_exit_reason()),
                                   start: { bootAttempt += 1 }, close: close)
                        .frame(width: min(layout.touch.width - 32, 360))
                        .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                if let error { errorCard(error, layout) }
                if shutdownAsked != nil && state != 2 { shutdownCard(layout) }
                KeyboardCatcher(active: $typing, suspended: consoleShown, linux: mac.guest == .linux).frame(width: 0, height: 0)
                if mac.guest == .linux && state == 1 && !consoleShown && !display.isExternal {
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
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
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
            }
            .onChange(of: layout.shown) { shown = $0 }
            .onChange(of: window) { windowChanged($0) } // the new value: the closure's captures are from the old body
            .onChange(of: display.externalPixels) { externalChanged($0) }
            .onChange(of: ScreenChoiceKey(current)) { _ in screenChoiceChanged() }
            .onChange(of: display.isExternal) { henge_vm_set_pointer_scale($0 ? 1 : 0) } // 1:1 on a big screen
        }
        .statusBarHidden(zoomShown || Device.isPad || display.isExternal || wholeScreen(landscape: false))
        .persistentSystemOverlays(.hidden)
        // With the guest on a monitor the phone is a pad: a pointer at its top must not open the system's panels
        .defersSystemGestures(on: display.isExternal || touchActive ? .all : [])
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog("Shut down \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Shut Down", role: .destructive) { finish() }
        } message: {
            Text(mac.guest == .linux
                 ? "\(mac.name) is asked to shut down, as if you pressed its power button. It can take a few seconds."
                 : "This turns the Mac off at once. Anything not saved on it is lost.")
        }
        .onChange(of: zoomShown) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: touchActive) { touchModeChanged($0) }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                display.refresh()
                setBackground(false)
                return
            }
            henge_vm_screen_touch_cancel()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            VolumeClicks.shared.releaseButtons()
            DeviceStatus.shared.leaveForeground()
            // An external screen's scene may still be up; then the app is not in the background.
            if phase == .background && UIApplication.shared.applicationState == .background { setBackground(true) }
            else if phase == .inactive { setBackground(false) }
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
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
            VolumeClicks.shared.start()
            henge_vm_set_touch_mode(touchActive ? 1 : 0)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            modeTask?.cancel()
            henge_vm_set_pointer_scale(0)
            console.stop()
            henge_vm_screen_touch_cancel()
            henge_vm_set_touch_mode(0)
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
            VolumeClicks.shared.stop()
            DeviceStatus.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: layoutAspect, isLinux: mac.guest == .linux)))
        .task(id: bootAttempt) { await run() }
        .task { await Sharing.followMacClipboard() }
        .task(id: bootAttempt) { await followGuestKeyboard() }
        .onChange(of: typing) { if !$0 { keyboardFollow.closed() } }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { state == 2 || showDetails || confirmStop || error != nil || shutdownAsked != nil }

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

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat,
             console: Bool, whole: Bool, native: CGSize?) {
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
                // Whole pixels, so a guest pixel is a layer pixel. The home bar keeps its room; a keyboard's inset does not.
                // The whole screen: the picture's room ignores the insets; the controls still keep them.
                let px = Device.nativeScale
                let room = whole ? EdgeInsets() : insets
                let safeW = full.width - room.leading - room.trailing
                let safeH = full.height - room.top - min(room.bottom, 40)
                screen = CGRect(x: ((room.leading + (safeW - native.width) / 2) * px).rounded() / px,
                                y: ((room.top + (safeH - native.height) / 2) * px).rounded() / px,
                                width: native.width, height: native.height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
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
                // Edge to edge. Phones wider than the Mac fill the height with room to spare beside the
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
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        if (!typing || consoleShown) && !controlsHidden {
            HStack {
                if consoleShown {
                    viewSwitch()
                } else {
                    tool("eye.slash", "Hide controls") { hideControls() }
                    Spacer()
                    if mac.guest == .linux {
                        viewSwitch()
                        Spacer()
                    }
                }
                tool("keyboard", "Keyboard") { typing.toggle() }
                Spacer()
                if mac.guest == .linux && !consoleShown {
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
        if !consoleShown { trackpadPanel(layout) }
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if compact {
                    Text("Trackpad").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("Drag", "to move")
                        hint("Tap", "to click")
                        hint("Hold, then drag", "to grab")
                        hint("Two fingers", "to scroll")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "Click", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "Right-click", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    /// A Linux desktop adds a menu for what to paste with: terminals want Ctrl-Shift-V. Details has the same choice.
    private func pasteTool(keysMenu: Bool = true) -> some View {
        HStack(spacing: 0) {
            PasteButton(payloadType: String.self) { texts in
                if let text = texts.first {
                    Sharing.paste(text, guest: mac.guest, console: consoleShown, keys: Sharing.PasteKeys(rawValue: pasteKeys) ?? .control)
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(Desk.raised)
            .accessibilityHint(mac.guest == .linux ? "Types the copied text into the machine" : "Pastes the copied text into the Mac")
            if mac.guest == .linux && !consoleShown && keysMenu {
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
        HengeLog.log("input", "touch input \(on ? "on" : "off")")
        henge_vm_set_touch_mode(on ? 1 : 0)
        if on {
            let ms = UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000))
            for id in Int32(1)...5 { henge_vm_touch(id, 2, 0, 0, ms) }
            henge_vm_touch_frame(ms)
            henge_vm_mouse_button(0, 0) // a drag in progress ends
        } else {
            henge_vm_screen_touch_cancel()
        }
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

    /// A Linux desktop says when the focused program wants text (henge-keyboard): the keyboard comes and goes with it.
    private func followGuestKeyboard() async {
        guard mac.guest == .linux else { return }
        KeyboardFrame.start() // before the console can hide the probe
        var seq: UInt = 0
        _ = henge_share_keyboard_wanted(&seq)
        keyboardFollow = KeyboardFollow(seq: seq)
        while !Task.isCancelled {
            let wanted = henge_share_keyboard_wanted(&seq) != 0
            // The console has the keys while it shows. A hardware keyboard needs no keyboard on the screen.
            let allowed = keyboardFollows && state == 1 && !consoleShown && GCKeyboard.coalesced == nil
            if let show = keyboardFollow.poll(wanted: wanted, seq: seq, typing: typing, allowed: allowed) { typing = show }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Linux: the screen and the serial console are both always there; this shows the other one.
    private func viewSwitch(tint: Color = Desk.text) -> some View {
        tool(consoleShown ? "display" : "terminal", consoleShown ? "Show the screen" : "Show the console", tint: tint) {
            zoomed = false
            controlsHidden = false
            consoleChoice = consoleShown ? .screen : .console
            var m = current
            m.showsConsole = consoleChoice == .console ? true : nil
            Machines.shared.update(m)
        }
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
        let roomy = Self.roomForKeysMenu(layout.touch.width) || mac.guest == .mac || consoleShown
        let pill = HStack(spacing: roomy ? 4 : 2) {
            if consoleShown {
                viewSwitch(tint: .white)
            } else {
                tool("eye.slash", "Hide controls", tint: .white) { hideControls() }
                if mac.guest == .linux { viewSwitch(tint: .white) }
            }
            tool("keyboard", "Keyboard", tint: .white) { typing.toggle() }
            if mac.guest == .linux && !consoleShown { inputSwitch(tint: .white) }
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
            if henge_vm_pointer(&x, &y) == 0 {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(guestScreen.width), y: CGFloat(y) / CGFloat(guestScreen.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / layoutAspect)) { map = UIImage(cgImage: image) }
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
        let bottom = typing ? (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? insets.bottom) : insets.bottom
        let room = wholeScreen(landscape: full.width > full.height) ? .zero
            : DisplayInsets(top: insets.top, left: insets.left, bottom: bottom, right: insets.right)
        let mode = DisplayModePolicy.phoneMode(window: full, insets: room, nativeScale: Device.nativeScale)
        guard mode != windowMode else { return }
        HengeLog.log("display", "window \(Int(full.width))x\(Int(full.height)) pt, safe insets t\(insets.top) l\(insets.left) b\(insets.bottom) (used \(bottom)) r\(insets.right), typing \(typing), "
                   + "scale \(Device.nativeScale) -> \(mode.w)x\(mode.h)")
        windowMode = mode
        guard var f = follower else { return }
        let pending = f.orientation(mode, now: ProcessInfo.processInfo.systemUptime)
        follower = f
        schedule(pending)
    }

    /// An external screen came or went: Linux follows its size; a Mac only remembers it (its size is fixed at boot).
    private func externalChanged(_ pixels: CGSize?) {
        if mac.guest == .mac {
            saveExternalScreen(pixels)
            return
        }
        HengeLog.log("display", "external screen \(pixels.map { "\(Int($0.width))x\(Int($0.height))" } ?? "gone")")
        applyLinuxScreen()
    }

    /// The screen choice changed in settings: Linux takes it at once.
    private func screenChoiceChanged() {
        guard mac.guest == .linux else { return }
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
        HengeLog.log("display", "linux screen choice -> guest \(mode.map { "\($0.w)x\($0.h)" } ?? "phone mode")")
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
                    henge_vm_set_display_scale(scale) // before the mode: the guest reads both when the mode event comes
                    henge_vm_set_display(UInt32(m.w), UInt32(m.h))
                    HengeLog.log("session", "linux screen \(m.w)x\(m.h) scale \(scale) (\(externalMode != nil ? "external" : "phone"))")
                    return
                }
                if f?.pending == nil { return }
            }
        }
    }

    private func saveExternalScreen(_ pixels: CGSize?) {
        guard let pixels else { return }
        let size = PixelSize(width: Int(pixels.width), height: Int(pixels.height))
        guard var current = Machines.shared.all.first(where: { $0.id == mac.id }), current.lastExternalScreen != size else { return }
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
            Text(mac.guest == .linux ? "This machine could not start" : "This Mac could not start").font(.system(size: 17, weight: .semibold))
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
                Text("\(mac.name) is taking a while. You can turn it off now; anything not saved on it is lost.")
                    .font(.system(size: 14)).foregroundStyle(Desk.dim)
                Button("Turn off now") {
                    henge_vm_stop()
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
        case 1: return userCode ? (mac.guest == .linux ? "Debian is running" : "macOS is running") : "Booting"
        case 3: return "Finishing shutdown…"
        default: return "Stopped (\(String(cString: henge_vm_exit_reason())))"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("CPUs on", value: "\(cpusOn) of \(cpus)")
                    LabeledContent("Temperature", value: Self.thermalLabel(thermalState))
                    LabeledContent("Translated blocks", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("Network frames", value: "\(framesOut) out, \(framesIn) in")
                    LabeledContent("Up", value: "\(Int(Date().timeIntervalSince(started))) s")
                }
                Section("Display") {
                    Toggle("Color matching", isOn: $matchScreenColors)
                    LabeledContent("Brightness", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("Brightness dims only the \(mac.noun)'s screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pointer") {
                    Picker("Size", selection: $cursorScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Sharp edges", isOn: $sharpCursor)
                    LabeledContent("Scroll speed", value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text("The \(mac.noun) supplies a small pointer image. Enlarging it can look blurry; 1× is the sharpest on an iPad. Scroll speed changes apply immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sharing") {
                    LabeledContent(mac.guest == .linux ? "Clipboard" : "Clipboard and folder", value: helperRunning ? "On" : mac.guest == .linux ? "Not running" : "Not set up")
                    if mac.guest == .mac && !helperRunning {
                        Button("Type the Set Up Command") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    if mac.guest == .linux {
                        Picker("Paste with", selection: $pasteKeys) {
                            Text("Ctrl-V").tag(Sharing.PasteKeys.control.rawValue)
                            Text("Ctrl-Shift-V (terminals)").tag(Sharing.PasteKeys.controlShift.rawValue)
                        }
                        Text(helperRunning
                             ? "What you copy in the guest is copied here too, and the paste button pastes from here into the guest. Paste with chooses Ctrl-V or Ctrl-Shift-V, which terminals want. When there is room, the arrow beside the paste button also chooses it."
                             : "The clipboard helper runs on a Debian desktop. Without it, and on the console, the paste button types the text into the guest.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                    Text(helperRunning
                         ? "Put files in Files, Henge, Shared to see them in the Henge folder in this Mac's home folder. What you copy on the Mac is copied here too, and the paste button pastes from here into the Mac."
                         : "Once for each Mac: open Terminal on the Mac, tap this, then press Return. When macOS asks about henge-agent and local networks, choose Allow. It types \(Sharing.setUpCommand) and needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if mac.guest == .mac {
                Section("Lighter macOS") {
                    Button("Type the Lighter macOS Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button("Type the Undo Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text("Less drawing for the emulated CPUs: window and Dock animations, desktop widgets, the screen saver and a moving wallpaper go. Open Terminal on the Mac, tap the button and press Return, then log out and back in. Also turn on Reduce Motion and Reduce Transparency in the Mac's System Settings, Accessibility. Undo puts it back, apart from the wallpaper. Needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                }
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
        henge_vm_screen_touch_cancel()
        controlsHidden = false
        showRevealHint = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        showWallpaperTip = false
        shutdownAsked = nil
        shutdownOverdue = false
        consoleChoice = current.showsConsole == true ? .console : .screen
        if mac.guest == .linux {
            console.reset()
            console.start()
        }
        while henge_vm_state() == 3 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let ram = GuestMemory.prepare(mac)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "There is not room for this \(mac.guest == .linux ? "machine" : "Mac")'s memory: it needs a few GB of free storage."
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        if mac.guest == .linux { DeviceStatus.shared.start { [display] in !display.isExternal } }
        EngineTuning.apply()
        let saved = current
        var macMM: (width: Int, height: Int) = saved.isRetina ? Device.retinaMM : (0, 0)
        if saved.guest == .linux {
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
            henge_vm_set_display_scale(guestScale(for: boot))
            henge_vm_set_display(UInt32(boot.w), UInt32(boot.h))
        } else {
            var screen = saved.screen
            macBootMode = nil // a restart must not keep the last external size
            var external: GuestMode?
            // macOS reads its size once, so a screen it ran on before gets a short wait to show up.
            if saved.lastExternalScreen != nil, saved.screenFollowsExternal == true || saved.screenWidth == nil, !saved.isRetina {
                external = await bootExternalMode()
                guard !Task.isCancelled else { return }
                if let ext = external { screen = (ext.w, ext.h); macBootMode = ext }
                else if saved.screenFollowsExternal == true, let r = saved.lastExternalScreen { // asked for it, but not connected
                    let ext = DisplayModePolicy.externalMode(pixels: CGSize(width: r.width, height: r.height))
                    screen = (ext.w, ext.h)
                    macBootMode = ext
                    external = ext
                }
            }
            if !saved.isRetina {
                let auto = external.map { DisplayModePolicy.guestScale(shortSide: min($0.w, $0.h), isPhone: false) == 2 } ?? false
                if saved.sharpText ?? auto { macMM = PixelSize(width: screen.width, height: screen.height).denseMM }
            }
            henge_vm_set_display(UInt32(screen.width), UInt32(screen.height))
        }
        let rc: Int32
        switch mac.guest {
        case .mac:
            henge_vm_set_display_mm(UInt32(macMM.width), UInt32(macMM.height))
            HengeLog.log("session", "screen \(guestScreen.width)x\(guestScreen.height) retina \(mac.isRetina) mm \(macMM.width)x\(macMM.height)")
            rc = henge_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus), &buffer, buffer.count)
        case .linux:
            HengeLog.log("session", "linux screen \(guestScreen.width)x\(guestScreen.height)\(current.followsPhoneScreen ? " (phone native, scale 2)" : "")\(mac.accel == true ? ", graphics acceleration" : "")")
            rc = henge_vm_boot_linux(mac.firmware.path, mac.disk.path, ram, Int32(cpus), mac.accel == true ? 1 : 0, &buffer, buffer.count)
        }
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        started = Date()
        var used = Machines.shared.all.first { $0.id == mac.id } ?? mac // keeps lastExternalScreen
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            if state == 3 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            if let asked = shutdownAsked, Date().timeIntervalSince(asked) >= 30 { shutdownOverdue = true }
            cpusOn = henge_vm_cpus_on()
            userCode = userCode || henge_vm_guest_el0() != 0
            let now = Date(), blocks = henge_vm_blocks()
            blocksPerSecond = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            framesOut = henge_vm_net_frames(1)
            framesIn = henge_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(HengeLog.recentLines(200))
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                thermalState = heat
                HengeLog.log("session", "thermal state: \(Self.thermalLabel(heat))")
            }
            if state == 2 {
                typing = false
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                let outcome = henge_vm_exit_outcome()
                if shutdownAsked != nil && outcome == Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue) {
                    close() // the person asked for it: no stopped card
                    break
                }
                HengeLog.log("session", "showing stopped machine: \(String(cString: henge_vm_exit_reason()))")
                if outcome == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", blocksPerSecond)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(framesOut), rx \(framesIn), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                             + "thermal \(Self.thermalLabel(heat))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 && mac.guest == .mac && !stillWallpaperTipShown { // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        if state == 1 { confirmStop = true } else { close() }
    }

    /// Linux pauses while the app is away, so iOS freezing it does not jump the guest's clock (RCU stalls).
    /// A Mac keeps running as before: the pause is not checked with macOS yet (T4).
    /// A machine with graphics acceleration always pauses, even while it plays sound: iOS allows no Metal work in the background.
    private func setBackground(_ away: Bool) {
        guard mac.guest == .linux else { return }
        let was = henge_vm_paused() != 0
        henge_vm_set_background(away ? 1 : 0) // sound keeps only a machine without acceleration running; it pauses when the sound stops
        let now = henge_vm_paused() != 0
        if now != was { HengeLog.log("session", now ? "paused in the background" : "resumed") }
    }

    private func finish() {
        if state == 1 {
            MacPreview.saveNow(for: mac)
            if mac.guest == .linux {
                henge_vm_power_button()
                shutdownAsked = Date()
                shutdownOverdue = false
                return // the run loop closes the view when the guest is off
            }
            henge_vm_stop()
        }
        close()
    }
}
