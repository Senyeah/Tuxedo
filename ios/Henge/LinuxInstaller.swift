import SwiftUI
import UIKit

/// The Linux side of the Install view: the catalogue, the downloads, and making a machine from one.
@MainActor
final class LinuxInstaller: ObservableObject {
    static let shared = LinuxInstaller()

    enum Catalogue: Equatable {
        case none
        case loading
        case loaded([LinuxImage])
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case downloading
        case checking
        case downloaded
        case decoding
        case unpacking
        case finishing
        case installed(UUID)
        case failed(String)
    }

    /// What the user chose for the new machine.
    struct Options {
        var name: String
        var ramMB: Int
        var diskBytes: Int64
        var keepDownload: Bool
    }

    @Published private(set) var catalogue: Catalogue = .none
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var current: LinuxImage?
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0

    private var grace = UIBackgroundTaskIdentifier.invalid

    nonisolated static var folder: URL { LinuxDownload.folder(root: MachinePaths.root) }

    var busy: Bool { [.downloading, .checking, .decoding, .unpacking, .finishing].contains(phase) }

    func refresh() async {
        guard let url = LinuxCatalogue.configuredURL else { catalogue = .none; return }
        catalogue = .loading
        do {
            let images = try await LinuxCatalogue.fetch(url)
            catalogue = .loaded(images)
            HengeLog.log("linux", "catalogue: \(images.count) images from \(url.absoluteString)")
        } catch {
            catalogue = .failed(error.localizedDescription)
            HengeLog.log("linux", "catalogue failed: \(error.localizedDescription)")
        }
    }

    func reset() { if !busy { phase = .idle; current = nil } }

    func download(_ image: LinuxImage) { run(image, options: nil) }

    /// Downloads what is missing, then unpacks it into a new machine in the list.
    func install(_ image: LinuxImage, options: Options) { run(image, options: options) }

    private func run(_ image: LinuxImage, options: Options?) {
        guard !busy else { return }
        current = image
        phase = .downloading
        received = LinuxDownload.present(image, in: Self.folder)
        expected = image.downloadBytes
        UIApplication.shared.isIdleTimerDisabled = true
        grace = UIApplication.shared.beginBackgroundTask(withName: "Henge Linux download") {
            MainActor.assumeIsolated { LinuxInstaller.shared.endGrace() }
        }
        LinuxDownload.log = { HengeLog.log("linux", $0) }
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; endGrace() }
            do {
                try LinuxCatalogue.checkBuild(image, appBuild: LinuxCatalogue.appBuild)
                if let options { try LinuxUnpack.checkDisk(options.diskBytes, for: image) }
                try checkSpace(image)
                Machines.excludeFromBackup(Machines.root)
                HengeLog.log("linux", "downloading \(image.id) \(image.version)")
                let throttle = ProgressThrottle()
                let files = try await LinuxDownload.fetch(image, in: Self.folder) { stage, have, total in
                    guard throttle.allow(stage == .check || have >= total) else { return }
                    Task { @MainActor in
                        let me = LinuxInstaller.shared
                        guard me.busy, me.current?.id == image.id else { return } // a late update after the end
                        me.phase = stage == .download ? .downloading : .checking
                        me.received = have
                        me.expected = total
                    }
                }
                Machines.excludeFromBackup(Self.folder)
                HengeLog.log("linux", "\(image.id) downloaded and checked")
                guard let options else { phase = .downloaded; return }
                let mac = try await make(image, files: files, options: options)
                phase = .installed(mac.id)
            } catch {
                HengeLog.log("linux", "failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Unpacks into a new machine folder, lists it, and deletes the download unless it is kept.
    private func make(_ image: LinuxImage, files: LinuxDownload.Files, options: Options) async throws -> VirtualMac {
        try checkUnpackSpace(image)
        let name = options.name.trimmingCharacters(in: .whitespaces)
        var mac = VirtualMac(name: name.isEmpty ? "Debian" : name, ecid: 0, seed: 0, ramMB: options.ramMB, diskBytes: options.diskBytes)
        mac.kind = .linux
        mac.osName = image.name
        phase = .decoding
        received = 0
        expected = image.diskBytes
        let throttle = ProgressThrottle()
        let dir = mac.directory, bytes = options.diskBytes, planned = mac
        HengeLog.log("linux", "making \(mac.name): \(ByteText.string(UInt64(bytes))) disk, \(options.ramMB) MB")
        try await Task.detached {
            try LinuxUnpack.make(image, files: files, into: dir, mac: planned, diskBytes: bytes) { stage, done, total in
                guard throttle.allow(done >= total) else { return }
                Task { @MainActor in
                    let me = LinuxInstaller.shared
                    guard me.busy, me.current?.id == image.id else { return }
                    me.phase = stage == .decode ? .decoding : .unpacking
                    me.received = done
                    me.expected = total
                }
            }
        }.value
        phase = .finishing
        mac.diskBytes = mac.logicalDiskBytes
        Machines.shared.add(mac)
        if !options.keepDownload {
            var others: [LinuxImage] = []
            if case .loaded(let all) = catalogue { others = all }
            LinuxDownload.delete(image, in: Self.folder, others: others)
        }
        HengeLog.log("linux", "made \(mac.name) (\(mac.id)), \(ByteText.string(UInt64(mac.diskBytes))) disk")
        return mac
    }

    func deleteDownload(_ image: LinuxImage) {
        guard !busy else { return }
        var others: [LinuxImage] = []
        if case .loaded(let all) = catalogue { others = all }
        LinuxDownload.delete(image, in: Self.folder, others: others)
        objectWillChange.send()
    }

    private func checkSpace(_ image: LinuxImage) throws {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        try LinuxCatalogue.checkSpace(image, free: free, alreadyDownloaded: LinuxDownload.present(image, in: Self.folder))
    }

    private func checkUnpackSpace(_ image: LinuxImage) throws {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        try LinuxCatalogue.checkUnpackSpace(image, free: free)
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }
}

/// Lets about 5 progress updates per second through, so the main actor does not queue one per chunk.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func allow(_ force: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard force || now.timeIntervalSince(last) >= 0.2 else { return false }
        last = now
        return true
    }
}

/// The Linux images card in the Install view.
struct LinuxImagesSection: View {
    @ObservedObject private var linux = LinuxInstaller.shared
    @AppStorage(LinuxCatalogue.urlKey) private var catalogueURL = ""

    var body: some View {
        DeskHeading("Linux images")
        VStack(alignment: .leading, spacing: 0) {
            switch linux.catalogue {
            case .none:
                note(LinuxCatalogue.configuredURL == nil
                     ? "To download a Linux machine, Henge needs a catalogue URL: enter it in Settings. Or bring in a machine made on a computer: the + button on the Machines tab, then \"Bring in a machine from a computer\"."
                     : "")
                if LinuxCatalogue.configuredURL != nil { Button("Load the catalogue") { Task { await linux.refresh() } }.padding(17) }
            case .loading:
                ProgressView("Loading the catalogue…").padding(17)
            case .failed(let text):
                note(text)
                Button("Try again") { Task { await linux.refresh() } }.padding(.horizontal, 17).padding(.bottom, 14)
            case .loaded(let images):
                ForEach(images) { image in
                    row(image)
                    if image.id != images.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
        }
        .deskCard()
        .task(id: catalogueURL) { await linux.refresh() }
    }

    private static func verb(_ phase: LinuxInstaller.Phase) -> String {
        switch phase {
        case .checking: return "Checking"
        case .decoding: return "Decompressing"
        case .unpacking: return "Unpacking"
        case .finishing: return "Finishing"
        default: return "Downloading"
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim).padding(17)
    }

    @ViewBuilder private func row(_ image: LinuxImage) -> some View {
        let mine = linux.current == image
        let have = LinuxDownload.haveAll(image, in: LinuxInstaller.folder)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(image.name), \(image.version)").font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
            Text("\(ByteText.string(image.downloadBytes)) download, \(ByteText.string(image.logicalBytes)) installed")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
            if mine, linux.busy {
                DeskBar(fraction: linux.expected > 0 ? Double(linux.received) / Double(linux.expected) : 0, height: 8)
                Text("\(Self.verb(linux.phase)) \(ByteText.string(linux.received)) of \(ByteText.string(linux.expected))")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            } else if mine, case .failed(let text) = linux.phase {
                Text(text).font(.system(size: 13)).foregroundStyle(.red)
            }
            HStack {
                if have {
                    Text("Downloaded and checked").font(.system(size: 13)).foregroundStyle(Desk.good)
                    Spacer()
                    Button("Delete") { linux.deleteDownload(image) }.disabled(linux.busy)
                } else {
                    let part = LinuxDownload.present(image, in: LinuxInstaller.folder)
                    Button(part > 0 ? "Go on downloading" : "Download") { linux.download(image) }.disabled(linux.busy)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
    }
}
