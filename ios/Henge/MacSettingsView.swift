import SwiftUI

/// One Mac: what it has, and what can be done with it.
struct MacSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var confirmDelete = false
    @State private var movingExport = false
    @AppStorage("henge.cpus") private var globalCpus = 4
    @State private var growToGB = 0 // 0: no change picked
    @State private var confirmGrow = false
    @State private var growError: String?

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Name")
                TextField("Name", text: $mac.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                DeskHeading("Memory")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(mac.ramMB / 1024) GB").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text(Entitlements.increasedMemory ? "Outside the app's limit once JIT is on" : "Used from free storage if needed")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.trailing)
                    }
                    Stepper("Memory", value: Binding(get: { mac.ramMB / 1024 }, set: { mac.ramMB = $0 * 1024; save() }), in: Device.memoryChoices)
                        .font(.system(size: 16))
                    if let note = Device.memoryNote(mac.ramMB / 1024, guest: mac.guest) {
                        Text(note).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Processors")
                Stepper(value: Binding(get: { mac.cpuCount(fallback: globalCpus) }, set: { mac.cpus = $0; save() }), in: VirtualMac.cpuRange) {
                    HStack {
                        Text("CPUs").font(.system(size: 16))
                        Spacer()
                        Text("\(mac.cpuCount(fallback: globalCpus))").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .deskCard()

                if Device.fittingScreen.height != 1080 {
                    DeskHeading("Screen")
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Screen", selection: Binding(get: {
                            if mac.isRetina { return "retina" }
                            if mac.screen.width == Device.performanceScreen.width,
                               mac.screen.height == Device.performanceScreen.height { return "performance" }
                            if mac.screen.width == 1920, mac.screen.height == 1080 { return "wide" }
                            return "fit"
                        }, set: { choice in
                            mac.retina = choice == "retina"
                            switch choice {
                            case "retina": break
                            case "performance": (mac.screenWidth, mac.screenHeight) = Device.performanceScreen
                            case "wide": (mac.screenWidth, mac.screenHeight) = (1920, 1080)
                            default: (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
                            }
                            save()
                        })) {
                            if Device.isPad {
                                if mac.guest == .mac { Text("Retina").tag("retina") }
                                Text("Performance").tag("performance")
                            }
                            Text("Fit this \(Device.name)").tag("fit")
                            Text("16:9").tag("wide")
                        }
                        .pickerStyle(.segmented)
                        Text("\(mac.screen.width) × \(mac.screen.height). \(Device.isPad ? "Performance renders about 30% fewer pixels. " : "")Changes apply the next time this \(mac.noun) starts.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                } else if mac.guest == .linux { // nothing to pick on this shape, but the size is still worth showing
                    DeskHeading("Screen")
                    Text("\(mac.screen.width) × \(mac.screen.height)").font(.system(size: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .deskCard()
                }

                DeskHeading(mac.guest == .linux ? "Disk size" : "Storage")
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text("\(usedText) used").font(.system(size: 16))
                        Spacer()
                        Text("of \(sizeText)").font(.system(size: 16)).foregroundStyle(Desk.dim)
                    }
                    DeskBar(fraction: Double(mac.bytesUsed) / Double(max(diskBytes, 1)))
                    if mac.guest == .linux { growControls }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Manage")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
    }

    private var diskBytes: Int64 { mac.guest == .linux ? mac.logicalDiskBytes : mac.diskBytes }
    private var diskGB: Int { Int((diskBytes + (1 << 30) - 1) >> 30) }
    private var growTarget: Int { max(growToGB, diskGB) }
    // Linux sizes are in GB of 2^30 bytes, like Memory and the grow stepper.
    private var usedText: String { mac.guest == .linux ? String(format: "%.1f GB", Double(max(mac.bytesUsed, 0)) / Double(1 << 30)) : ByteText.string(UInt64(max(mac.bytesUsed, 0))) }
    private var sizeText: String { mac.guest == .linux ? "\(diskGB) GB" : ByteText.string(UInt64(max(diskBytes, 0))) }

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
        let state = henge_vm_state()
        guard state != 1 && state != 3 else { growError = "Turn this machine off first."; return }
        do {
            try DiskGrowth.grow(mac.disk, toBytes: Int64(growTarget) << 30)
            mac.diskBytes = mac.logicalDiskBytes
            growToGB = 0
            save()
            HengeLog.log("machines", "grew \(mac.name)'s disk to \(mac.diskBytes >> 30) GB")
        } catch {
            growError = error.localizedDescription
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Exporting \(name)… keep Henge open").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else {
                row("Export", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(mac) }
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved in Files, under Henge, Exports, \(folder.lastPathComponent). Deleting Henge deletes it too, so move it somewhere else first.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Move Out of Henge…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            divider
            row("Delete this \(mac.noun)", symbol: nil, tint: Desk.bad) { confirmDelete = true }
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
        if mac.name.isEmpty { mac.name = mac.guest == .linux ? "Linux" : "Mac" }
        machines.update(mac)
    }
}
