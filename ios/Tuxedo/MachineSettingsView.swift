// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// One machine: what it has, and what can be done with it.
struct MachineSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var machine: VirtualMachine
    @State private var confirmDelete = false
    @State private var movingExport = false
    @AppStorage("tux.cpus") private var globalCpus = 4
    @State private var growToGB = 0 // 0: no change picked
    @State private var confirmGrow = false
    @State private var growError: String?

    init(machine: VirtualMachine) { _machine = State(initialValue: machine) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Name")
                TextField("Name", text: $machine.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                DeskHeading("Memory")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(MemoryAmount.text(machine.ramMB)) GB").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text(Entitlements.increasedMemory ? "Outside the app's limit once JIT is on" : "Used from free storage if needed")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.trailing)
                    }
                    MemoryField(mb: $machine.ramMB, commit: save)
                    if let note = Device.memoryNote(mb: machine.ramMB) {
                        Text(note).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Processors")
                Stepper(value: Binding(get: { machine.cpuCount(fallback: globalCpus) }, set: { machine.cpus = $0; save() }), in: VirtualMachine.cpuRange) {
                    HStack {
                        Text("CPUs").font(.system(size: 16))
                        Spacer()
                        Text("\(machine.cpuCount(fallback: globalCpus))").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .deskCard()

                DeskHeading("Screen")
                if Device.isPad { padScreen } else { linuxScreen }
                DeskHeading("Graphics")
                graphics

                DeskHeading("Disk size")
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text("\(usedText) used").font(.system(size: 16))
                        Spacer()
                        Text("of \(sizeText)").font(.system(size: 16)).foregroundStyle(Desk.dim)
                    }
                    DeskBar(fraction: Double(machine.bytesUsed) / Double(max(diskBytes, 1)))
                    growControls
                }
                .padding(17)
                .deskCard()

                FoldersSection(machine: machine.id)
                ForwardsSection(machine: machine.id)

                DeskHeading("Manage")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(machine.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(machine.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
    }

    /// What a Linux machine on an iPhone can pick; changes apply at once.
    private enum LinuxScreen: Hashable { case phone, external, qhd, fhd }

    private var linuxChoice: LinuxScreen? {
        if machine.screenWidth == nil { return machine.screenFollowsExternal == true ? .external : .phone }
        switch PixelSize(width: machine.screenWidth ?? 0, height: machine.screenHeight ?? 0) {
        case ScreenPreset.qhd: return .qhd
        case ScreenPreset.fhd: return .fhd
        default: return nil
        }
    }

    private func pickLinux(_ choice: LinuxScreen) {
        machine.screenFollowsExternal = choice == .external ? true : nil
        switch choice {
        case .phone, .external: (machine.screenWidth, machine.screenHeight) = (nil, nil)
        case .qhd: (machine.screenWidth, machine.screenHeight) = (ScreenPreset.qhd.width, ScreenPreset.qhd.height)
        case .fhd: (machine.screenWidth, machine.screenHeight) = (ScreenPreset.fhd.width, ScreenPreset.fhd.height)
        }
        save()
    }

    @ViewBuilder private var linuxScreen: some View {
        let rows: [(LinuxScreen, String)] = [(.phone, "This iPhone"), (.external, "External display"),
                                              (.qhd, "2560 × 1440"), (.fhd, "1920 × 1080")]
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { divider }
                Button { pickLinux(row.0) } label: {
                    HStack {
                        Text(row.1).font(.system(size: 16)).foregroundStyle(Desk.text)
                        Spacer()
                        if linuxChoice == row.0 { Image(systemName: "checkmark").foregroundStyle(Desk.accentLight) }
                    }
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(linuxChoice == row.0 ? .isSelected : [])
            }
        }
        .deskCard()
        Text(linuxScreenNote).font(.system(size: 13)).foregroundStyle(Desk.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.top, 8)
        if linuxChoice == .phone {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use the whole screen", isOn: Binding(get: { machine.wholeScreen ?? false }, set: { machine.wholeScreen = $0 ? true : nil; save() }))
                    .font(.system(size: 16))
                Text("Upright, the status bar hides and the desktop goes under it and the home bar. The rounded corners and the camera cut-out hide parts of it. Applies at once.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            .padding(17)
            .deskCard()
            .padding(.top, 10)
        }
    }

    private var linuxScreenNote: String {
        switch linuxChoice {
        case .phone?: return "The size of this iPhone's screen, in either orientation. A connected external display takes over. Applies at once."
        case .external?: return machine.lastExternalScreen.map { "The external display's size, \($0.width) × \($0.height) when it was last connected. Applies at once." }
            ?? "The external display's size. Connect one once and this machine remembers it. Applies at once."
        default: return "\(machine.screen.width) × \(machine.screen.height), whatever screen is connected. Applies at once."
        }
    }

    private var padScreenChoice: String {
        if machine.screenFollowsExternal == true { return "external" }
        if machine.screen.width == Device.performanceScreen.width, machine.screen.height == Device.performanceScreen.height { return "performance" }
        if machine.screen.width == 1920, machine.screen.height == 1080, Device.fittingScreen.height != 1080 { return "wide" }
        return "fit"
    }

    @ViewBuilder private var padScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Screen", selection: Binding(get: { padScreenChoice }, set: { choice in
                machine.screenFollowsExternal = choice == "external" ? true : nil
                switch choice {
                case "external": (machine.screenWidth, machine.screenHeight) = (nil, nil)
                case "performance": (machine.screenWidth, machine.screenHeight) = Device.performanceScreen
                case "wide": (machine.screenWidth, machine.screenHeight) = (1920, 1080)
                default: (machine.screenWidth, machine.screenHeight) = Device.fittingScreen
                }
                save()
            })) {
                if Device.isPad { Text("Performance").tag("performance") }
                Text("Fit this \(Device.name)").tag("fit")
                if Device.fittingScreen.height != 1080 { Text("16:9").tag("wide") }
                Text("External display").tag("external")
            }
            .pickerStyle(.segmented)
            Text(padScreenNote).font(.system(size: 13)).foregroundStyle(Desk.dim)
        }
        .padding(17)
        .deskCard()
    }

    private var padScreenNote: String {
        let later = "Changes apply the next time this machine starts."
        if padScreenChoice == "external" {
            let size = machine.lastExternalScreen.map { "\($0.width) × \($0.height) when it was last connected" } ?? "none remembered yet: connect one once"
            return "The external display's size (\(size)). Without it, \(machine.screen.width) × \(machine.screen.height). \(later)"
        }
        return "\(machine.screen.width) × \(machine.screen.height). \(Device.isPad ? "Performance renders about 30% fewer pixels. " : "")\(later)"
    }

    private var graphics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Graphics acceleration", isOn: Binding(get: { machine.accel ?? false }, set: { machine.accel = $0; save() }))
                .font(.system(size: 16))
            Text("The guest draws 3D and its desktop on this \(Device.name)'s GPU (OpenGL ES 3.0). It takes more memory, and a graphics fault can stop the machine. In the background the whole machine pauses, even while it plays sound, so its sound stops. Experimental. Applies the next time this machine starts.")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
            if machine.accel == true {
                Toggle("Video decode", isOn: Binding(get: { machine.video ?? false }, set: { machine.video = $0; save() }))
                    .font(.system(size: 16))
                    .padding(.top, 8)
                Text("This \(Device.name)'s video decoder then parses data that the guest controls (H.264, VP9 and AV1 through VA-API). Applies the next time this machine starts.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Toggle("Video encode", isOn: Binding(get: { machine.encode ?? false }, set: { machine.encode = $0; save() }))
                .font(.system(size: 16))
                .padding(.top, 8)
            Text("This \(Device.name)'s video codecs then take data that the guest controls (ffmpeg from tux-ffmpeg). Applies the next time this machine starts.")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
        }
        .padding(17)
        .deskCard()
    }

    private var diskBytes: Int64 { machine.logicalDiskBytes }
    private var diskGB: Int { Int((diskBytes + (1 << 30) - 1) >> 30) }
    private var growTarget: Int { max(growToGB, diskGB) }
    // Linux sizes are in GB of 2^30 bytes, like Memory and the grow stepper.
    private var usedText: String { String(format: "%.1f GB", Double(max(machine.bytesUsed, 0)) / Double(1 << 30)) }
    private var sizeText: String { "\(diskGB) GB" }

    @ViewBuilder private var growControls: some View {
        Stepper(value: Binding(get: { growTarget }, set: { growToGB = $0 }), in: diskGB...max(diskGB + 1, 512), step: 4) {
            Text("Grow to \(growTarget) GB").font(.system(size: 16))
        }
        .confirmationDialog("Grow the disk to \(growTarget) GB?", isPresented: $confirmGrow, titleVisibility: .visible) {
            Button("Grow Disk", action: grow)
        } message: {
            Text("A disk cannot shrink again. Linux uses the new space the next time it starts.")
        }
        if growTarget > diskGB {
            Button("Grow Disk…") { confirmGrow = true }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        if let growError { Text(growError).font(.system(size: 13)).foregroundStyle(Desk.bad) }
        Text("A disk can only grow, and only while the machine is off.").font(.system(size: 13)).foregroundStyle(Desk.dim)
    }

    private func grow() {
        growError = nil
        guard growTarget > diskGB else { return }
        let state = tux_vm_state()
        guard state != 1 && state != 3 else { growError = "Turn this machine off first."; return }
        do {
            try DiskGrowth.grow(machine.disk, toBytes: Int64(growTarget) << 30)
            machine.diskBytes = machine.logicalDiskBytes
            growToGB = 0
            save()
            TuxLog.log("machines", "grew \(machine.name)'s disk to \(machine.diskBytes >> 30) GB")
        } catch {
            growError = error.localizedDescription
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Exporting \(name)… keep Tuxedo open").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else {
                row("Export", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(machine) }
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved in Files, under Tuxedo, Exports, \(folder.lastPathComponent). Deleting Tuxedo deletes it too, so move it somewhere else first.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Move Out of Tuxedo…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            divider
            row("Delete this machine", symbol: nil, tint: Desk.bad) { confirmDelete = true }
        }
        .deskCard()
    }

    private var divider: some View { Rectangle().fill(Desk.hairline).frame(height: 0.5) }

    private func row(_ title: String, symbol: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                Spacer()
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func save() {
        if machine.name.isEmpty { machine.name = "Linux" }
        machines.update(machine)
    }
}
