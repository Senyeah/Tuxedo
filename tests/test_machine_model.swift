import Foundation

@main
struct MachineModelTests {
    // machines.json as the app wrote it before GuestKind existed (no "kind" key).
    static let oldList = """
    [{"id":"11111111-2222-3333-4444-555555555555","name":"Sequoia","ecid":1234605616436508552,"seed":12345,
      "ramMB":4096,"diskBytes":68719476736,"added":784000000.5,"osName":"macOS 15.1",
      "screenWidth":1920,"screenHeight":1080,"retina":false}]
    """

    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("machine-model-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Old list: decodes, and the Mac keeps its identity and kind.
        let old = MachineList.decode(Data(oldList.utf8), diskExists: { _ in true })!
        precondition(old.count == 1 && old[0].kind == nil && old[0].guest == .mac)
        precondition(old[0].ecid == 1234605616436508552 && old[0].seed == 12345 && old[0].ramMB == 4096)
        precondition(old[0].rom.lastPathComponent == "AVPBooter.vmapple2.bin" && old[0].aux.lastPathComponent == "auxiliary.bin")

        // New list: a Mac and a Linux machine round-trip, and the Linux one has its own firmware path.
        var linux = VirtualMac(name: "Debian", ecid: 0, seed: 0, ramMB: 1024, diskBytes: 16 << 30)
        linux.kind = .linux
        let both = old + [linux]
        let data = try JSONEncoder().encode(both)
        let back = MachineList.decode(data, diskExists: { _ in true })!
        precondition(back == both && back[0].guest == .mac && back[1].guest == .linux)
        precondition(back[1].firmware.lastPathComponent == "u-boot.bin" && back[1].firmware.deletingLastPathComponent() == back[1].directory)
        precondition(String(decoding: data, as: UTF8.self).contains("\"kind\":\"linux\""))

        // A machine whose disk is gone is dropped; a damaged list is nil, not empty.
        precondition(MachineList.decode(data, diskExists: { $0.guest == .mac })!.map(\.name) == ["Sequoia"])
        precondition(MachineList.decode(Data("{".utf8)) == nil)
        precondition(MachineList.decode(Data(#"[{"id":"x"}]"#.utf8)) == nil)

        // machine.json: a Linux one has no ecid; an old Mac one has no kind.
        let file = try JSONDecoder().decode(MachineFile.self, from: Data(#"{"name":"D","kind":"linux","ramMB":1024}"#.utf8))
        precondition(file.kind == .linux && file.ecid == nil && file.ramMB == 1024)
        let macFile = try JSONDecoder().decode(MachineFile.self, from: Data(#"{"name":"M","ecid":7,"seed":9,"ramMB":2048}"#.utf8))
        precondition(macFile.kind == nil && macFile.ecid == 7)

        // Recovery of an install that finished but was never listed.
        func folder(_ name: String, files: [String: String]) throws -> URL {
            let dir = tmp.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (file, text) in files { try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8) }
            return dir
        }
        let id = UUID()
        let linuxJSON = #"{"name":"Debian","kind":"linux","ramMB":2048}"#
        let ok = try folder("linux-ok", files: ["installed": "Debian 13\n", "machine.json": linuxJSON, "disk.img": "xxxx", "u-boot.bin": "fw"])
        let rec = MachineList.recover(id: id, folder: ok, defaultRAMMB: 1024)!
        precondition(rec.guest == .linux && rec.id == id && rec.name == "Debian" && rec.ramMB == 2048)
        precondition(rec.osName == "Debian 13" && rec.ecid == 0 && rec.seed == 0 && rec.diskBytes == 4)

        let noFirmware = try folder("linux-nofw", files: ["installed": "", "machine.json": linuxJSON, "disk.img": "x"])
        precondition(MachineList.recover(id: id, folder: noFirmware, defaultRAMMB: 1024) == nil)
        let noMarker = try folder("linux-nomarker", files: ["machine.json": linuxJSON, "disk.img": "x", "u-boot.bin": "fw"])
        precondition(MachineList.recover(id: id, folder: noMarker, defaultRAMMB: 1024) == nil)
        let noDisk = try folder("linux-nodisk", files: ["installed": "", "machine.json": linuxJSON, "u-boot.bin": "fw"])
        precondition(MachineList.recover(id: id, folder: noDisk, defaultRAMMB: 1024) == nil)

        let macOK = try folder("mac-ok", files: ["installed": "macOS 15\n", "machine.json": #"{"name":"M","ecid":7}"#, "disk.img": "x"])
        let mrec = MachineList.recover(id: id, folder: macOK, defaultRAMMB: 3072)!
        precondition(mrec.guest == .mac && mrec.ecid == 7 && mrec.ramMB == 3072 && mrec.osName == "macOS 15")
        let macNoEcid = try folder("mac-noecid", files: ["installed": "", "machine.json": #"{"name":"M"}"#, "disk.img": "x"])
        precondition(MachineList.recover(id: id, folder: macNoEcid, defaultRAMMB: 1024) == nil)

        // I5: a per-machine CPU count falls back to the global one, and stays in range.
        precondition(old[0].cpus == nil && old[0].cpuCount(fallback: 4) == 4)
        var four = linux
        four.cpus = 2
        precondition(four.cpuCount(fallback: 4) == 2 && linux.cpuCount(fallback: 5) == 5)
        four.cpus = 99
        precondition(four.cpuCount(fallback: 4) == 6 && linux.cpuCount(fallback: 0) == 1)
        four.cpus = 3
        let again = try MachineList.decode(JSONEncoder().encode([four]), diskExists: { _ in true })!; precondition(again[0].cpus == 3)

        // The tab and the list heading say "machines" once a Linux machine exists.
        precondition(MachineList.tabTitle([]) == "Macs" && MachineList.tabTitle(old) == "Macs")
        precondition(MachineList.tabTitle(both) == "Machines" && MachineList.othersHeading(both) == "Other machines")
        precondition(MachineList.othersHeading(old) == "Other Macs" && linux.noun == "machine" && old[0].noun == "Mac")

        // Disk growth: the file gets longer, never shorter.
        let img = tmp.appendingPathComponent("grow.img")
        try Data(count: 4096).write(to: img)
        try DiskGrowth.grow(img, toBytes: 1 << 20)
        let len = try (fm.attributesOfItem(atPath: img.path)[.size] as! NSNumber).int64Value; precondition(len == 1 << 20)
        for bad in [Int64(1 << 20), 4096] {
            do { try DiskGrowth.grow(img, toBytes: bad); preconditionFailure("shrink allowed") } catch {}
        }
        let len2 = try (fm.attributesOfItem(atPath: img.path)[.size] as! NSNumber).int64Value; precondition(len2 == 1 << 20)
        var sized = linux
        sized.diskBytes = 5
        precondition(sized.logicalDiskBytes == 5) // no disk.img in its folder: the stored size

        // The stopped card has its own words per kind, and a panic is not "stopped unexpectedly".
        for guest in [GuestKind.mac, .linux] {
            let name = guest == .linux ? "Debian" : "Mac"
            precondition(StopText.title(.shutdown, guest: guest) == "\(name) shut down")
            precondition(StopText.title(.restart, guest: guest) == "\(name) requested a restart")
            precondition(StopText.title(.panic, guest: guest) == "\(name) had a kernel panic")
            precondition(StopText.title(.error, guest: guest) == "\(name) stopped unexpectedly")
            precondition(StopText.detail(.error, guest: guest, reason: "boom").contains("boom"))
            precondition(!StopText.detail(.panic, guest: guest, reason: "guest panic").contains("guest panic"))
        }
        precondition(StopText.startLabel(guest: .linux) == "Start" && StopText.startLabel(guest: .mac) == "Start Mac")
        precondition(StopText.detail(.shutdown, guest: .linux, reason: "").contains("machines"))
        precondition(StopText.detail(.shutdown, guest: .mac, reason: "").contains("Macs"))

        precondition(MachineFolder.required(.linux) == ["u-boot.bin", "machine.json"])
        precondition(MachineFolder.required(.mac).contains("auxiliary.bin"))
        precondition(MachineFolder.files(.linux).contains("u-boot.bin") && !MachineFolder.files(.linux).contains("auxiliary.bin"))
        var lin = VirtualMac(name: "Deb", ecid: 0, seed: 0, ramMB: 1024, diskBytes: 0)
        lin.kind = .linux
        let exp = MachineFolder.exportInfo(lin)
        precondition(exp["kind"] as? String == "linux" && exp["ecid"] == nil && exp["ramMB"] as? Int == 1024)
        let exported = try JSONDecoder().decode(MachineFile.self, from: JSONSerialization.data(withJSONObject: exp))
        precondition(exported.kind == .linux && exported.name == "Deb")
        let macExp = MachineFolder.exportInfo(VirtualMac(name: "M", ecid: 7, seed: 9, ramMB: 2048, diskBytes: 0))
        precondition(macExp["kind"] == nil && macExp["ecid"] as? UInt64 == 7)

        print("machine model: ok")
    }
}
