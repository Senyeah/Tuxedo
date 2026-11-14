import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    @AppStorage(VolumeClicks.swapKey) private var swapButtons = false
    @AppStorage(TrackpadFeel.hapticsKey) private var haptics = PadHaptics.Level.all
    @AppStorage(TrackpadFeel.motionKey) private var motionFeel = PadTuning.Motion().style
    @AppStorage(PhysicalMouseButtons.swapKey) private var swapMouseButtons = false
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage(LinuxCatalogue.urlKey) private var linuxCatalogueURL = ""
    @AppStorage(KeyboardFollow.storageKey) private var keyboardFollows = true

    /// The second footer paragraph: how you click, given the selected input mode.
    private var inputDescription: String {
        if inputMode == .touchscreen {
            return "Tap to click once. Tap then hold to begin dragging. Quickly tap with two fingers to right-click."
        }
        switch volumeMode {
        case .delayHold:
            return "Delay hold waits to see if you're holding or just clicking the volume button, which results in all clicks being ~0.5s long."
        case .tapThenDrag:
            return "Tap then drag waits to see if you're holding or just clicking the volume button, but it unconditionally sends a single click regardless of whether you tap or hold, which results in shorter clicks at the cost of sending a click before holding."
        case .intercept:
            return "Activates the camera in order to intercept volume keys properly. This causes the volume keys to behave in the same way a mouse's buttons do, but it causes higher temperatures, as the camera is always on."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("Status", value: JITBootstrap.ready ? "On" : "Off")
                    Picker("Method", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge uses \(jit.method.title).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Set up JIT") { jit.showSetup = true }
                    Toggle("Turn on JIT when Henge opens", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("Henge connects LocalDevVPN first when it is off, and comes back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Code region", value: "\(JITBootstrap.jitBytes >> 20) MB, claimed once per launch")
                }
                .listRowBackground(Desk.card)
                Section("Memory") {
                    LabeledContent("Extra memory", value: Entitlements.increasedMemory ? "On" : "Off")
                    LabeledContent("Henge's limit", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Free for Henge", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "A machine's memory is kept out of this limit once JIT is on. If iOS refuses that, it uses free storage instead."
                         : "This install isn't signed with the increased memory limit entitlement. Reinstall Henge with a certificate that has it. Export your machines first if the reinstall replaces the app's data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Mouse and Trackpad") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer speed")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scroll speed")
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Toggle("Swap physical right and middle buttons", isOn: $swapMouseButtons)
                        Text("Only enable this if your physical mouse's right and middle buttons are reversed in the guest. Touch controls stay unchanged. Restart the session to apply.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("A Magic Keyboard or a Bluetooth mouse moves the guest's pointer. Pointer speed changes apply the next time a machine starts; scroll speed changes apply immediately.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                if !Device.isPad {
                    Section("Trackpad") {
                        Picker("Input mode", selection: $inputMode) {
                            Text("Touchscreen").tag(VolumeClicks.InputMode.touchscreen)
                            Text("Volume buttons").tag(VolumeClicks.InputMode.volumeButtons)
                        }
                        .pickerStyle(.menu)
                        if inputMode == .volumeButtons {
                            Picker("Button mode", selection: $volumeMode) {
                                Text("Delay hold").tag(VolumeClicks.Mode.delayHold)
                                Text("Tap then drag").tag(VolumeClicks.Mode.tapThenDrag)
                                Text("Camera intercept").tag(VolumeClicks.Mode.intercept)
                            }
                            .pickerStyle(.menu)
                            Toggle("Swap buttons", isOn: $swapButtons)
                        }
                        Text("Henge is able to emulate a Magic Trackpad, allowing you to use native gestures, such as two-finger scrolling, on your device's touchscreen.\n\n\(inputDescription)\n\nIn both modes, a quick two-finger tap is a right-click. While the on-screen keyboard is up, a tap is a click.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Picker("Haptics", selection: $haptics) {
                            Text("All").tag(PadHaptics.Level.all)
                            Text("Clicks only").tag(PadHaptics.Level.clicksOnly)
                            Text("Off").tag(PadHaptics.Level.off)
                        }
                        .pickerStyle(.menu)
                        if haptics == .all {
                            Picker("Motion feel", selection: $motionFeel) {
                                Text("Texture").tag("texture")
                                Text("Ticks").tag("ticks")
                                Text("Off").tag("none")
                            }
                            .pickerStyle(.menu)
                        }
                        Text("All adds a soft tick when a finger touches the trackpad, and a feel that follows the finger as it speeds up, slows down or turns. Clicks only keeps the clicks and the trackpad's buttons. The system's own haptics setting also applies.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("On a Linux machine, the hand button in the session's controls (Use touch) makes the screen a touchscreen. Each machine keeps its own choice.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Performance") {
                    Toggle("Faster disk writes", isOn: $fastFlush)
                    Toggle("Quicker wake from idle", isOn: $wfiSpin)
                    Toggle("Superblocks (experimental)", isOn: $superblocks)
                    Picker("Code cache", selection: $codeCacheMB) {
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    Text("A bigger code cache empties less often and takes more memory; Henge picks 1.5 GB where there is room for it. Applies the next time Henge opens. If JIT stops turning on, choose 1 GB.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Faster disk writes order them without waiting for a full sync; a sudden power loss could lose the last ones. Quicker wake keeps an idle CPU watching for work for 50 µs, at some battery cost. Superblocks let translated code run past conditional branches. Changes apply the next time a machine starts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("System follows the \(Device.name)'s Light or Dark setting. Henge stays dark while a machine is running.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Linux keyboard") {
                    Toggle("Show the keyboard when Linux wants text", isOn: $keyboardFollows)
                    Text("The keyboard comes up when a text field or a terminal on the Linux desktop has the focus, and goes away after. Programs that run through XWayland do not ask for it: use the keyboard button for them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Linux images") {
                    TextField("Catalogue URL", text: $linuxCatalogueURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Where Henge reads the list of Linux images it can download (linux-images.json). Leave it empty to install Linux from a folder brought in from a computer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Log") {
                    ShareLink(item: HengeLog.logFileURL) { Label("Share henge.log", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Settings")
        }
    }
}
