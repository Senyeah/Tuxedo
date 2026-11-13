import Foundation

/// What a machine runs. The type that holds one is still called VirtualMac: a rename would touch most files.
enum GuestKind: String, Codable, Hashable {
    case mac, linux
}

/// A size in pixels, saved with a machine.
struct PixelSize: Codable, Hashable {
    var width: Int
    var height: Int
}

extension PixelSize {
    /// Physical size in mm at 264 ppi, which makes macOS see a Retina panel and draw at 2x.
    var denseMM: (width: Int, height: Int) {
        (Int((Double(width) / 264 * 25.4).rounded()), Int((Double(height) / 264 * 25.4).rounded()))
    }
}

/// The fixed sizes the screen choices offer (R9).
enum ScreenPreset {
    static let qhd = PixelSize(width: 2560, height: 1440)
    static let fhd = PixelSize(width: 1920, height: 1080)
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
    /// This machine's own CPU count. Missing: the global henge.cpus setting.
    var cpus: Int?
    /// The external screen this machine last ran on; a Mac boots at its size when that screen is there again.
    var lastExternalScreen: PixelSize?
    /// R9: the "External display" choice. Linux boots at the remembered external size when no screen is there; a Mac boots at it.
    var screenFollowsExternal: Bool?
    /// R9: macOS "Sharp text (HiDPI)". Missing: on only for an external screen taller than 1440 px.
    var sharpText: Bool?
    /// A9: Linux "Graphics acceleration" (virgl). Missing: off.
    var accel: Bool?
    /// Linux "Video decode": with acceleration, the guest's VA-API decodes on VideoToolbox. Missing: off.
    var video: Bool?
    var decodesVideo: Bool { guest == .linux && accel == true && video == true }
    /// LINUX-PLAN-12: the picture takes direct touches (the toolbar's touch switch). Missing: the pointer.
    var touchInput: Bool?
    /// Never for a Mac: its board has no touchscreen.
    var usesTouch: Bool { guest == .linux && touchInput == true }
    /// Linux on the phone, upright: the picture takes the whole screen, under the status bar and the home bar. Missing: off.
    var wholeScreen: Bool?
    /// Linux: the session opens on the serial console, as it was left. Missing: the screen.
    var showsConsole: Bool?

    var directory: URL { MachinePaths.directory(for: id) }
    var rom: URL { directory.appendingPathComponent("AVPBooter.vmapple2.bin") }
    var disk: URL { directory.appendingPathComponent("disk.img") }
    var aux: URL { directory.appendingPathComponent("auxiliary.bin") }
    var firmware: URL { directory.appendingPathComponent("u-boot.bin") }

    var noun: String { guest == .linux ? "machine" : "Mac" }
    static let cpuRange = 1...6
    func cpuCount(fallback: Int) -> Int { min(max(cpus ?? fallback, Self.cpuRange.lowerBound), Self.cpuRange.upperBound) }

    /// disk.img's size as the guest sees it (the file is sparse, so this is not what it takes on flash).
    var logicalDiskBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? Int64) ?? diskBytes
    }

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

/// What an exported machine folder holds, by kind.
enum MachineFolder {
    /// Files that must be there (the disk is checked apart: disk.img or disk.img.hvsparse).
    static func required(_ kind: GuestKind) -> [String] {
        kind == .linux ? ["u-boot.bin", "machine.json"] : ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json"]
    }

    /// Files adopt moves or copies as they are; the packed disk is unpacked apart.
    static func files(_ kind: GuestKind) -> [String] { required(kind) + ["disk.img"] }

    static func info(_ folder: URL) -> MachineFile? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("machine.json")) else { return nil }
        return try? JSONDecoder().decode(MachineFile.self, from: data)
    }

    /// machine.json for an export.
    static func exportInfo(_ mac: VirtualMac) -> [String: Any] {
        var info: [String: Any] = ["name": mac.name, "ramMB": mac.ramMB]
        if mac.guest == .linux { info["kind"] = GuestKind.linux.rawValue } else { info["ecid"] = mac.ecid; info["seed"] = mac.seed }
        return info
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

    /// "Macs" until a Linux machine exists.
    static func tabTitle(_ list: [VirtualMac]) -> String { list.contains { $0.guest == .linux } ? "Machines" : "Macs" }
    static func othersHeading(_ list: [VirtualMac]) -> String { list.contains { $0.guest == .linux } ? "Other machines" : "Other Macs" }
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
enum StopKind { case shutdown, restart, hostStop, panic, error }

enum StopText {
    static func title(_ kind: StopKind, guest: GuestKind) -> String {
        let name = guest == .linux ? "Debian" : "Mac"
        switch kind {
        case .shutdown: return "\(name) shut down"
        case .restart: return "\(name) requested a restart"
        case .hostStop: return "\(name) stopped"
        case .panic: return "\(name) had a kernel panic"
        case .error: return "\(name) stopped unexpectedly"
        }
    }

    static func detail(_ kind: StopKind, guest: GuestKind, reason: String) -> String {
        let noun = guest == .linux ? "machine" : "Mac"
        let next = "You can start this \(noun) again or return to your \(guest == .linux ? "machines" : "Macs")."
        switch kind {
        case .shutdown, .hostStop: return next
        case .restart: return "The \(noun) is ready to start again."
        case .panic: return "The kernel stopped with a panic. " + next
        case .error: return "The \(noun) stopped: \(reason). " + next
        }
    }

    static func startLabel(guest: GuestKind) -> String { guest == .linux ? "Start" : "Start Mac" }
}
