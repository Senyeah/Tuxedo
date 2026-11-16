// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Your machine as you left it, and one big button.
struct HomeView: View {
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Binding var running: VirtualMachine?
    @Binding var tab: RootView.Tab
    @State private var picking = false
    @State private var jitReady = JITBootstrap.ready
    @State private var chosen: UUID?

    /// The machine on show: the one picked, or the one used last.
    private var machine: VirtualMachine? {
        if let chosen, let machine = machines.all.first(where: { $0.id == chosen }) { return machine }
        return machines.all.max { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    notices
                    if let machine {
                        MachineHero(machine: machine, jitReady: jitReady, start: { running = machine }, turnOnJIT: { jit.enable() },
                                jitNote: jitReady ? nil
                                    : jit.busy ? (jit.status ?? "Turning on JIT…")
                                    : (JITBootstrap.lastFailure ?? jit.automaticDescription),
                                jitBusy: jit.busy)
                        HStack(spacing: 10) {
                            FactTile(title: "Disk", value: ByteText.string(UInt64(max(machine.bytesUsed, 0))))
                            FactTile(title: "Last used", value: machine.lastUsedText)
                        }
                        others(besides: machine)
                    } else {
                        firstMachine
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle("Tuxedo")
            .navigationDestination(for: VirtualMachine.self) { MachineSettingsView(machine: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Install Linux…") { tab = .install }
                        Button("Bring in a machine from a computer…") { picking = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a machine")
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { machines.importFolder(url) }
            }
            .task {
                while !Task.isCancelled { // the region may be claimed after a hand-off to StikDebug
                    jitReady = JITBootstrap.ready
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if Device.chipTooOld {
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: Device.chipTooOldText, tint: Desk.bad)
        }
        if let name = machines.importing {
            NoticeRow(symbol: "square.and.arrow.down.fill",
                      text: machines.unpacked > 0 ? String(format: "Unpacking %@'s disk… %.0f%%", name, machines.unpacked * 100) : "Bringing in \(name)…")
        }
        if let error = machines.lastError {
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: error, tint: Desk.bad)
        }
    }

    private var firstMachine: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Desk.accentLight)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(Desk.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("No machine yet").font(.system(size: 24, weight: .bold))
            Text("Install Linux on this \(Device.name), or bring in a machine made on a computer.")
                .font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            Button("Install Linux") { tab = .install }.buttonStyle(DeskButtonStyle())
            Button("Bring in a machine") { picking = true }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private func others(besides shown: VirtualMachine) -> some View {
        let rest = machines.all.filter { $0.id != shown.id }
        if !rest.isEmpty {
            DeskHeading(MachineList.othersHeading)
            VStack(spacing: 0) {
                ForEach(rest) { other in
                    Button { chosen = other.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                                Text(other.summary).font(.system(size: 13)).foregroundStyle(Desk.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    if other.id != rest.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()
        }
    }
}

extension VirtualMachine {
    var bytesUsed: Int64 {
        Int64((try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }

    var lastUsedText: String {
        guard let lastUsed else { return "Never" }
        if Calendar.current.isDateInToday(lastUsed) { return "Today" }
        if Calendar.current.isDateInYesterday(lastUsed) { return "Yesterday" }
        return lastUsed.formatted(.dateTime.month(.abbreviated).day())
    }

    var summary: String {
        var parts: [String] = []
        parts.append(osName ?? "Linux")
        parts.append("\(MemoryAmount.text(ramMB)) GB")
        return parts.joined(separator: " · ")
    }
}

/// The picture of the machine, its name, and Start.
private struct MachineHero: View {
    let machine: VirtualMachine
    let jitReady: Bool
    let start: () -> Void
    let turnOnJIT: () -> Void
    let jitNote: String?
    let jitBusy: Bool
    @AppStorage("tux.cpus") private var cpus = 4

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: machine) {
                VStack(spacing: 0) {
                    preview
                    HStack {
                        Text(machine.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1)
                        Spacer()
                        Text(jitReady ? "JIT on" : "JIT off")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(jitReady ? Desk.good : Desk.warn)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background((jitReady ? Desk.good : Desk.warn).opacity(0.13), in: Capsule())
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                    }
                    .padding(.top, 15)
                    .padding(.horizontal, 5)
                    Text("\(machine.summary) · \(machine.cpuCount(fallback: cpus)) CPUs")
                        .font(.system(size: 15))
                        .foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 3)
                }
            }
            .buttonStyle(.plain)
            if jitReady {
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(DeskButtonStyle())
                .padding(.top, 15)
            } else {
                if let jitNote {
                    Text(jitNote).font(.system(size: 13)).foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 10)
                }
                Button(action: turnOnJIT) {
                    if jitBusy {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Turning On JIT…")
                        }
                    } else {
                        Text("Turn On JIT")
                    }
                }
                .buttonStyle(DeskButtonStyle())
                .disabled(jitBusy)
                .padding(.top, 15)
            }
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private var preview: some View {
        let image = UIImage(contentsOfFile: MachinePreview.file(for: machine).path)
        ZStack {
            Desk.raised.opacity(0.5)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Desk.faint)
            }
        }
        .aspectRatio(image.map { MachinePreview.aspect(of: $0, fallback: machine.aspect) } ?? machine.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct FactTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13)).foregroundStyle(Desk.dim)
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .deskCard()
    }
}

struct NoticeRow: View {
    let symbol: String
    let text: String
    var trailing: String?
    var tint: Color = Desk.accentLight

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.text).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(14)
        .deskCard()
    }
}
