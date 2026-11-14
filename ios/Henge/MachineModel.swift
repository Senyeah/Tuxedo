import Foundation

/// A size in pixels, saved with a machine.
struct PixelSize: Codable, Hashable {
    var width: Int
    var height: Int
}

/// The fixed sizes the screen choices offer (R9).
enum ScreenPreset {
    static let qhd = PixelSize(width: 2560, height: 1440)
    static let fhd = PixelSize(width: 1920, height: 1080)
}

/// A machine brought over or made here: its files and its settings.
struct VirtualMachine: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var ramMB: Int
    var diskBytes: Int64
    var added = Date()
    var osName: String?
    var lastUsed: Date?
    /// The size the guest is told its screen is. Missing: the phone's own screen, or 16:9 on an iPad.
    var screenWidth: Int?
    var screenHeight: Int?
    /// This machine's own CPU count. Missing: the global henge.cpus setting.
    var cpus: Int?
    /// The external screen this machine last ran on; the "External display" choice boots at its size when none is there.
    var lastExternalScreen: PixelSize?
    /// R9: the "External display" choice. Boots at the remembered external size when no screen is there.
    var screenFollowsExternal: Bool?
    /// A9: Linux "Graphics acceleration" (virgl). Missing: off.
    var accel: Bool?
    /// Linux "Video decode": with acceleration, the guest's VA-API decodes on VideoToolbox. Missing: off.
    var video: Bool?
    var decodesVideo: Bool { accel == true && video == true }
    /// Linux "Video encode": the guest's ffmpeg on VideoToolbox (hvcodec), at 10.0.2.4:8470 and /dev/hvcodec. Missing: off.
    var encode: Bool?
    var encodesVideo: Bool { encode == true }
    /// LINUX-PLAN-12: the picture takes direct touches (the toolbar's touch switch). Missing: the pointer.
    var touchInput: Bool?
    var usesTouch: Bool { touchInput == true }
    /// Linux on the phone, upright: the picture takes the whole screen, under the status bar and the home bar. Missing: off.
    var wholeScreen: Bool?
    /// Linux: the session opens on the serial console, as it was left. Missing: the screen.
    var showsConsole: Bool?
    /// Linux: folders from the Files app, at /media/henge/<name> in the guest. Missing: none.
    var folders: [SharedFolder]?
    /// Linux: TCP ports on the phone's local networks that lead into the guest (ForwardPolicy). Missing: none.
    var forwards: [PortForward]?

    var directory: URL { MachinePaths.directory(for: id) }
    var disk: URL { directory.appendingPathComponent("disk.img") }
    var firmware: URL { directory.appendingPathComponent("u-boot.bin") }

    static let cpuRange = 1...6
    func cpuCount(fallback: Int) -> Int { min(max(cpus ?? fallback, Self.cpuRange.lowerBound), Self.cpuRange.upperBound) }

    /// disk.img's size as the guest sees it (the file is sparse, so this is not what it takes on flash).
    var logicalDiskBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? Int64) ?? diskBytes
    }
}

/// A folder from the Files app that a Linux machine sees at /media/henge/<name> (docs/files-mount-plan.md).
struct SharedFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    /// The guest's name for it (FolderPolicy.safeName).
    var name: String
    /// Only this app on this device can resolve it, so an export of the machine leaves it out.
    var bookmark: Data
    var mode: Mode = .readWrite
    /// Where it is, for settings only, e.g. "iCloud Drive › Projects".
    var displayPath: String?
    /// The last session could not resolve the bookmark: it must be picked again. Missing: no.
    var lost: Bool?

    /// Read-write is the default (the owner's decision 1). The host serves Copy-on-write read-only; the guest's overlay
    /// keeps the changes on the machine's disk.
    enum Mode: String, Codable, CaseIterable {
        case readWrite, copyOnWrite, readOnly
    }
}

/// A port on the phone's local networks that leads to a port in a Linux guest (host/net_forward.h).
struct PortForward: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Shown in settings and Details, e.g. "SSH". Missing: the guest port.
    var name: String?
    var phonePort: Int
    var guestPort: Int
    var enabled = true
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

/// machine.json in an exported machine folder (LinuxUnpack and MachineFolder.exportInfo write it).
struct MachineFile: Codable {
    var name: String?
    var ramMB: Int?
}

/// What an exported machine folder holds.
enum MachineFolder {
    /// Files that must be there (the disk is checked apart: disk.img or disk.img.hvsparse).
    static let required = ["u-boot.bin", "machine.json"]

    /// Files adopt moves or copies as they are; the packed disk is unpacked apart.
    static let files = required + ["disk.img"]

    static func info(_ folder: URL) -> MachineFile? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("machine.json")) else { return nil }
        return try? JSONDecoder().decode(MachineFile.self, from: data)
    }

    /// machine.json for an export.
    static func exportInfo(_ machine: VirtualMachine) -> [String: Any] {
        ["name": machine.name, "ramMB": machine.ramMB]
    }
}

enum PreviewShape {
    /// The saved picture's own shape: a phone-native Linux screen is not 16:9.
    static func aspect(width: Double, height: Double, fallback: Double) -> Double {
        width > 0 && height > 0 && width.isFinite && height.isFinite ? width / height : fallback
    }
}

enum MachineList {
    /// nil when the list is damaged or from a newer Henge. A machine whose disk is gone is dropped.
    static func decode(_ data: Data, diskExists: (VirtualMachine) -> Bool = { FileManager.default.fileExists(atPath: $0.disk.path) }) -> [VirtualMachine]? {
        guard let list = try? JSONDecoder().decode([VirtualMachine].self, from: data) else { return nil }
        return list.filter(diskExists)
    }

    /// A folder whose install finished but was never listed. Needs the marker, a machine.json and a disk,
    /// plus the files the guest boots from. `defaultRAMMB` is used when machine.json has none.
    static func recover(id: UUID, folder: URL, defaultRAMMB: Int) -> VirtualMachine? {
        let fm = FileManager.default
        let marker = folder.appendingPathComponent(MachinePaths.installedMarker)
        guard fm.fileExists(atPath: marker.path),
              let data = try? Data(contentsOf: folder.appendingPathComponent("machine.json")),
              let info = try? JSONDecoder().decode(MachineFile.self, from: data),
              fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path) else { return nil }
        guard fm.fileExists(atPath: folder.appendingPathComponent("u-boot.bin").path) else { return nil }
        let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent("disk.img").path)[.size] as? Int64) ?? 0
        var machine = VirtualMachine(id: id, name: info.name ?? "Linux", ramMB: info.ramMB ?? defaultRAMMB, diskBytes: size)
        let os = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        machine.osName = os.isEmpty ? nil : os
        return machine
    }

    static let tabTitle = "Machines"
    static let othersHeading = "Other machines"
}

enum DiskGrowth {
    /// Extends a sparse disk image. It never shrinks: the guest's partitions would be cut.
    static func grow(_ disk: URL, toBytes: Int64) throws {
        let handle = try FileHandle(forUpdating: disk)
        defer { try? handle.close() }
        let now = Int64(try handle.seekToEnd())
        guard toBytes > now else {
            throw NSError(domain: "Henge", code: 2, userInfo: [NSLocalizedDescriptionKey: "A disk can only grow."])
        }
        try handle.truncate(atOffset: UInt64(toBytes))
    }
}

/// Why a machine stopped (the app maps HengeVmOutcome to this) and what to tell the person.
enum StopKind { case shutdown, restart, hostStop, error }

enum StopText {
    static func title(_ kind: StopKind) -> String {
        let name = "Debian"
        switch kind {
        case .shutdown: return "\(name) shut down"
        case .restart: return "\(name) requested a restart"
        case .hostStop: return "\(name) stopped"
        case .error: return "\(name) stopped unexpectedly"
        }
    }

    static func detail(_ kind: StopKind, reason: String) -> String {
        let next = "You can start this machine again or return to your machines."
        switch kind {
        case .shutdown, .hostStop: return next
        case .restart: return "The machine is ready to start again."
        case .error: return "The machine stopped: \(reason). " + next
        }
    }

    static let startLabel = "Start"
}
