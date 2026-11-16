// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit

extension VirtualMachine {
    var screen: (width: Int, height: Int) { (screenWidth ?? 1920, screenHeight ?? 1080) }
    /// A phone's machine with no chosen size takes the phone's safe area at scale 2; rotation changes it.
    var followsPhoneScreen: Bool { !Device.isPad && screenWidth == nil }
    var aspect: CGFloat { CGFloat(screen.width) / CGFloat(screen.height) }
}

/// How much RAM a machine gets. The engine first asks the kernel to leave it out of Tuxedo's footprint,
/// which is allowed once a debugger has attached (how JIT is turned on). If that is refused it uses
/// a file beside the disk: iOS's memory limit does not count a mapped file's pages either.
enum GuestMemory {
    /// Points the engine at the file (it is unlinked as soon as it is open) and returns the size that fits.
    static func prepare(_ machine: VirtualMachine) -> UInt64 {
        let file = machine.directory.appendingPathComponent("ram.tmp")
        setenv("HV_RAM_FILE", file.path, 1)
        let free = (try? machine.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let room = free > 0 ? UInt64(max(free - (2 << 30), 0)) >> 20 : UInt64.max
        let reach = tux_largest_mapping_mb()
        let ram = min(UInt64(machine.ramMB), room, reach > 512 ? reach - 512 : 0) / 512 * 512
        TuxLog.log("session", "guest RAM \(ram) MB (asked \(machine.ramMB), disk room \(room), largest mapping \(reach))")
        return ram
    }
}

@MainActor
final class Machines: ObservableObject {
    static let shared = Machines()

    @Published private(set) var all: [VirtualMachine] = []
    @Published private(set) var importing: String?
    @Published var lastError: String?

    /// An exported folder's disk is disk.img, or disk.img.hvsparse (the export packs it); the rest is MachineFolder.required.
    static let packedDisk = "disk.img.hvsparse"

    nonisolated static func hasDisk(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path)
            || fm.fileExists(atPath: folder.appendingPathComponent(packedDisk).path)
    }

    @Published private(set) var unpacked: Double = 0
    /// While a machine is being exported: its name and how far along.
    @Published private(set) var exporting: String?
    @Published private(set) var exported: Double = 0
    /// The last finished export, ready to be moved out of Tuxedo.
    @Published var lastExport: URL?

    private init() {
        load()
        removeLeftovers()
    }

    /// Machine folders nothing refers to (an install cut short by a crash or by quitting): their disks take real space.
    /// A folder whose install finished (Tuxedo stopped before it was listed) is listed again instead, and nothing is
    /// removed when the list itself could not be read: every machine would look unreferenced.
    /// A folder that Tuxedo did not start (MachineList.leftover) is kept: it can be a copy put there from outside.
    private func removeLeftovers() {
        if listUnreadable {
            TuxLog.log("machines", "the list of machines could not be read: no machine folder is removed")
            return
        }
        let known = Set(all.map(\.id))
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            guard let id = UUID(uuidString: item.lastPathComponent), !known.contains(id) else { continue }
            switch MachineList.leftover(id: id, folder: item, defaultRAMMB: Device.suggestedRAMGB * 1024) {
            case .recover(let machine):
                all.append(machine)
                save()
                TuxLog.log("machines", "\(machine.name) finished installing but was not listed: listed again")
            case .remove:
                TuxLog.log("machines", "removing the unfinished machine \(id)")
                try? fm.removeItem(at: item)
            case .keep:
                TuxLog.log("machines", "the folder \(id) is not in the list and Tuxedo did not start it: kept")
            }
        }
    }

    nonisolated static var root: URL { MachinePaths.root }
    nonisolated static func directory(for id: UUID) -> URL { MachinePaths.directory(for: id) }
    /// Where Finder file sharing puts what the user drops on Tuxedo.
    nonisolated static var inbox: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Folders dropped into Tuxedo's Documents over Finder (or the Files app) that look like
    /// an exported machine are moved in. A move, not a copy: a disk image is tens of gigabytes.
    func collectImports() {
        Task { await collect() }
    }

    private func collect() async {
        guard importing == nil, let items = try? FileManager.default.contentsOfDirectory(at: Self.inbox, includingPropertiesForKeys: nil) else { return }
        for folder in items {
            guard Self.hasDisk(folder), let info = MachineFolder.info(folder),
                  MachineFolder.required.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) else { continue }
            await adopt(folder, move: true)
        }
    }

    /// A folder chosen in the Files picker: copied (it may be on another volume).
    func importFolder(_ folder: URL) {
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await adopt(folder, move: false)
        }
    }

    private func adopt(_ folder: URL, move: Bool) async {
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("machine.json"))
            let info = try JSONDecoder().decode(MachineFile.self, from: data)
            let missing = MachineFolder.required.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            guard missing.isEmpty, Self.hasDisk(folder) else { throw message("The folder is missing \((missing + (Self.hasDisk(folder) ? [] : ["disk.img"])).joined(separator: ", ")).") }
            var machine = VirtualMachine(name: info.name ?? folder.lastPathComponent, ramMB: info.ramMB ?? 2048, diskBytes: 0)
            machine.guestUser = info.guestUser
            importing = machine.name
            unpacked = 0
            let dest = machine.directory
            let fm = FileManager.default
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let installing = dest.appendingPathComponent(MachinePaths.installingMarker)
            try Data().write(to: installing)
            excludeFromBackup()
            for name in MachineFolder.files {
                let from = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                if move { try fm.moveItem(at: from, to: dest.appendingPathComponent(name)) }
                else { try fm.copyItem(at: from, to: dest.appendingPathComponent(name)) }
            }
            let packed = folder.appendingPathComponent(Self.packedDisk)
            if fm.fileExists(atPath: packed.path) {
                // Off the main thread: unpacking tens of gigabytes takes minutes.
                let target = machine.disk.path, source = packed.path
                let ok = await Task.detached { () -> Bool in
                    hv_sparse_unpack(source, target, { done, total, _ in
                        let fraction = Double(done) / Double(max(total, 1))
                        Task { @MainActor in Machines.shared.unpacked = fraction }
                    }, nil) == 0
                }.value
                guard ok else { try? fm.removeItem(at: dest); throw message("The packed disk could not be unpacked (not enough space?).") }
                if move { try? fm.removeItem(at: packed) }
            }
            if move { try? fm.removeItem(at: folder) }
            machine.diskBytes = (try? fm.attributesOfItem(atPath: machine.disk.path)[.size] as? Int64) ?? 0
            all.append(machine)
            save()
            try? fm.removeItem(at: installing) // after the list has it
            TuxLog.log("machines", "imported \(machine.name) (\(machine.diskBytes >> 30) GB disk)")
        } catch {
            lastError = error.localizedDescription
            TuxLog.log("machines", "import of \(folder.lastPathComponent) failed: \(error.localizedDescription)")
        }
        importing = nil
    }

    /// Makes a folder "Bring in a machine" can read back,
    /// in Documents/Exports, which the Files app can reach. Deleting Tuxedo deletes that folder too,
    /// so it has to be moved out of Tuxedo before a reinstall that replaces the app's data.
    func export(_ machine: VirtualMachine) {
        guard exporting == nil, importing == nil else { return }
        exporting = machine.name
        exported = 0
        lastExport = nil
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true // a locked screen would suspend the app mid-way
        Task {
            defer {
                exporting = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do { lastExport = try await writeExport(machine) } catch {
                lastError = error.localizedDescription
                TuxLog.log("machines", "export of \(machine.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeExport(_ machine: VirtualMachine) async throws -> URL {
        let fm = FileManager.default
        let exports = Self.inbox.appendingPathComponent("Exports", isDirectory: true)
        let safeName = machine.name.replacingOccurrences(of: "/", with: "-")
        let final = exports.appendingPathComponent(safeName, isDirectory: true)
        // Not under its final name until it is whole, so a cut-short export can't be mistaken for a machine.
        let partial = exports.appendingPathComponent(safeName + ".partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: final)
        let used = (try? machine.disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
        let free = (try? Self.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let needed = Int64(used) + (256 << 20)
        if free > 0 && free < needed {
            throw message("Exporting \(machine.name) needs about \(ByteText.string(UInt64(needed))) free; this \(Device.name) has \(ByteText.string(UInt64(free))). Deleting a downloaded Linux image (Install, the trash button) frees space.")
        }
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: machine.firmware, to: partial.appendingPathComponent("u-boot.bin"))
            try JSONSerialization.data(withJSONObject: MachineFolder.exportInfo(machine)).write(to: partial.appendingPathComponent("machine.json"))
            let source = machine.disk.path, target = partial.appendingPathComponent(Self.packedDisk).path
            let ok = await Task.detached { () -> Bool in
                hv_sparse_pack_progress(source, target, { done, total, _ in
                    let fraction = Double(done) / Double(max(total, 1))
                    Task { @MainActor in Machines.shared.exported = fraction }
                }, nil) == 0
            }.value
            guard ok else { throw message("The disk could not be written (not enough space?).") }
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        TuxLog.log("machines", "exported \(machine.name) to \(final.path)")
        return final
    }

    /// A machine made here (the installer), already in its directory.
    func add(_ machine: VirtualMachine) {
        all.removeAll { $0.id == machine.id }
        all.append(machine)
        save()
    }

    /// Every field but the folders, forwards, guest user and Additions fields: settings and the session change those
    /// with updateFolders, updateForwards and updateAdditions, so an older copy of the record cannot put back a
    /// stale bookmark, forward, user name or report.
    func update(_ machine: VirtualMachine) {
        guard let i = all.firstIndex(where: { $0.id == machine.id }) else { return }
        var machine = machine
        machine.folders = all[i].folders
        machine.forwards = all[i].forwards
        machine.guestUser = all[i].guestUser
        machine.additionsReport = all[i].additionsReport
        machine.additionsPromptDismissed = all[i].additionsPromptDismissed
        all[i] = machine
        save()
    }

    func updateFolders(of id: UUID, _ change: (inout [SharedFolder]) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        var list = all[i].folders ?? []
        change(&list)
        all[i].folders = list.isEmpty ? nil : list
        save()
    }

    func updateForwards(of id: UUID, _ change: (inout [PortForward]) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        var list = all[i].forwards ?? []
        change(&list)
        all[i].forwards = list.isEmpty ? nil : list
        save()
    }

    /// The Additions report, the dismissed prompt and the guest's user name: the session's Additions model writes them.
    func updateAdditions(of id: UUID, _ change: (inout VirtualMachine) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        let before = all[i]
        var machine = before
        change(&machine)
        guard machine != before else { return }
        all[i] = machine
        save()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.directory(for: id))
        KeychainStore.removeAll(machine: id)
        all.removeAll { $0.id == id }
        save()
    }

    private var listURL: URL { Self.root.appendingPathComponent("machines.json") }

    /// Disk images are tens of gigabytes: keep them out of iCloud and computer backups.
    private func excludeFromBackup() { Self.excludeFromBackup(Self.root) }

    nonisolated static func excludeFromBackup(_ dir: URL) {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// machines.json is there but did not decode (damaged, or written by a newer Tuxedo).
    private var listUnreadable = false

    private func load() {
        guard let data = try? Data(contentsOf: listURL) else { return }
        guard let list = MachineList.decode(data) else {
            listUnreadable = true
            TuxLog.log("machines", "machines.json (\(data.count) bytes) could not be read")
            return
        }
        all = list
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        excludeFromBackup()
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: listURL, options: .atomic) }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Tux", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

extension Device {
    /// Pixels per point of the panel: the scale the display layer draws at.
    static var nativeScale: CGFloat { UIScreen.main.nativeScale }
}
