import Foundation

/// What a machine runs. The type that holds one is still called VirtualMac: a rename would touch most files.
enum GuestKind: String, Codable, Hashable {
    case mac, linux
}

/// A machine brought over or made here: its files, and the identity it was installed with.
/// Linux machines keep ecid and seed at 0; they only mean something for a Mac.
struct VirtualMac: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var ecid: UInt64
    var seed: UInt64
    var ramMB: Int
    var diskBytes: Int64
    var added = Date()
    var osName: String?
    var lastUsed: Date?
    /// The size macOS is told its screen is. Macs made before this was a choice have none: 16:9.
    var screenWidth: Int?
    var screenHeight: Int?
    /// m4 fork: the iPad's own panel at Retina density. On by default on iPad, for Macs that never chose.
    var retina: Bool?
    /// Missing in a list written before Linux guests: that is a Mac.
    var kind: GuestKind?
    var guest: GuestKind { kind ?? .mac }

    var directory: URL { MachinePaths.directory(for: id) }
    var rom: URL { directory.appendingPathComponent("AVPBooter.vmapple2.bin") }
    var disk: URL { directory.appendingPathComponent("disk.img") }
    var aux: URL { directory.appendingPathComponent("auxiliary.bin") }
    var firmware: URL { directory.appendingPathComponent("u-boot.bin") }

    /// Writes the file that says the install finished; the list is rebuilt from it after a crash.
    func markInstalled() {
        try? (osName ?? "").write(to: directory.appendingPathComponent(MachinePaths.installedMarker), atomically: true, encoding: .utf8)
    }
}

enum MachinePaths {
    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Machines", isDirectory: true)
    }
    nonisolated static func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// The file the installer puts in a machine's folder once the guest is on its disk (it holds the release's name).
    nonisolated static let installedMarker = "installed"
}

/// machine.json in an exported machine folder (tools/export_ios.sh writes it).
struct MachineFile: Codable {
    var name: String?
    var kind: GuestKind?
    /// Only a Mac has one.
    var ecid: UInt64?
    var seed: UInt64?
    var ramMB: Int?
}

enum MachineList {
    /// nil when the list is damaged or from a newer Henge. A machine whose disk is gone is dropped.
    static func decode(_ data: Data, diskExists: (VirtualMac) -> Bool = { FileManager.default.fileExists(atPath: $0.disk.path) }) -> [VirtualMac]? {
        guard let list = try? JSONDecoder().decode([VirtualMac].self, from: data) else { return nil }
        return list.filter(diskExists)
    }

    /// A folder whose install finished but was never listed. Needs the marker, a machine.json and a disk,
    /// plus the files the guest boots from. `defaultRAMMB` is used when machine.json has none.
    static func recover(id: UUID, folder: URL, defaultRAMMB: Int) -> VirtualMac? {
        let fm = FileManager.default
        let marker = folder.appendingPathComponent(MachinePaths.installedMarker)
        guard fm.fileExists(atPath: marker.path),
              let data = try? Data(contentsOf: folder.appendingPathComponent("machine.json")),
              let info = try? JSONDecoder().decode(MachineFile.self, from: data),
              fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path) else { return nil }
        var mac: VirtualMac
        switch info.kind ?? .mac {
        case .mac:
            guard let ecid = info.ecid else { return nil }
            mac = VirtualMac(id: id, name: info.name ?? "Mac", ecid: ecid, seed: info.seed ?? 0,
                             ramMB: info.ramMB ?? defaultRAMMB, diskBytes: 64 << 30)
        case .linux:
            guard fm.fileExists(atPath: folder.appendingPathComponent("u-boot.bin").path) else { return nil }
            let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent("disk.img").path)[.size] as? Int64) ?? 0
            mac = VirtualMac(id: id, name: info.name ?? "Linux", ecid: 0, seed: 0,
                             ramMB: info.ramMB ?? defaultRAMMB, diskBytes: size)
            mac.kind = .linux
        }
        let os = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mac.osName = os.isEmpty ? nil : os
        return mac
    }
}
