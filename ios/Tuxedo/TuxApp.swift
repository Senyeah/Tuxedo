// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AVFAudio

@main
struct TuxApp: App {
    /// Answers for external display scenes before iOS 27 (LegacyExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(TuxAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Order matters: TuxLog takes over stderr, so the engine's and the JIT
        // allocator's first lines land in Documents/tux.log too.
        TuxLog.start()
        TuxLog.log("boot", "address space: \(tux_largest_reservation_gb()) GB can be reserved in one piece")
        EngineTuning.apply()
        TuxLog.logFootprint("app-launch")
        JITBootstrap.noteLaunchState()
        TuxLog.log("app", "increased memory limit: \(Entitlements.increasedMemory ? "yes" : "no"); extended addressing: \(Entitlements.extendedAddressing ? "yes" : "no"); limit \(Entitlements.memoryLimitAtLaunch >> 20) MB")
        // Without the guard, a brk no debugger answers kills the app instead of failing.
        JITBootstrap.installTrapGuard()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        Machines.shared.collectImports()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in TuxLog.log("app", "opened with \(url.absoluteString)") } // tux:// back from LocalDevVPN
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case machines, install, settings }

    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var running: VirtualMachine?
    @State private var tab = Tab.machines
    @State private var demo: AdditionsWizardRequest? // testing only: Autopilot additions-demo
    @State private var demoAdditions: TuxAdditions?
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                HomeView(running: $running, tab: $tab)
                    .tabItem { Label(MachineList.tabTitle, systemImage: "terminal") }
                    .tag(Tab.machines)
                InstallView(start: { machine in tab = .machines; running = machine })
                    .tabItem { Label("Install", systemImage: "arrow.down.circle") }
                    .tag(Tab.install)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            .tint(Desk.accentLight)
            if let running {
                SessionView(machine: running) { self.running = nil }
                    .environment(\.colorScheme, .dark) // still dark while it fades out over a light page
                    .transition(.opacity)
            }
        }
        .background(WindowStyle(style: running != nil ? .dark : appearance.style))
        .sheet(isPresented: $jit.showSetup) { JITSetupFlow() }
        .onReceive(NotificationCenter.default.publisher(for: Autopilot.additionsDemo)) { note in
            let arg = note.object as? String
            let switching = arg == "switch"
            let step = switching ? AdditionsStep.desktop : arg.flatMap(AdditionsStep.init(rawValue:))
            demoAdditions = TuxAdditions.demo(switching: switching)
            demo = AdditionsWizardRequest(step: step, intro: step == .account)
        }
        .fullScreenCover(item: $demo) { request in
            if let demoAdditions {
                AdditionsWizardView(additions: demoAdditions, request: request, typeCommand: { _ in }, close: { demo = nil })
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            machines.collectImports()
            jit.enableAtLaunchIfAsked()
            // StikDebug can launch Tuxedo before it attaches. A task also runs
            // on the first appearance, when there may be no phase change.
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if JITBootstrap.prewarmed || JITBootstrap.isLive {
                    jit.objectWillChange.send()
                    return
                }
                if JITBootstrap.debuggedFlag || JITBootstrap.canGrantOwnJIT {
                    JITBootstrap.prewarm()
                    // Readiness lives outside the observable coordinator.
                    jit.objectWillChange.send()
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return } // going into the background cancels this wait
            }
        }
        .onChange(of: jit.attachGeneration) { _ in JITBootstrap.prewarm() } // the built-in helper attached
        .task { // testing only: TUX_AUTOPILOT
            await Autopilot.run { machine in
                // A session still on screen (its machine stopped) is closed first: the same value again would start nothing.
                guard running != nil else { running = machine; return }
                running = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { running = machine }
            }
        }
    }
}

extension View {
    /// Husk's screens are written against an iOS 15 shim; Tuxedo needs iOS 17, so this is the real thing.
    func tuxDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        navigationDestination(for: data, destination: destination)
    }
}
