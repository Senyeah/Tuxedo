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

        print("machine model: ok")
    }
}
