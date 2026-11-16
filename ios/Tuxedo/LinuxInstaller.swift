// SPDX-License-Identifier: GPL-2.0-or-later
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
    @Published private(set) var phase: Phase = .idle {
        didSet { if let n = Self.stage(phase) { reached = max(reached, n) } }
    }
    /// The furthest of the four Install steps so far: the download and its check alternate for firmware and disk.
    private(set) var reached = 0
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
            TuxLog.log("linux", "catalogue: \(images.count) images from \(url.absoluteString)")
        } catch {
            catalogue = .failed(error.localizedDescription)
            TuxLog.log("linux", "catalogue failed: \(error.localizedDescription)")
        }
    }

    /// Download 0, Check 1, Unpack 2 (decode and unpack), Finish 3.
    static func stage(_ phase: Phase) -> Int? {
        switch phase {
        case .downloading: return 0
        case .checking: return 1
        case .decoding, .unpacking: return 2
        case .finishing: return 3
        default: return nil
        }
    }

    func reset() { if !busy { phase = .idle; current = nil } }

    /// For Autopilot's installed-demo: the Installed screen for a machine that is already listed.
    func showInstalled(_ id: UUID) { if !busy { phase = .installed(id) } }

    func download(_ image: LinuxImage) { run(image, options: nil) }

    /// Downloads what is missing, then unpacks it into a new machine in the list.
    func install(_ image: LinuxImage, options: Options) { run(image, options: options) }

    private func run(_ image: LinuxImage, options: Options?) {
        guard !busy else { return }
        current = image
        reached = 0
        phase = .downloading
        received = LinuxDownload.present(image, in: Self.folder)
        expected = image.downloadBytes
        UIApplication.shared.isIdleTimerDisabled = true
        grace = UIApplication.shared.beginBackgroundTask(withName: "Tuxedo Linux download") {
            MainActor.assumeIsolated { LinuxInstaller.shared.endGrace() }
        }
        LinuxDownload.log = { TuxLog.log("linux", $0) }
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; endGrace() }
            do {
                try LinuxCatalogue.checkBuild(image, appBuild: LinuxCatalogue.appBuild)
                try LinuxCatalogue.checkGuest(image)
                if let options { try LinuxUnpack.checkDisk(options.diskBytes, for: image) }
                try checkSpace(image)
                Machines.excludeFromBackup(Machines.root)
                TuxLog.log("linux", "downloading \(image.id) \(image.version)")
                let throttle = ProgressThrottle()
                let files = try await LinuxDownload.fetch(image, in: Self.folder) { stage, have, total in
                    guard throttle.allow(stage == .check || have >= total) else { return }
                    Task { @MainActor in
                        let me = LinuxInstaller.shared
                        guard me.busy, me.current?.id == image.id else { return } // a late update after the end
                        me.phase = stage == .check ? .checking : .downloading
                        // the check bar is the disk's alone: the firmware, read first, counts in the download
                        me.received = stage == .check ? max(have - image.firmwareBytes, 0) : have
                        me.expected = stage == .check ? image.diskBytes : total
                    }
                }
                Machines.excludeFromBackup(Self.folder)
                TuxLog.log("linux", "\(image.id) downloaded and checked")
                guard let options else { phase = .downloaded; return }
                let machine = try await make(image, files: files, options: options)
                phase = .installed(machine.id)
            } catch {
                TuxLog.log("linux", "failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Unpacks into a new machine folder, lists it, and deletes the download unless it is kept.
    private func make(_ image: LinuxImage, files: LinuxDownload.Files, options: Options) async throws -> VirtualMachine {
        try checkUnpackSpace(image)
        let name = options.name.trimmingCharacters(in: .whitespaces)
        var machine = VirtualMachine(name: name.isEmpty ? "Debian" : name, ramMB: options.ramMB, diskBytes: options.diskBytes)
        machine.osName = image.name
        if image.touch == true { machine.touchInput = true }
        machine.guestUser = image.guestUser
        phase = .decoding
        received = 0
        expected = image.diskBytes
        let throttle = ProgressThrottle()
        let dir = machine.directory, bytes = options.diskBytes, planned = machine
        TuxLog.log("linux", "making \(machine.name): \(ByteText.string(UInt64(bytes))) disk, \(options.ramMB) MB")
        try await Task.detached {
            try LinuxUnpack.make(image, files: files, into: dir, machine: planned, diskBytes: bytes) { stage, done, total in
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
        machine.diskBytes = machine.logicalDiskBytes
        Machines.shared.add(machine)
        if !options.keepDownload {
            var others: [LinuxImage] = []
            if case .loaded(let all) = catalogue { others = all }
            LinuxDownload.delete(image, in: Self.folder, others: others)
        }
        TuxLog.log("linux", "made \(machine.name) (\(machine.id)), \(ByteText.string(UInt64(machine.diskBytes))) disk")
        return machine
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
