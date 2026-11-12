import SwiftUI
import UIKit

/// The Linux side of the Install view: the catalogue and the downloads. Unpacking and creating the machine come with I8.
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
        case failed(String)
    }

    @Published private(set) var catalogue: Catalogue = .none
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var current: LinuxImage?
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0

    private var grace = UIBackgroundTaskIdentifier.invalid

    nonisolated static var folder: URL { LinuxDownload.folder(root: MachinePaths.root) }

    var busy: Bool { phase == .downloading || phase == .checking }

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

    func download(_ image: LinuxImage) {
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
                try checkSpace(image)
                Machines.excludeFromBackup(Machines.root)
                HengeLog.log("linux", "downloading \(image.id) \(image.version)")
                let throttle = ProgressThrottle()
                _ = try await LinuxDownload.fetch(image, in: Self.folder) { stage, have, total in
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
                phase = .downloaded
            } catch {
                HengeLog.log("linux", "failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
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
                Text("\(linux.phase == .checking ? "Checking" : "Downloading") \(ByteText.string(linux.received)) of \(ByteText.string(linux.expected))")
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
