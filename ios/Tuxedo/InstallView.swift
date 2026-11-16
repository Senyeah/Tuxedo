// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// The Install tab: the Linux installer inside a page of its own.
struct InstallView: View {
    /// Starts a machine made here, from the finished screen.
    var start: (VirtualMachine) -> Void = { _ in }
    @ObservedObject private var linux = LinuxInstaller.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var jitReady = JITBootstrap.ready
    @State private var offeredFor: UUID? // the machine the setup prompt came up for, once
    @State private var promptShown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    LinuxInstallView(jitReady: jitReady, start: start)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .overlay(alignment: .bottom) { setupPrompt }
            .onChange(of: linux.phase) { _, phase in offerSetup(phase) }
            .onAppear { offerSetup(linux.phase) }
            .sensoryFeedback(.impact(weight: .light), trigger: promptShown) { _, shown in shown }
            .navigationTitle(linux.busy ? "Installing" : "Install Linux")
            .task {
                while !Task.isCancelled { // the region may be claimed after a hand-off to StikDebug
                    jitReady = JITBootstrap.ready
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
}

extension InstallView {
    @ViewBuilder fileprivate var setupPrompt: some View {
        if promptShown, case .installed(let id) = linux.phase, let machine = Machines.shared.all.first(where: { $0.id == id }) {
            SetupPrompt(name: machine.name,
                        blocker: jitReady ? nil : (JITBootstrap.lastFailure ?? "Turn on JIT to start it."),
                        setUp: {
                            SetupHint.request(machine.id)
                            promptShown = false
                            linux.reset()
                            start(machine)
                        },
                        dismiss: { withAnimation(.smooth) { promptShown = false } })
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .deskColumn()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The prompt rises a moment after the Installed screen, once for each new machine.
    fileprivate func offerSetup(_ phase: LinuxInstaller.Phase) {
        guard case .installed(let id) = phase else {
            promptShown = false
            return
        }
        guard offeredFor != id else { return }
        offeredFor = id
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard case .installed(id) = linux.phase else { return }
            withAnimation(.spring(duration: 0.6, bounce: 0.25)) { promptShown = true }
        }
    }
}

/// The last lines of Tuxedo's log.
struct LogTail: View {
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                lines = Array(TuxLog.recentLines(14))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
