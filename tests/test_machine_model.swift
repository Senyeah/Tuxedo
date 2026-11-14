import Foundation

@main
struct MachineModelTests {
    // A list written by an earlier build: keys the model no longer has (ecid, seed, kind, retina, sharpText) are ignored.
    static let oldList = """
    [{"id":"11111111-2222-3333-4444-555555555555","name":"Bookworm","ecid":0,"seed":0,"kind":"linux",
      "ramMB":4096,"diskBytes":17179869184,"added":784000000.5,"osName":"Debian 12",
      "screenWidth":1920,"screenHeight":1080,"retina":false,"sharpText":true}]
    """

    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("machine-model-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Old list: decodes, and the keys the model dropped are ignored.
        let old = MachineList.decode(Data(oldList.utf8), diskExists: { _ in true })!
        precondition(old.count == 1 && old[0].name == "Bookworm" && old[0].ramMB == 4096 && old[0].osName == "Debian 12")
        precondition(old[0].screenWidth == 1920 && old[0].screenHeight == 1080)

        // New list: two machines round-trip, and each has its own firmware path.
        let linux = VirtualMachine(name: "Debian", ramMB: 1024, diskBytes: 16 << 30)
        let both = old + [linux]
        let data = try JSONEncoder().encode(both)
        let back = MachineList.decode(data, diskExists: { _ in true })!
        precondition(back == both)
        precondition(back[1].firmware.lastPathComponent == "u-boot.bin" && back[1].firmware.deletingLastPathComponent() == back[1].directory)
        for dropped in ["kind", "ecid", "seed", "retina", "sharpText"] {
            precondition(!String(decoding: data, as: UTF8.self).contains("\"\(dropped)\""), dropped)
        }

        // lastExternalScreen is optional: old JSON decodes without it, and a saved size round-trips.
        precondition(old[0].lastExternalScreen == nil && back[1].lastExternalScreen == nil)
        var withScreen = old[0]
        withScreen.lastExternalScreen = PixelSize(width: 3840, height: 2160)
        let screenData = try JSONEncoder().encode([withScreen])
        precondition(MachineList.decode(screenData, diskExists: { _ in true })! == [withScreen])
        precondition(String(decoding: screenData, as: UTF8.self).contains("\"lastExternalScreen\":{"))

        // A machine whose disk is gone is dropped; a damaged list is nil, not empty.
        precondition(MachineList.decode(data, diskExists: { $0.name == "Bookworm" })!.map(\.name) == ["Bookworm"])
        precondition(MachineList.decode(Data("{".utf8)) == nil)
        precondition(MachineList.decode(Data(#"[{"id":"x"}]"#.utf8)) == nil)

        // machine.json holds a name and a RAM size; other keys (an older file's kind, ecid, seed) are ignored.
        let file = try JSONDecoder().decode(MachineFile.self, from: Data(#"{"name":"D","ramMB":1024}"#.utf8))
        precondition(file.name == "D" && file.ramMB == 1024)
        let staleFile = try JSONDecoder().decode(MachineFile.self, from: Data(#"{"name":"S","kind":"linux","ecid":7,"seed":9,"ramMB":2048}"#.utf8))
        precondition(staleFile.name == "S" && staleFile.ramMB == 2048)

        // Recovery of an install that finished but was never listed.
        func folder(_ name: String, files: [String: String]) throws -> URL {
            let dir = tmp.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (file, text) in files { try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8) }
            return dir
        }
        let id = UUID()
        let linuxJSON = #"{"name":"Debian","ramMB":2048}"#
        let ok = try folder("linux-ok", files: ["installed": "Debian 13\n", "machine.json": linuxJSON, "disk.img": "xxxx", "u-boot.bin": "fw"])
        let rec = MachineList.recover(id: id, folder: ok, defaultRAMMB: 1024)!
        precondition(rec.id == id && rec.name == "Debian" && rec.ramMB == 2048)
        precondition(rec.osName == "Debian 13" && rec.diskBytes == 4)
        let stale = try folder("linux-stale", files: ["installed": "", "machine.json": #"{"kind":"linux","ecid":7}"#, "disk.img": "xx", "u-boot.bin": "fw"])
        let srec = MachineList.recover(id: id, folder: stale, defaultRAMMB: 3072)!
        precondition(srec.name == "Linux" && srec.ramMB == 3072 && srec.osName == nil && srec.diskBytes == 2)

        let noFirmware = try folder("linux-nofw", files: ["installed": "", "machine.json": linuxJSON, "disk.img": "x"])
        precondition(MachineList.recover(id: id, folder: noFirmware, defaultRAMMB: 1024) == nil)
        let noMarker = try folder("linux-nomarker", files: ["machine.json": linuxJSON, "disk.img": "x", "u-boot.bin": "fw"])
        precondition(MachineList.recover(id: id, folder: noMarker, defaultRAMMB: 1024) == nil)
        let noDisk = try folder("linux-nodisk", files: ["installed": "", "machine.json": linuxJSON, "u-boot.bin": "fw"])
        precondition(MachineList.recover(id: id, folder: noDisk, defaultRAMMB: 1024) == nil)


        // I5: a per-machine CPU count falls back to the global one, and stays in range.
        precondition(old[0].cpus == nil && old[0].cpuCount(fallback: 4) == 4)
        var four = linux
        four.cpus = 2
        precondition(four.cpuCount(fallback: 4) == 2 && linux.cpuCount(fallback: 5) == 5)
        four.cpus = 99
        precondition(four.cpuCount(fallback: 4) == 6 && linux.cpuCount(fallback: 0) == 1)
        four.cpus = 3
        let again = try MachineList.decode(JSONEncoder().encode([four]), diskExists: { _ in true })!; precondition(again[0].cpus == 3)

        // The tab and the list heading say "machines".
        precondition(MachineList.tabTitle == "Machines" && MachineList.othersHeading == "Other machines")

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

        // The stopped card's words.
        precondition(StopText.title(.shutdown) == "Debian shut down")
        precondition(StopText.title(.restart) == "Debian requested a restart")
        precondition(StopText.title(.hostStop) == "Debian stopped")
        precondition(StopText.title(.error) == "Debian stopped unexpectedly")
        precondition(StopText.detail(.error, reason: "boom").contains("boom"))
        precondition(StopText.startLabel == "Start")
        precondition(StopText.detail(.shutdown, reason: "").contains("machines"))
        precondition(StopText.detail(.restart, reason: "") == "The machine is ready to start again.")

        precondition(MachineFolder.required == ["u-boot.bin", "machine.json"])
        precondition(MachineFolder.files.contains("u-boot.bin") && MachineFolder.files.contains("disk.img"))
        let exp = MachineFolder.exportInfo(VirtualMachine(name: "Deb", ramMB: 1024, diskBytes: 0))
        precondition(Set(exp.keys) == ["name", "ramMB"] && exp["ramMB"] as? Int == 1024)
        let exported = try JSONDecoder().decode(MachineFile.self, from: JSONSerialization.data(withJSONObject: exp))
        precondition(exported.name == "Deb" && exported.ramMB == 1024)

        // R9: the screen choices are optional; old JSON decodes without them and saved ones round-trip.
        precondition(old[0].screenFollowsExternal == nil && back[1].screenFollowsExternal == nil)
        var chosen = linux
        chosen.screenFollowsExternal = true
        chosen.screenWidth = ScreenPreset.qhd.width
        chosen.screenHeight = ScreenPreset.qhd.height
        let chosenData = try JSONEncoder().encode([chosen])
        let chosenBack = MachineList.decode(chosenData, diskExists: { _ in true })!
        precondition(chosenBack == [chosen] && chosenBack[0].screenFollowsExternal == true)
        precondition(String(decoding: chosenData, as: UTF8.self).contains("\"screenFollowsExternal\":true"))
        // Without the fields they are left out of the JSON, so an older build reads the list.

        // A9: acceleration is off unless chosen, and is left out of the JSON when never chosen.
        precondition(old[0].accel == nil && chosenBack[0].accel == nil)
        precondition(!String(decoding: data, as: UTF8.self).contains("accel"))
        chosen.accel = true
        let accelBack = MachineList.decode(try JSONEncoder().encode([chosen]), diskExists: { _ in true })!
        precondition(accelBack[0].accel == true)
        // Video decode is off unless chosen, and only with acceleration.
        precondition(accelBack[0].video == nil && !accelBack[0].decodesVideo && !String(decoding: data, as: UTF8.self).contains("video"))
        chosen.video = true
        let videoBack = MachineList.decode(try JSONEncoder().encode([chosen]), diskExists: { _ in true })!
        precondition(videoBack[0].video == true && videoBack[0].decodesVideo)
        chosen.accel = false
        precondition(!chosen.decodesVideo)
        chosen.accel = true
        chosen.video = nil
        // Video encode is off unless chosen, and needs no acceleration.
        precondition(old[0].encode == nil && !old[0].encodesVideo && back[1].encode == nil && !back[1].encodesVideo)
        precondition(!String(decoding: data, as: UTF8.self).contains("encode"))
        var encoding = linux
        encoding.encode = true
        let encodeData = try JSONEncoder().encode([encoding])
        precondition(String(decoding: encodeData, as: UTF8.self).contains("\"encode\":true"))
        let encodeBack = MachineList.decode(encodeData, diskExists: { _ in true })!
        precondition(encodeBack == [encoding] && encodeBack[0].encode == true && encodeBack[0].encodesVideo && encodeBack[0].accel == nil)
        encoding.encode = false
        let offBack = MachineList.decode(try JSONEncoder().encode([encoding]), diskExists: { _ in true })!
        precondition(!encoding.encodesVideo && offBack[0].encode == false && !offBack[0].encodesVideo)

        // TS5: the touch switch is per machine; old JSON has none (the pointer).
        precondition(old[0].touchInput == nil && !old[0].usesTouch && back[1].touchInput == nil && !back[1].usesTouch)
        precondition(!String(decoding: data, as: UTF8.self).contains("touchInput"))
        var touchLinux = linux
        touchLinux.touchInput = true
        let touchBack = MachineList.decode(try JSONEncoder().encode([touchLinux]), diskExists: { _ in true })!
        precondition(touchBack[0].touchInput == true && touchBack[0].usesTouch)
        touchLinux.touchInput = false
        precondition(!touchLinux.usesTouch)

        // The whole-screen and console choices are per machine; old JSON has neither (safe area, the screen).
        precondition(old[0].wholeScreen == nil && old[0].showsConsole == nil)
        precondition(!String(decoding: data, as: UTF8.self).contains("wholeScreen"))
        precondition(!String(decoding: data, as: UTF8.self).contains("showsConsole"))
        var chosenView = linux
        chosenView.wholeScreen = true
        chosenView.showsConsole = true
        let viewBack = MachineList.decode(try JSONEncoder().encode([chosenView]), diskExists: { _ in true })!
        precondition(viewBack[0].wholeScreen == true && viewBack[0].showsConsole == true)

        // A9: the Home thumbnail follows the saved picture, not the machine's 16:9 screen.
        precondition(PreviewShape.aspect(width: 640, height: 1386, fallback: 16.0 / 9) == 640.0 / 1386)
        precondition(PreviewShape.aspect(width: 0, height: 0, fallback: 16.0 / 9) == 16.0 / 9)

        // Port forwards: none by default, off for old JSON, and a list round-trips.
        precondition(old[0].forwards == nil && linux.forwards == nil)
        precondition(!String(decoding: data, as: UTF8.self).contains("forwards"))
        let ssh = ForwardPolicy.sshPreset()
        precondition(ssh.name == "SSH" && ssh.phonePort == 2222 && ssh.guestPort == 22 && ssh.enabled)
        precondition(ForwardPolicy.sshPreset().id != ssh.id) // a new rule each tap
        var web = PortForward(phonePort: 8000, guestPort: 8000)
        web.enabled = false
        var forwarding = linux
        forwarding.forwards = [ssh, web]
        let fwdData = try JSONEncoder().encode([forwarding])
        let fwdBack = MachineList.decode(fwdData, diskExists: { _ in true })!
        precondition(fwdBack[0].forwards == [ssh, web] && fwdBack[0].forwards![1].name == nil && !fwdBack[0].forwards![1].enabled)
        precondition(String(decoding: fwdData, as: UTF8.self).contains("\"phonePort\":2222"))

        // Validation: phone ports 1024-65535, guest 1-65535, a phone port once, at most 16.
        precondition(ForwardPolicy.isValid([]) && ForwardPolicy.isValid([ssh, web]))
        precondition(ForwardPolicy.problem([PortForward(phonePort: 22, guestPort: 22)], at: 0) == .phonePort)
        precondition(ForwardPolicy.problem([PortForward(phonePort: 1023, guestPort: 22)], at: 0) == .phonePort)
        precondition(ForwardPolicy.problem([PortForward(phonePort: 1024, guestPort: 22)], at: 0) == nil)
        precondition(ForwardPolicy.problem([PortForward(phonePort: 65536, guestPort: 22)], at: 0) == .phonePort)
        precondition(ForwardPolicy.problem([PortForward(phonePort: 65535, guestPort: 65535)], at: 0) == nil)
        precondition(ForwardPolicy.problem([PortForward(phonePort: 2000, guestPort: 0)], at: 0) == .guestPort)
        precondition(ForwardPolicy.problem([PortForward(phonePort: 2000, guestPort: 65536)], at: 0) == .guestPort)
        let twice = [ssh, PortForward(phonePort: 2222, guestPort: 80)]
        precondition(ForwardPolicy.problem(twice, at: 0) == nil && ForwardPolicy.problem(twice, at: 1) == .duplicate)
        precondition(!ForwardPolicy.isValid(twice))
        var offTwice = twice
        offTwice[0].enabled = false // a disabled rule still holds its phone port
        precondition(ForwardPolicy.problem(offTwice, at: 1) == .duplicate)
        let sixteen = (0..<16).map { PortForward(phonePort: 3000 + $0, guestPort: 22) }
        precondition(ForwardPolicy.isValid(sixteen) && !ForwardPolicy.isValid(sixteen + [PortForward(phonePort: 4000, guestPort: 22)]))
        precondition(!ForwardPolicy.canAddSSH(sixteen) && ForwardPolicy.canAddSSH([web]) && !ForwardPolicy.canAddSSH([ssh]))
        // A typed name is stored trimmed; the preset is not offered again for "SSH " or "ssh".
        precondition(ForwardPolicy.cleanName("  SSH \n") == "SSH" && ForwardPolicy.cleanName("   ") == nil && ForwardPolicy.cleanName("") == nil)
        precondition(!ForwardPolicy.canAddSSH([PortForward(name: "SSH ", phonePort: 2200, guestPort: 22)]))
        precondition(!ForwardPolicy.canAddSSH([PortForward(name: "ssh", phonePort: 2200, guestPort: 22)]))
        precondition(ForwardPolicy.canAddSSH([PortForward(name: "SSH", phonePort: 2200, guestPort: 8022)]))
        // A blank or non-numeric port field keeps the stored port.
        precondition(ForwardPolicy.port("2222") == 2222 && ForwardPolicy.port(" 22 ") == 22)
        precondition(ForwardPolicy.port("") == nil && ForwardPolicy.port("22a") == nil)

        // The engine gets the enabled rules with no problem, at most 16.
        precondition(ForwardPolicy.active([ssh, web]) == [ssh])
        precondition(ForwardPolicy.active(twice) == [ssh])
        precondition(ForwardPolicy.active(sixteen + [PortForward(phonePort: 4000, guestPort: 22)]).count == 16)
        precondition(ForwardPolicy.newRule([web]).phonePort == 8001 && ForwardPolicy.newRule([]).guestPort == 8000)

        // What Details shows.
        precondition(ForwardPolicy.title(ssh) == "SSH" && ForwardPolicy.title(web) == "Port 8000")
        precondition(ForwardPolicy.connectText(ssh, address: "192.168.1.20") == "ssh -p 2222 henge@192.168.1.20")
        precondition(ForwardPolicy.connectText(web, address: "192.168.1.20") == "192.168.1.20:8000")
        let lines = "127.0.0.1 lo0\n100.101.102.103 utun3\n192.168.1.20 en0\n"
        precondition(ForwardPolicy.parseAddresses(lines).map(\.ip) == ["192.168.1.20", "100.101.102.103", "127.0.0.1"])
        precondition(ForwardPolicy.networkName("en0") == "Wi-Fi" && ForwardPolicy.networkName("utun3") == "VPN"
                     && ForwardPolicy.networkName("en5") == "Ethernet" && ForwardPolicy.networkName("bridge100") == "Personal Hotspot"
                     && ForwardPolicy.networkName("ipsec0") == "ipsec0")
        let up = ForwardPolicy.shown(count: 3, err: 0, text: lines, phonePort: 2222, device: "iPhone")
        guard case .listening(let local, true) = up, local.map(\.ip) == ["192.168.1.20", "100.101.102.103"] else { preconditionFailure("\(up)") }
        precondition(ForwardPolicy.shown(count: 1, err: 0, text: "127.0.0.1 lo0\n", phonePort: 2222, device: "iPhone") == .noLocalNetwork(loopback: true))
        precondition(ForwardPolicy.shown(count: 0, err: 0, text: "", phonePort: 2222, device: "iPhone") == .noLocalNetwork(loopback: false))
        precondition(ForwardPolicy.shown(count: -1, err: 0, text: "", phonePort: 2222, device: "iPhone") == .off)
        precondition(ForwardPolicy.shown(count: 0, err: 48, text: "", phonePort: 2222, device: "iPad")
                     == .failed("Port 2222 is in use on this iPad.", local: []))
        guard case .failed("Port 2222 is in use on this iPhone on some of its addresses.", let some) =
                ForwardPolicy.shown(count: 1, err: 48, text: "192.168.1.20 en0\n", phonePort: 2222, device: "iPhone"),
              some.map(\.ip) == ["192.168.1.20"] else { preconditionFailure("partly in use") }

        print("machine model: ok")
    }
}
