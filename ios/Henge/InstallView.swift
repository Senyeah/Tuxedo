import SwiftUI

/// The Install tab: the Linux installer inside a page of its own.
struct InstallView: View {
    /// Starts a machine made here, from the finished screen.
    var start: (VirtualMac) -> Void = { _ in }
    @ObservedObject private var linux = LinuxInstaller.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var jitReady = JITBootstrap.ready

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

/// The last lines of Henge's log.
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
                lines = Array(HengeLog.recentLines(14))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
