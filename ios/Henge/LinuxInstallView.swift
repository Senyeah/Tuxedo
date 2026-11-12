import SwiftUI

/// The Linux side of the Install view: choose an image, then download, check, unpack and start it.
struct LinuxInstallView: View {
    @ObservedObject private var linux = LinuxInstaller.shared
    @AppStorage(LinuxCatalogue.urlKey) private var catalogueURL = ""
    let jitReady: Bool
    let start: (VirtualMac) -> Void

    @State private var selected: String?
    @State private var name = "Debian"
    @State private var ramGB = 2
    @State private var diskGB = Int(LinuxUnpack.defaultDiskBytes >> 30)
    @State private var deleteAfter = false
    @State private var refresh = 0 // redraws the list when a download is deleted
    @State private var details = false
    @State private var confirmDelete: LinuxImage?

    private static let stages = ["Download", "Check", "Unpack", "Finish"]

    var body: some View {
        Group {
            switch linux.phase {
            case .idle, .downloaded: chooser
            case .downloading, .checking, .decoding, .unpacking, .finishing: progress
            case .installed(let id): finished(id)
            case .failed(let text): failed(text)
            }
        }
        .task(id: catalogueURL) { await linux.refresh() }
    }

    private var images: [LinuxImage] {
        if case .loaded(let all) = linux.catalogue { return all }
        return []
    }

    private var image: LinuxImage? { images.first { $0.id == selected } ?? images.first }

    // MARK: Choosing

    @ViewBuilder private var chooser: some View {
        DeskHeading("Image")
        VStack(alignment: .leading, spacing: 0) {
            switch linux.catalogue {
            case .none:
                note(LinuxCatalogue.configuredURL == nil
                     ? "To download a Linux machine, Henge needs a catalogue URL: enter it in Settings. Or bring in a machine made on a computer: the + button on the Machines tab, then \"Bring in a machine from a computer\"."
                     : "")
                if LinuxCatalogue.configuredURL != nil { Button("Load the catalogue") { Task { await linux.refresh() } }.padding(17) }
            case .loading:
                ProgressView("Loading the catalogue…").frame(maxWidth: .infinity).padding(17)
            case .failed(let text):
                note(text)
                Button("Try again") { Task { await linux.refresh() } }.padding(.horizontal, 17).padding(.bottom, 14)
            case .loaded(let all):
                if all.isEmpty { note("The catalogue has no images.") }
                ForEach(all) { r in
                    HStack(spacing: 0) {
                        Button { selected = r.id } label: { row(r) }.buttonStyle(.plain)
                            .accessibilityAddTraits(image?.id == r.id ? .isSelected : [])
                        if LinuxDownload.present(r, in: LinuxInstaller.folder) > 0 {
                            Button { confirmDelete = r } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Desk.dim)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete the \(r.name) download")
                            .padding(.trailing, 6)
                        }
                    }
                    if r.id != all.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskCard()
        .id(refresh)
        .confirmationDialog("Delete this download?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Download", role: .destructive) {
                if let r = confirmDelete { linux.deleteDownload(r) }
                refresh += 1
            }
        }

        if let image {
            let minGB = LinuxUnpack.minDiskGB(for: image)
            DeskHeading("New Linux machine")
            VStack(spacing: 0) {
                TextField("Name", text: $name)
                    .font(.system(size: 16))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
                Stepper(value: $ramGB, in: Device.memoryChoices) {
                    HStack {
                        Text("Memory").font(.system(size: 16))
                        Spacer()
                        Text("\(ramGB) GB").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                if let text = Device.memoryNote(ramGB, guest: .linux) {
                    Text(text).font(.system(size: 13)).foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 17)
                        .padding(.bottom, 10)
                }
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
                Stepper(value: Binding(get: { max(diskGB, minGB) }, set: { diskGB = $0 }), in: minGB...512) {
                    HStack {
                        Text("Disk size").font(.system(size: 16))
                        Spacer()
                        Text("\(max(diskGB, minGB)) GB").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                Text("The disk grows as the guest writes to it. df -h in the guest shows this size.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.bottom, 10)
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
                Toggle("Delete the download after", isOn: $deleteAfter)
                    .font(.system(size: 16))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 10)
            }
            .deskCard()

            let have = LinuxDownload.haveAll(image, in: LinuxInstaller.folder)
            Button(have ? "Install" : "Download and Install") {
                linux.reset()
                linux.install(image, options: .init(name: name, ramMB: ramGB * 1024,
                                                    diskBytes: LinuxUnpack.diskBytes(chosen: Int64(max(diskGB, minGB)) << 30, for: image),
                                                    keepDownload: !deleteAfter))
            }
            .buttonStyle(DeskButtonStyle())
            .padding(.top, 20)
            let need = image.spaceNeeded(alreadyDownloaded: LinuxDownload.present(image, in: LinuxInstaller.folder))
            Text("Keep Henge open and the \(Device.name) plugged in. Needs about \(ByteText.string(need)) free.")
                .font(.system(size: 13))
                .foregroundStyle(Desk.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim).padding(17)
    }

    private func row(_ r: LinuxImage) -> some View {
        let part = LinuxDownload.present(r, in: LinuxInstaller.folder)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(r.name), \(r.version)").font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                Text("\(ByteText.string(r.downloadBytes)) download, \(ByteText.string(r.logicalBytes)) installed")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
                if LinuxDownload.haveAll(r, in: LinuxInstaller.folder) {
                    Text("Downloaded and checked").font(.system(size: 13)).foregroundStyle(Desk.good)
                } else if part > 0 {
                    Text("\(ByteText.string(part)) of \(ByteText.string(r.downloadBytes)) downloaded: goes on from there")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
            }
            Spacer()
            if image?.id == r.id { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Going

    private var stage: Int { linux.reached }

    private var fraction: Double { linux.expected > 0 ? min(Double(linux.received) / Double(linux.expected), 1) : 0 }

    private var verb: String {
        switch linux.phase {
        case .checking: return "Checking"
        case .decoding: return "Decompressing"
        case .unpacking: return "Unpacking"
        case .finishing: return "Finishing"
        default: return "Downloading"
        }
    }

    @ViewBuilder private var progress: some View {
        Text("\(linux.current?.name ?? "Linux") on this \(Device.name). Keep Henge open.")
            .font(.system(size: 16))
            .foregroundStyle(Desk.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 16)

        VStack(alignment: .leading, spacing: 0) {
            Text(stage == 3 ? "" : "\(Int(fraction * 100))%")
                .font(.system(size: 66, weight: .bold))
                .monospacedDigit()
                .frame(minHeight: 80, alignment: .leading)
            Text(stage == 3 ? "Finishing" : "\(verb) \(ByteText.string(linux.received)) of \(ByteText.string(linux.expected))")
                .font(.system(size: 15))
                .foregroundStyle(Desk.dim)
                .padding(.top, 2)
                .padding(.bottom, 16)
            DeskBar(fraction: stage == 3 ? 1 : fraction, height: 11)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskCard(radius: 30)

        DeskHeading("Steps")
        VStack(spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, title in
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: i == stage ? .semibold : .regular))
                        .foregroundStyle(i > stage ? Desk.faint : Desk.text)
                    Spacer()
                    if i < stage {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.good)
                    } else if i == stage {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
                if i < Self.stages.count - 1 { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()

        Button(details ? "Hide details" : "Show details") { withAnimation { details.toggle() } }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Desk.accentLight)
            .padding(.top, 14)
        if details {
            LogTail().padding(14).deskCard().padding(.top, 10)
        }
    }

    private func finished(_ id: UUID) -> some View {
        let mac = Machines.shared.all.first { $0.id == id }
        return VStack(spacing: 14) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Desk.good).padding(.top, 8)
                Text("Installed").font(.system(size: 24, weight: .bold))
                Text("\(mac?.name ?? "The machine") is ready to start.")
                    .font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .deskCard(radius: 30)

            if let mac {
                Button("Start") {
                    linux.reset()
                    start(mac)
                }
                .buttonStyle(DeskButtonStyle(enabled: jitReady))
                .disabled(!jitReady)
                if !jitReady {
                    Text(JITBootstrap.lastFailure ?? "Turn on JIT to start it.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
                }
            }
            Button("Done") { linux.reset() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Desk.accentLight)
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func failed(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("It did not work").font(.system(size: 22, weight: .bold))
            Text(text).font(.system(size: 15))
            Button("Back") { linux.reset() }.buttonStyle(DeskButtonStyle()).padding(.top, 6)
        }
        .padding(18)
        .deskCard(radius: 30)
        .padding(.top, 8)
        DeskHeading("Log")
        LogTail().padding(14).frame(maxWidth: .infinity, alignment: .leading).deskCard()
    }
}
